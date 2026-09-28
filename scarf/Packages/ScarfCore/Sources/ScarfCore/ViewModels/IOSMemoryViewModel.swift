import Foundation
import Observation

/// iOS Memory editor state. Loads MEMORY.md / USER.md via the
/// transport, holds the text in-memory, saves on explicit action.
///
/// Lives in ScarfCore (not ScarfIOS) because it's pure file-I/O on
/// top of `ServerContext.readText` / `writeText` — no Keychain, no
/// Citadel, no UIKit — and that lets the state machine be unit-
/// tested on Linux with `InMemory` mocks.
///
/// **Which file.** Constructor takes `kind` (`.memory` or `.user`)
/// and picks the corresponding path via `ServerContext.paths`. Users
/// toggle between the two via navigation.
@Observable
@MainActor
public final class IOSMemoryViewModel {
    public enum Kind: Sendable, Equatable, CaseIterable {
        /// `~/.hermes/memories/MEMORY.md` — the agent's persistent
        /// memory. Visible (and editable) to the agent at every
        /// session start.
        case memory
        /// `~/.hermes/memories/USER.md` — user-profile notes the
        /// agent reads but (by default) does not write.
        case user
        /// `~/.hermes/SOUL.md` — the agent's persona / character
        /// (voice, tone, style). Lives in the Personalities feature
        /// on macOS; on iOS we fold it into Memory so the whole
        /// "edit the agent's prompt inputs" surface is in one place.
        case soul

        /// Heading shown in the UI.
        public var displayName: String {
            switch self {
            case .memory: return "MEMORY.md"
            case .user:   return "USER.md"
            case .soul:   return "SOUL.md"
            }
        }

        /// SF Symbol used in the list row.
        public var iconName: String {
            switch self {
            case .memory: return "brain.head.profile"
            case .user:   return "person.crop.square"
            case .soul:   return "sparkles"
            }
        }

        /// Terse explanation shown under the heading.
        public var subtitle: String {
            switch self {
            case .memory:
                return "Agent's persistent memory. Appears in every session prompt."
            case .user:
                return "Notes about you. Read by the agent but not modified automatically."
            case .soul:
                return "Agent persona — voice, tone, personality."
            }
        }

        /// Resolve the remote path for this memory file on the
        /// given context. `ServerContext.paths` exposes
        /// `memoryMD`, `userMD`, and `soulMD` directly.
        public func path(on context: ServerContext) -> String {
            switch self {
            case .memory: return context.paths.memoryMD
            case .user:   return context.paths.userMD
            case .soul:   return context.paths.soulMD
            }
        }
    }

    public let kind: Kind
    public let context: ServerContext

    /// Content loaded from the file. `text` binds to the editor; the
    /// view compares against `originalText` to gate the Save button.
    public var text: String = ""
    public private(set) var originalText: String = ""

    public private(set) var isLoading: Bool = true
    public private(set) var isSaving: Bool = false
    public private(set) var lastError: String?

    /// The PROOF that this editor's buffer came from a real read
    /// (GW-F2, audit DI M12). `false` until a load succeeds, and back to
    /// `false` after any load failure — a Save is unreachable without it.
    ///
    /// This mirrors `SkillsViewModel`'s proof-token discipline: no token, no
    /// save. Without it, a transport blip blanked `text`/`originalText` to
    /// `""`, and the very next keystroke made `hasUnsavedChanges` true again
    /// — re-arming Save over a buffer that was never read. The guarded write
    /// would refuse a stat-confirmed unreadable file, but a blip that healed
    /// in the meantime reads fine, and then the empty buffer publishes.
    public private(set) var isLoaded: Bool = false

    /// Save is reachable only for a buffer with a load behind it AND an
    /// actual edit.
    public var canSave: Bool { isLoaded && hasUnsavedChanges && !isSaving }

    public var hasUnsavedChanges: Bool { isLoaded && text != originalText }

    /// Set when a Save found the file changed on the server since this
    /// editor loaded it (the agent writes MEMORY.md / USER.md itself,
    /// tools/memory_tool_store.py:526 @ v2026.9.24). Holds the on-disk text.
    /// Nothing was written; the view asks the user to reload (take the new
    /// text, dropping the draft) or overwrite (``save(force:)`` with `true`).
    /// Mirrors the Mac editor's `.conflict` path.
    public private(set) var conflictOnDisk: String?

    public init(kind: Kind, context: ServerContext) {
        self.kind = kind
        self.context = context
    }

    public func load() async {
        isLoading = true
        lastError = nil
        // Run the file read on a detached task — `readTextThrowing`
        // blocks on transport I/O, and we don't want the MainActor
        // hanging during a remote SFTP fetch.
        // v2.7 — instrumented for parity with Mac `memory.load`.
        // iOS path is one SFTP read per Memory tab open (per kind:
        // memory / user / soul); the bytes counter shows payload
        // size alongside latency.
        let ctx = context
        let path = kind.path(on: context)
        let result: Result<String?, Error> = await ScarfMon.measureAsync(.diskIO, "ios.memory.load") {
            await Task.detached {
                do {
                    return Result<String?, Error>.success(try ctx.readTextThrowing(path))
                } catch {
                    return Result<String?, Error>.failure(error)
                }
            }.value
        }
        if case .success(.some(let loaded)) = result {
            ScarfMon.event(.diskIO, "ios.memory.load.bytes", count: 0, bytes: loaded.utf8.count)
        }

        switch result {
        case .success(.some(let loaded)):
            text = loaded
            originalText = loaded
            isLoaded = true
            lastError = nil
            conflictOnDisk = nil
        case .success(.none):
            // Genuinely absent file — treat as empty (first-time
            // create). Distinguished from transport error by the
            // fileExists check inside readTextThrowing (pass-1 M7 #7/#8).
            text = ""
            originalText = ""
            isLoaded = true
            lastError = nil
            conflictOnDisk = nil
        case .failure(let error):
            // Transport error (SSH timeout, auth failure, SFTP protocol
            // issue). The buffer is NOT blanked and the editor is NOT armed
            // (GW-F2): `text = ""` here plus a re-arming keystroke is how a
            // blip published an empty MEMORY.md through a guard that had
            // nothing left to refuse. Whatever was last successfully read
            // stays on screen; `load()` is re-issued by the view's `.task`,
            // so a retry is one navigation away.
            isLoaded = false
            lastError = "Couldn't load \(kind.displayName) — \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Save the buffer. The write is refused when the file no longer holds
    /// the text this editor loaded (see ``conflictOnDisk``); `force: true` is
    /// the user's explicit "overwrite" answer to that conflict.
    public func save(force: Bool = false) async -> Bool {
        guard !isSaving else { return false }
        // No proof, no save. The UI disables the button on `canSave`; this is
        // the model-level enforcement so a programmatic caller cannot get
        // past it either (GW-F2).
        guard isLoaded else {
            lastError = "Couldn't save \(kind.displayName) — it hasn't been read yet. Reopen this file to try loading it again."
            return false
        }
        isSaving = true
        lastError = nil
        let ctx = context
        let path = kind.path(on: context)
        let snapshot = text
        let baseline: String? = force ? nil : originalText
        let label = kind.displayName
        // GUARDED — the second of two defences, the first being `isLoaded`
        // above. An EMPTY memory file is a legal state, so only a
        // stat-confirmed unreadable (or non-UTF-8) file is refused here.
        // Deliberately re-reads rather than reusing the load's proof: the
        // editor may have sat open for minutes, and a `.bak` written from a
        // stale inspection would archive bytes the file no longer holds.
        // SERIALIZED (GW-F3): the re-read and the publish are one hold of
        // this file's write lock, on one detached thread. The re-read was
        // already deliberate; the lock is what makes it MEAN something —
        // without it, "read the current bytes, then write" is the same
        // read-modify-write window the Mac side had, just narrower.
        // CONFLICT-CHECKED (S14-F2): the comparison runs against the read
        // taken under the lock, so a memory entry the agent wrote while the
        // editor sat open is never published away. An absent file loads as
        // "" on both sides, so a first-time create still saves.
        let result: Result<String?, Error> = await Task.detached {
            do {
                let file = GuardedTextFile(context: ctx, label: label)
                var conflict: String?
                try file.mutate(path) { loaded in
                    if let baseline, loaded.text != baseline {
                        conflict = loaded.text
                        return nil
                    }
                    return snapshot
                }
                return .success(conflict)
            } catch {
                return .failure(error)
            }
        }.value
        isSaving = false
        switch result {
        case .success(.some(let onDisk)):
            conflictOnDisk = onDisk
            return false
        case .success(.none):
            conflictOnDisk = nil
            originalText = snapshot
            return true
        case .failure(let error):
            lastError = "Couldn't save \(kind.displayName) — \(error.localizedDescription)"
            return false
        }
    }

    /// Revert in-memory edits back to whatever the file contained
    /// at last load.
    public func revert() {
        text = originalText
    }

    /// The user's "reload" answer to a conflict: take the server's text
    /// and drop the draft.
    public func acceptOnDiskVersion() {
        guard let onDisk = conflictOnDisk else { return }
        text = onDisk
        originalText = onDisk
        conflictOnDisk = nil
    }

    /// The user's "keep editing" answer: keep the draft, save nothing yet.
    /// The next Save checks again against the same loaded baseline.
    public func dismissConflict() {
        conflictOnDisk = nil
    }
}
