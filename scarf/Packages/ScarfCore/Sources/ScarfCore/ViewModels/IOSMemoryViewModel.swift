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

    public var hasUnsavedChanges: Bool { text != originalText }

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
            lastError = nil
        case .success(.none):
            // Genuinely absent file — treat as empty (first-time
            // create). Distinguished from transport error by the
            // fileExists check inside readTextThrowing (pass-1 M7 #7/#8).
            text = ""
            originalText = ""
            lastError = nil
        case .failure(let error):
            // Transport error (SSH timeout, auth failure, SFTP
            // protocol issue). Surface to the UI so the user
            // understands this isn't just "empty file" — something's
            // genuinely broken with the connection.
            text = ""
            originalText = ""
            lastError = "Couldn't load \(kind.displayName) — \(error.localizedDescription)"
        }
        isLoading = false
    }

    public func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        lastError = nil
        let ctx = context
        let path = kind.path(on: context)
        let snapshot = text
        let label = kind.displayName
        // GUARDED. `load()` sets `text = ""` on a transport failure and Save
        // stays armed, so an unguarded write here published that empty
        // buffer over the file. An EMPTY memory file is a legal state, so
        // only a stat-confirmed unreadable (or non-UTF-8) file is refused.
        let result: Result<Void, Error> = await Task.detached {
            do {
                let file = GuardedTextFile(
                    transport: ctx.makeTransport(), label: label
                )
                let loaded = try file.load(path)
                try file.write(snapshot, to: path, after: loaded)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        isSaving = false
        switch result {
        case .success:
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
}
