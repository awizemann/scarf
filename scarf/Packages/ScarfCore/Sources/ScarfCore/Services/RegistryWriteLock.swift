import Foundation
#if canImport(os)
import os
#endif

/// Cross-process advisory lock around the WHOLE read-modify-write of
/// `~/.hermes/scarf/projects.json` (t-db8c745b).
///
/// **The race it closes.** `ProjectDashboardService.saveRegistry` inspects
/// the file, refuses if it is damaged, backs it up, then publishes. Between
/// the inspect and the publish there is a window, and since the
/// `scarf-projects` MCP server shipped there are two PROCESSES in it — the
/// app and the helper Hermes spawns — plus ~6 in-app writers. Both sides
/// publish atomically, so nobody sees a torn file; the loser simply
/// disappears, and `.bak` holds the loser's state rather than the user's
/// previous one. A lock on one side only would read as safety while the
/// other side's race stayed open, which is why this is taken at the
/// chokepoint every writer already funnels through.
///
/// **Semantics — deliberately the boring ones.**
/// - **Scope: one host's local filesystem.** For a LOCAL context the lock
///   file sits beside the registry (`projects.json.lock`), so the app and
///   the MCP helper — same user, same `~/.hermes` — contend on the same
///   inode. That is the case the ticket is about: the helper resolves the
///   local home only (`scarf-projects-mcp/main.swift`) and never writes to
///   a remote host.
/// - **Remote contexts get a LOCAL lock** keyed by a digest of
///   `host|path`, in Application Support. Every writer to a remote
///   registry funnels through this app's transports, so serializing this
///   machine's writers is the whole population in practice. Two different
///   Macs writing one remote `~/.hermes` are NOT serialized — an advisory
///   file on the remote would need its own create-exclusive primitive over
///   SSH, and the stale-lock story over a flaky link is worse than the
///   race it would close. Documented rather than half-built.
/// - **Advisory, not mandatory.** Nothing stops a writer that doesn't ask.
///   Every Scarf writer does, because `saveRegistry` is the only door.
/// - **Stale locks are broken, not waited on.** A crashed holder must not
///   brick the registry: a lock whose mtime is older than
///   ``staleAfter`` (30s — three orders of magnitude over a real write) is
///   removed and re-contended. A live holder refreshes nothing because it
///   never holds the lock that long.
/// - **Waiting is bounded** at ``acquireTimeout`` (2s). Registry writes are
///   milliseconds; two seconds of contention means something is wedged,
///   and `registryBusy` — a failure the caller reports — beats both a
///   frozen main actor (charter C10) and a silent clobber.
public struct RegistryWriteLock: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "RegistryWriteLock")
    #endif

    /// How long a lock file may go untouched before a contender treats it
    /// as abandoned and removes it.
    public static let staleAfter: TimeInterval = 30

    /// How long a contender waits before giving up with `registryBusy`.
    public static let acquireTimeout: TimeInterval = 2

    /// Poll interval while waiting. Short enough that an uncontended
    /// hand-off costs a millisecond, long enough not to spin a core.
    private static let pollInterval: TimeInterval = 0.01

    private let lockURL: URL

    /// The lock covering `context`'s registry. Never throws: a context we
    /// cannot derive a lock path for yields `nil` and the caller proceeds
    /// unlocked (the pre-t-db8c745b behaviour) rather than losing the
    /// ability to save.
    public nonisolated init?(context: ServerContext) {
        guard let url = Self.lockURL(for: context) else { return nil }
        self.lockURL = url
    }

    nonisolated init(lockURL: URL) {
        self.lockURL = lockURL
    }

    /// Where this context's lock lives. LOCAL → beside the registry, so a
    /// second process resolving the same home lands on the same file.
    /// REMOTE → a local stand-in named for the remote identity.
    static func lockURL(for context: ServerContext) -> URL? {
        let registry = context.paths.projectsRegistry
        if !context.isRemote {
            return URL(fileURLWithPath: registry + ".lock")
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Scarf/locks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var host = ""
        if case .ssh(let config) = context.kind { host = config.host }
        return dir.appendingPathComponent(Self.digest("\(host)|\(registry)") + ".lock")
    }

    /// A short, filename-safe, stable digest. Not cryptographic — it names
    /// a lock file, and a collision would only over-serialize two remotes.
    static func digest(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(string.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }

    // MARK: - Acquire / release

    /// Run `body` holding the lock. Releases on every path, including a
    /// throw from `body`.
    ///
    /// **Reentrant within a thread.** The multi-step writers take it around
    /// their WHOLE read-modify-write (`ProjectStore.indexInRegistry` reads
    /// the registry, edits a row, then calls `saveRegistry`, which takes it
    /// again) — and a lock that covered only the innermost publish would
    /// leave exactly the window this exists to close. Every one of these
    /// calls is synchronous and `nonisolated`, so there is no suspension
    /// point between the acquire and the release and a thread-local depth
    /// is the whole bookkeeping needed. The file lock is created by the
    /// OUTERMOST scope and removed when it exits.
    ///
    /// - Throws: `ProjectRegistryError.registryBusy` when the lock could
    ///   not be taken within ``acquireTimeout``; whatever `body` throws.
    public nonisolated func withLock<T>(path: String, _ body: () throws -> T) throws -> T {
        let key = "com.scarf.registryWriteLock." + lockURL.path
        let dictionary = Thread.current.threadDictionary
        if let depth = dictionary[key] as? Int, depth > 0 {
            dictionary[key] = depth + 1
            defer { dictionary[key] = (dictionary[key] as? Int ?? 1) - 1 }
            return try body()
        }
        try acquire(describing: path)
        dictionary[key] = 1
        defer {
            dictionary[key] = 0
            release()
        }
        return try body()
    }

    private nonisolated func acquire(describing path: String) throws {
        let deadline = Date().addingTimeInterval(Self.acquireTimeout)
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        while true {
            if tryCreate() { return }
            breakIfStale()
            if Date() >= deadline {
                #if canImport(os)
                Self.logger.error(
                    "Could not take the registry write lock at \(self.lockURL.path, privacy: .public) within \(Self.acquireTimeout)s"
                )
                #endif
                throw ProjectRegistryError.registryBusy(path: path)
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
    }

    /// `O_CREAT | O_EXCL` — the create either wins or reports EEXIST, with
    /// no window between the test and the create. The payload is
    /// diagnostic only; correctness rests on the flag, not the contents.
    private nonisolated func tryCreate() -> Bool {
        let fd = lockURL.withUnsafeFileSystemRepresentation { rep -> Int32 in
            guard let rep else { return -1 }
            return open(rep, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        }
        guard fd >= 0 else { return false }
        let payload = "pid=\(ProcessInfo.processInfo.processIdentifier) at=\(ISO8601DateFormatter().string(from: Date()))\n"
        _ = payload.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        return true
    }

    private nonisolated func breakIfStale() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: lockURL.path),
              let modified = attrs[.modificationDate] as? Date
        else { return }
        guard Date().timeIntervalSince(modified) > Self.staleAfter else { return }
        #if canImport(os)
        Self.logger.warning(
            "Breaking a stale registry write lock at \(self.lockURL.path, privacy: .public) (held since \(modified, privacy: .public))"
        )
        #endif
        // A racing contender may remove it first; that is a win, not an
        // error, and the next tryCreate settles who gets it.
        try? FileManager.default.removeItem(at: lockURL)
    }

    private nonisolated func release() {
        try? FileManager.default.removeItem(at: lockURL)
    }
}
