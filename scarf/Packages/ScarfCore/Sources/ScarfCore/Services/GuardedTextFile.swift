import Foundation
#if canImport(os)
import os
#endif

/// `GuardedJSONStore`'s discipline for the files that are NOT JSON:
/// `~/.hermes/config.yaml`, `~/.hermes/.env`, `MEMORY.md`, `USER.md`.
///
/// **Why this exists.** Every writer of those files is a whole-file
/// read-modify-write, and each one had grown its OWN copy of the read
/// (`readText(path) ?? ""`, `try? readFile … else header`, `readFile(path)
/// ?? ""`). That is the per-writer disease: the guard gets applied to a
/// FILE by whichever writer someone happened to audit, and the next writer
/// of the same file re-opens the hole. `config.yaml` alone had five
/// independent writers (`KanbanToolsetEnabler` ×2, `HermesFileService`'s MCP
/// patch + its two restores, `SettingsViewModel.saveDirectYAML`,
/// `GatewayConfigWriter.saveList`) and exactly zero of them could tell a
/// dropped SSH round-trip from an empty file — so one blip published a
/// config containing only the section being edited.
///
/// **What it keeps from `GuardedJSONStore`** (see that type's header for the
/// full argument): proof, not inference — a failed read is damage only when
/// a `stat` CONFIRMS the file and a RETRIED read fails too; a write keeps a
/// one-deep `.bak` of the bytes it replaces.
///
/// **What it deliberately changes:**
/// 1. **Zero bytes is a LEGAL state, not damage.** Scarf never writes a
///    zero-length JSON sidecar, so an empty one was truncated by somebody.
///    An empty `.env` or an empty `MEMORY.md` is a real thing a person
///    made, and refusing to write over it would freeze the surface. This is
///    exactly the reclassification `GuardedJSONStore.Inspection`'s public
///    initializer documents. `exists` stays `true` for such a file, so
///    "absent ⇒ create fresh" and "present but empty" remain distinct for
///    callers that care (`.env`'s header line).
/// 2. **Bytes that are not UTF-8 are a REFUSAL, not a rebuild.** These
///    files are hand-authored prose and configuration whose contents exist
///    nowhere else — the `projects.json` rule, not the sidecar rule. We
///    hold bytes we cannot interpret; replacing them would be the same
///    destruction by a slower route.
/// 3. **No `createDirectory` before publishing.** The parents of these four
///    files always exist, none of the writers this replaced created them,
///    and several of these call sites run synchronously on the main actor
///    (C10) where a gratuitous extra round-trip is a hang.
public struct GuardedTextFile: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "GuardedTextFile")
    #endif

    /// What a guarded load found, and the proof a later `write` needs.
    public struct Loaded: Sendable {
        /// The file's text. `""` for both an absent file and an empty one —
        /// check `exists` to tell them apart.
        public let text: String
        /// Whether the file is actually there. `false` only when a `stat`
        /// could not confirm it after the read failed.
        public let exists: Bool
        /// The inspection this load is based on. `write` consumes it rather
        /// than re-reading: a second read would cost another round-trip AND
        /// open a fresh read-then-write window.
        public let inspection: GuardedJSONStore.Inspection

        /// **`internal`, not `public` (GW-F6 / audit DI L5).** A `Loaded` is
        /// the PROOF TOKEN that ``GuardedTextFile/write(_:to:after:)``
        /// consumes: holding one is supposed to mean "a guarded load of this
        /// path succeeded". A public initializer made it forgeable from any
        /// module — `Loaded(text: "", exists: true, inspection: .init(state:
        /// .present, bytes: nil))` and the guard waves through exactly the
        /// blank-buffer publish the token exists to prevent. Keeping the
        /// memberwise init in-module leaves the two legitimate constructors
        /// (`load`, and `SkillsViewModel` re-stamping the token after its own
        /// successful write) working, and gives everything outside ScarfCore
        /// only the honest route: call `load`. Tests reach it with
        /// `@testable import`, which is the intended door.
        init(text: String, exists: Bool, inspection: GuardedJSONStore.Inspection) {
            self.text = text
            self.exists = exists
            self.inspection = inspection
        }
    }

    /// Why a guarded text write was refused. Separate from
    /// `GuardedStoreError` so the "we refused" cases for irreplaceable text
    /// carry their own, user-facing wording.
    public enum Refusal: LocalizedError, Sendable, Equatable {
        /// Stat-confirmed but unreadable (twice), or too large to hold.
        case unreadable(path: String, label: String)
        /// We hold the bytes; they are not UTF-8. Replacing them would
        /// destroy content nobody has seen.
        case notUTF8(path: String, label: String)

        /// **Not localized, by construction.** ScarfCore is a Swift package with
        /// no string catalog (a headless `xcodebuild` never merges keys back into
        /// one, and adding a second catalog to the package would fork the
        /// vocabulary). These sentences reach users VERBATIM through
        /// `localizedDescription` passthrough at the app-side save bars and
        /// banners, so they are written as user-facing English and stay English
        /// in every locale until the package gets a catalog of its own (GW-F4).
        public var errorDescription: String? {
            switch self {
            case let .unreadable(path, label):
                return "\(label) at \(path) exists but couldn't be read; refusing to overwrite it."
            case let .notUTF8(path, label):
                return "\(label) at \(path) isn't valid UTF-8 text; refusing to overwrite it."
            }
        }
    }

    public let transport: any ServerTransport
    /// Short name used in log lines and refusal messages (`"config.yaml"`).
    public let label: String

    /// The context whose ``RegistryWriteLock`` serializes this file's
    /// read-modify-write, or `nil` for an UNSERIALIZED file (GW-F3 / DI H4).
    ///
    /// **Why the lock lives HERE and not at the call sites.** The audit
    /// finding is the same shape as the one this type already exists to fix:
    /// `config.yaml` had five writers and `.env` two, each of which could
    /// interleave its read with another's write and publish a whole file
    /// built from bytes that were already stale — with the one-deep `.bak`
    /// overwritten by the loser, so not even the previous good copy
    /// survived. A lock taken by "whichever writer someone happened to
    /// audit" is the per-writer disease again, one layer up. So the type
    /// that owns the proof owns the serialization: ``mutate(_:maxBytes:_:)``
    /// is a load-mutate-write that CANNOT be entered without the lock, and
    /// the two flows that genuinely need the load and the write split apart
    /// (the memory editor's conflict check, the MCP patcher's
    /// verify-and-restore) take ``withLock(_:acquireTimeout:_:)`` explicitly
    /// around the whole of it. `GuardedTextFileLockCoverageTests` fails the
    /// build if a writer of a protected file reaches `write` any other way.
    ///
    /// **Why it is optional.** Not every file this type guards has a
    /// contention story worth a lock file. See that test's table; the short
    /// version is that the four hermes-GLOBAL files (`config.yaml`, `.env`,
    /// `MEMORY.md`, `USER.md`) have many writers across two processes and
    /// are locked, while the PER-PROJECT and PER-SKILL files
    /// (`AGENTS.md`, `SKILL.md`, a bot's `profile.yaml`) are written by one
    /// user-driven surface each, at paths no second writer shares, and get
    /// no lock rather than a blanket one. The transport-only initializer
    /// keeps that second group exactly as it was.
    ///
    /// **Scope is LOCAL serialization, inherited from `RegistryWriteLock`.**
    /// One host's processes contend on one lock file; two Macs pointed at
    /// one remote `~/.hermes` hold locks in their own Application Support
    /// directories, cannot see each other, and stay last-write-wins. That
    /// residual is accepted and documented, here and there, for the same
    /// reason: an advisory lock ON the remote over SSH needs a
    /// create-exclusive primitive whose stale-lock story across a flaky link
    /// is worse than the race it closes.
    ///
    /// **Lock-file lifecycle**, and why the remote case costs nothing. For a
    /// LOCAL context the lock is `<path>.lock` beside the file, created and
    /// removed with plain POSIX calls; a crashed holder's file is broken by
    /// the staleness bound, and the ownership token stops a late finisher
    /// from deleting its successor's. For a REMOTE context it is a LOCAL
    /// stand-in in Application Support — it never touches the remote host, so
    /// acquiring it adds ZERO SSH round-trips to a remote save (charter C10),
    /// leaves no litter on a host Scarf does not own, and cannot wedge on a
    /// dropped link. The local `.lock` files DO land in `~/.hermes/`, where
    /// the agent can see and write them: the same cooperation-not-integrity
    /// property `RegistryWriteLock` documents at length. They carry a token,
    /// a pid and a timestamp — never file contents — so a `0644` lock file
    /// beside a `0600` `.env` discloses nothing, and `loadMemoryProfiles`
    /// (directories only) and the config readers ignore them.
    public let lockContext: ServerContext?

    /// Generous: these are hand-sized files (a fat `config.yaml` is ~10 KB).
    /// The cap is a sanity bound on holding a runaway file in memory, not a
    /// tuning knob — anything past it is refused, never republished over.
    public static let defaultMaxBytes = 32 * 1024 * 1024

    /// An UNSERIALIZED guarded file: the proof discipline, no lock. Correct
    /// for the per-project and per-skill files (see ``lockContext``), and for
    /// the read-only loads of a protected file — reads do not need to be
    /// serialized against each other, only against a writer, and a reader
    /// that loses that race reads bytes that were true a moment ago.
    public nonisolated init(transport: any ServerTransport, label: String) {
        self.transport = transport
        self.label = label
        self.lockContext = nil
    }

    /// A guarded file whose read-modify-write is SERIALIZED against every
    /// other writer on this machine (GW-F3). Use this for the four
    /// hermes-global files; see ``lockContext``.
    public nonisolated init(context: ServerContext, label: String) {
        self.transport = context.makeTransport()
        self.label = label
        self.lockContext = context
    }

    // MARK: - Serialization

    /// Run `body` holding this file's cross-process write lock.
    ///
    /// A no-op passthrough for an unserialized file, so a call site can take
    /// the scope unconditionally. Reentrant within a thread (the underlying
    /// `RegistryWriteLock` is), which is what lets ``mutate(_:maxBytes:_:)``
    /// be called from inside an outer `withLock` without deadlocking — the
    /// MCP patcher does exactly that.
    ///
    /// **Every hold must be synchronous.** The reentrancy bookkeeping is
    /// thread-local, so a hold that spans an `await` can be released on a
    /// different thread than it was taken on. Callers that need to be off the
    /// main actor put the WHOLE scope inside one `Task.detached`, never the
    /// load in one and the write in another.
    ///
    /// - Parameter acquireTimeout: overrides the context-derived wait bound.
    ///   Exactly one site passes it — see
    ///   ``RegistryWriteLock/withAcquireTimeout(_:)``.
    /// - Throws: `ProjectRegistryError.registryBusy` when the lock could not
    ///   be taken in time — a failure, never a hang — plus whatever `body`
    ///   throws.
    public nonisolated func withLock<T>(
        _ path: String,
        acquireTimeout: TimeInterval? = nil,
        _ body: () throws -> T
    ) throws -> T {
        guard let context = lockContext,
              let base = RegistryWriteLock(context: context, path: path)
        else { return try body() }
        let lock = acquireTimeout.map { base.withAcquireTimeout($0) } ?? base
        // The per-file label the refusal messages already use, so a busy
        // config.yaml says "config.yaml" and not a projects-registry path.
        return try lock.withLock(path: path, label: label, body)
    }

    /// The load-mutate-write entry point: takes the lock, reads WITH PROOF
    /// under it, hands the result to `body`, and publishes whatever `body`
    /// returns — all inside one hold.
    ///
    /// `body` returns `nil` to publish nothing (no change, or a decision to
    /// refuse); the `Bool` result says whether a write happened, which is
    /// what `ProjectContextBlock.removeBlock` and friends report to their
    /// callers.
    ///
    /// This is the shape almost every writer wants, and the reason it exists
    /// is that it is impossible to get the ordering wrong with it: the read
    /// the write is validated against is by construction the read taken
    /// under the same lock.
    @discardableResult
    public nonisolated func mutate(
        _ path: String,
        maxBytes: Int = GuardedTextFile.defaultMaxBytes,
        acquireTimeout: TimeInterval? = nil,
        _ body: (Loaded) throws -> String?
    ) throws -> Bool {
        try withLock(path, acquireTimeout: acquireTimeout) {
            let loaded = try load(path, maxBytes: maxBytes)
            guard let text = try body(loaded) else { return false }
            try write(text, to: path, after: loaded)
            return true
        }
    }

    // MARK: - Read

    /// Read `path` with proof, or throw a `Refusal`.
    ///
    /// A healthy load is still ONE read: the stat + retry probe runs only
    /// after a read has already failed.
    public nonisolated func load(
        _ path: String,
        maxBytes: Int = GuardedTextFile.defaultMaxBytes
    ) throws -> Loaded {
        let store = GuardedJSONStore(transport: transport, label: label)
        let inspection = store.inspect(path, maxBytes: maxBytes)
        switch inspection.state {
        case .absent:
            return Loaded(text: "", exists: false, inspection: inspection)
        case .unreadable(let damagedPath):
            // Rule 1: zero bytes is a legal empty text file, not damage.
            if inspection.bytes?.isEmpty == true {
                return Loaded(
                    text: "",
                    exists: true,
                    inspection: GuardedJSONStore.Inspection(state: .absent, bytes: nil)
                )
            }
            throw Refusal.unreadable(path: damagedPath, label: label)
        case .quarantined:
            // Bytes we held but could not use. Since GW-F5 the size cap is
            // refused stat-first and arrives as `.unreadable` above, so this
            // branch is reached only through a decode-shaped quarantine; the
            // verdict is the same either way — we will not publish a rewrite
            // of a file we never parsed (rule 2's reasoning).
            throw Refusal.unreadable(path: path, label: label)
        case .present:
            guard let bytes = inspection.bytes else {
                throw Refusal.unreadable(path: path, label: label)
            }
            guard let text = String(data: bytes, encoding: .utf8) else {
                #if canImport(os)
                Self.logger.error(
                    "\(self.label, privacy: .public) at \(path, privacy: .public) is not valid UTF-8; refusing to overwrite"
                )
                #endif
                throw Refusal.notUTF8(path: path, label: label)
            }
            return Loaded(text: text, exists: true, inspection: inspection)
        }
    }

    // MARK: - Write

    /// Publish `text` over `path`, keeping a one-deep `.bak` of the bytes it
    /// replaces.
    ///
    /// - Parameter loaded: the load this write is based on. It carries the
    ///   proof that the predecessor was readable — which is why a `Loaded`
    ///   is the only way to reach this method.
    ///
    /// **Call this inside the file's lock** (``mutate(_:maxBytes:_:)`` does
    /// it for you; ``withLock(_:acquireTimeout:_:)`` is the manual form).
    /// This is TWO transport writes — the `.bak` and then the file — and a
    /// lock that covered only the second would let a contender's `.bak`
    /// refresh land between them, so the backup and the bytes it is supposed
    /// to back up come from different writers. Just as important, `loaded`
    /// must be a read taken under the SAME hold: a lock around a write whose
    /// proof came from a read outside it serializes the publish while
    /// leaving the read-modify-write window exactly where it was.
    public nonisolated func write(_ text: String, to path: String, after loaded: Loaded) throws {
        let data = Data(text.utf8)
        if let existing = loaded.inspection.bytes, !existing.isEmpty, existing != data {
            // Best effort: losing the backup is not a reason to fail the
            // write the user asked for.
            do {
                // UNGUARDED-WRITE(G): GuardedTextFile's own one-deep .bak publish.
                try transport.unguardedWriteFile(path + ".bak", data: existing)
            } catch {
                #if canImport(os)
                Self.logger.warning(
                    "Could not refresh \(self.label, privacy: .public).bak: \(error.localizedDescription, privacy: .public)"
                )
                #endif
            }
        }
        // The refusal already happened in `load`, whose proof `loaded` carries.
        // UNGUARDED-WRITE(G): GuardedTextFile's own guarded publish.
        try transport.unguardedWriteFile(path, data: data)
    }
}
