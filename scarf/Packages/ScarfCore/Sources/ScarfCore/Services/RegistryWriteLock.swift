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
///   brick the registry: a lock whose mtime is older than ``staleAfter``
///   is removed and re-contended.
/// - **Waiting is bounded** at ``acquireTimeout``, after which
///   `registryBusy` — a failure the caller reports — beats both a frozen
///   caller (charter C10) and a silent clobber.
///
/// **Both bounds are CONTEXT-AWARE (t-07e909e0 / DI-M5).** They used to be
/// 30s and 2s flat, which are local-filesystem facts: a local registry
/// write is microseconds, so 30s means "crashed" and 2s means "wedged".
/// Applied to a REMOTE context they are simply wrong. One remote save is
/// an inspect + a `.bak` scp + a staged scp + a rename over SSH — the
/// audit measured windows around 60s on a poor link. So a legitimate
/// holder was routinely declared stale (which is how DI-H4 got its teeth:
/// its lock was broken, the successor took the lock, and the original
/// holder's `release()` then deleted the SUCCESSOR's file), and an honest
/// contender hit `registryBusy` in normal use. Remote gets
/// ``remoteStaleAfter`` (5 min — comfortably above the worst save we have
/// seen) and ``remoteAcquireTimeout`` (60s — the worst-case hold, so a
/// concurrent save waits its turn instead of reporting a fake failure).
///
/// **Why a big `staleAfter` and not a holder heartbeat.** A heartbeat
/// (the holder touching the lock's mtime every few seconds while it
/// scps) would let the stale bound stay small, but it needs a timer or a
/// thread running alongside a synchronous write, on every platform, with
/// its own teardown-on-throw story — and it writes to the lock file
/// concurrently with contenders reading it. The boring option is a bigger
/// number: no extra thread, no extra writes, nothing to leak. What it
/// costs is that a genuinely crashed remote holder wedges contenders for
/// up to 5 minutes instead of 30 seconds. That is bounded, rare, and
/// recoverable (the file is removable by hand), and the ownership token
/// below means the eventual break can no longer damage the successor.
///
/// **The lock file is AGENT-WRITABLE — it is cooperation, not integrity
/// (SEC-M5).** For a local context it sits in `~/.hermes/scarf/`, a
/// directory the agent Scarf fronts reads and writes freely. Anything
/// with write access there can create the lock and hold it (a denial of
/// service — every Scarf registry write reports `registryBusy` until the
/// staleness bound expires and breaks it), or delete a live holder's lock
/// (re-opening exactly the race this closes for one write). Neither is
/// defended against, and neither can be: an advisory file lock in a
/// directory the adversary owns is a protocol between COOPERATING
/// writers — Scarf's app process and Scarf's `scarf-projects` MCP helper
/// — and nothing more. The integrity layer against a hostile writer is
/// elsewhere and unchanged: `saveRegistry` inspects the file inside the
/// lock and REFUSES to publish over damage, over an unexpected
/// fingerprint (`expecting:`), or over a non-empty registry with an empty
/// one. Those refusals hold whether or not the lock was honoured. Read
/// this type as "two of our own processes don't stomp on each other",
/// never as "the registry cannot be corrupted".
///
/// **Who takes it (t-07e909e0 / DI-H5).** Every read-modify-write of a
/// registry-shaped file, around the WHOLE of the RMW, not just its publish:
/// `ProjectDashboardService.saveRegistry`, `ProjectStore.indexInRegistry`,
/// `ProjectDoctorService.repair` (once per repair — `repairAllSafe` does
/// NOT hold one lock across the pass, so each repair re-reads a registry a
/// concurrent writer may have changed), `ProjectTemplateInstaller`'s
/// registration, `ProjectTemplateUninstaller`'s row removal,
/// `RemoteRestoreService`'s path re-anchor, and the two guarded sidecars
/// (`MiniAppGrantStore`, `SessionAttributionService`) on their own lock
/// files. Every one of those is a synchronous, `nonisolated` frame: the
/// reentrancy below is thread-local, so a hold must never span an `await`.
///
/// **The sidecars, and what is NOT serialised (DI-M4).** The grants file
/// and the session→project map are the same whole-file RMW shape, so the
/// macOS/iOS writers take this lock at their own `mutate` chokepoints —
/// cheap, since it lives next door — which removes same-machine
/// attribution loss. What remains last-write-wins BY CONSTRUCTION is a
/// second DEVICE: an iPhone and a Mac pointed at one remote `~/.hermes`
/// hold their locks in their own Application Support directories and
/// cannot see each other, so the later write of an interleaved pair wins
/// whole-file and the earlier device's grant or attribution is gone.
/// Serialising that needs a create-exclusive primitive ON the remote over
/// SSH, whose stale-lock story across a flaky cellular link is worse than
/// the loss it would prevent. Stated, not half-built — and both sidecars
/// are recoverable by construction (a dropped grant re-prompts, a dropped
/// attribution is re-derived), which is why the registry also gets
/// `expecting:` and they do not.
public struct RegistryWriteLock: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "RegistryWriteLock")
    #endif

    /// Staleness bound for a LOCAL target: three orders of magnitude over
    /// a real local write.
    public static let localStaleAfter: TimeInterval = 30

    /// Staleness bound for a REMOTE target. Above the worst-case save
    /// (inspect + two scps + a rename over a bad link), so a live holder
    /// is never mistaken for a dead one.
    public static let remoteStaleAfter: TimeInterval = 300

    /// Wait bound for a LOCAL target.
    public static let localAcquireTimeout: TimeInterval = 2

    /// Wait bound for a REMOTE target: matched to the worst-case hold, so
    /// a second writer queues rather than reporting `registryBusy` for
    /// what is ordinary SSH latency.
    ///
    /// A caller blocked here for 60s was already going to block for ~60s
    /// on its own write, so this does not introduce a class of stall the
    /// remote path did not have — which is why it can be this large
    /// without arguing with charter C10.
    public static let remoteAcquireTimeout: TimeInterval = 60

    /// Poll interval while waiting. Short enough that an uncontended
    /// hand-off costs a millisecond, long enough not to spin a core.
    private static let pollInterval: TimeInterval = 0.01

    private let lockURL: URL

    /// How long a lock file may go untouched before a contender treats it
    /// as abandoned and removes it.
    public let staleAfter: TimeInterval

    /// How long a contender waits before giving up with `registryBusy`.
    public let acquireTimeout: TimeInterval

    /// The lock covering `path` on `context` (the projects registry by
    /// default). Never throws: a context we cannot derive a lock path for
    /// yields `nil` and the caller proceeds unlocked (the pre-t-db8c745b
    /// behaviour) rather than losing the ability to save.
    ///
    /// - Parameter path: the file being read-modify-written. Defaults to
    ///   `projects.json`; the guarded sidecars (`miniapp_grants.json`,
    ///   `session_project_map.json`) pass their own path so each file gets
    ///   its OWN lock rather than serialising against the registry.
    public nonisolated init?(context: ServerContext, path: String? = nil) {
        guard let url = Self.lockURL(for: context, path: path) else { return nil }
        self.lockURL = url
        self.staleAfter = context.isRemote ? Self.remoteStaleAfter : Self.localStaleAfter
        self.acquireTimeout = context.isRemote ? Self.remoteAcquireTimeout : Self.localAcquireTimeout
    }

    nonisolated init(
        lockURL: URL,
        staleAfter: TimeInterval = RegistryWriteLock.localStaleAfter,
        acquireTimeout: TimeInterval = RegistryWriteLock.localAcquireTimeout
    ) {
        self.lockURL = lockURL
        self.staleAfter = staleAfter
        self.acquireTimeout = acquireTimeout
    }

    /// Where this context's lock lives. LOCAL → beside the target file, so
    /// a second process resolving the same home lands on the same file.
    /// REMOTE → a local stand-in named for the remote identity.
    static func lockURL(for context: ServerContext, path: String? = nil) -> URL? {
        let registry = path ?? context.paths.projectsRegistry
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
        guard let token = try acquire(describing: path) else {
            // The lock file cannot be CREATED here (unwritable or missing
            // parent — not contention, which is EEXIST). Proceeding
            // unlocked mirrors the nil-lockURL policy above: losing the
            // ability to save is worse than losing the serialization.
            return try body()
        }
        dictionary[key] = 1
        defer {
            dictionary[key] = 0
            release(token: token)
        }
        return try body()
    }

    /// Acquire, returning the ownership token written into the lock file.
    /// Acquire, returning the token — or `nil` when the lock file cannot
    /// exist here at all (create fails with something other than EEXIST),
    /// in which case the caller proceeds unlocked.
    private nonisolated func acquire(describing path: String) throws -> String? {
        let token = UUID().uuidString
        let deadline = Date().addingTimeInterval(acquireTimeout)
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        while true {
            switch tryCreate(token: token) {
            case .acquired: return token
            case .unlockable(let err):
                #if canImport(os)
                Self.logger.warning(
                    "Registry lock at \(self.lockURL.path, privacy: .public) cannot be created (errno \(err)); proceeding unlocked"
                )
                #endif
                return nil
            case .held: break
            }
            breakIfStale()
            if Date() >= deadline {
                #if canImport(os)
                Self.logger.error(
                    "Could not take the registry write lock at \(self.lockURL.path, privacy: .public) within \(self.acquireTimeout)s"
                )
                #endif
                throw ProjectRegistryError.registryBusy(path: path)
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
    }

    /// `O_CREAT | O_EXCL` — the create either wins or reports EEXIST, with
    /// no window between the test and the create. Exclusivity rests on the
    /// flag, not the contents; the contents carry the OWNERSHIP TOKEN that
    /// `release` checks, plus a pid and a timestamp for a human reading the
    /// file during an incident.
    private enum CreateResult {
        case acquired
        /// EEXIST — someone holds it; contend.
        case held
        /// Any other errno — the lock file cannot live here (missing or
        /// unwritable parent, read-only volume). Not contention.
        case unlockable(Int32)
    }

    private nonisolated func tryCreate(token: String) -> CreateResult {
        let fd = lockURL.withUnsafeFileSystemRepresentation { rep -> Int32 in
            guard let rep else { return -1 }
            return open(rep, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        }
        guard fd >= 0 else {
            return errno == EEXIST ? .held : .unlockable(errno)
        }
        let payload = """
            owner=\(token)
            pid=\(ProcessInfo.processInfo.processIdentifier)
            at=\(ISO8601DateFormatter().string(from: Date()))

            """
        _ = payload.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        return .acquired
    }

    /// The `owner=` token in the lock file on disk, if it has one. A lock
    /// written by an older Scarf (or by anything else) has none, and is
    /// therefore never ours to remove.
    static func ownerToken(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("owner=") {
            return String(line.dropFirst("owner=".count))
        }
        return nil
    }

    private nonisolated func breakIfStale() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: lockURL.path),
              let modified = attrs[.modificationDate] as? Date
        else { return }
        guard Date().timeIntervalSince(modified) > staleAfter else { return }
        #if canImport(os)
        Self.logger.warning(
            "Breaking a stale registry write lock at \(self.lockURL.path, privacy: .public) (held since \(modified, privacy: .public))"
        )
        #endif
        // A racing contender may remove it first; that is a win, not an
        // error, and the next tryCreate settles who gets it.
        try? FileManager.default.removeItem(at: lockURL)
    }

    /// Remove the lock — but ONLY if the file present is still the one this
    /// holder created (DI-H4).
    ///
    /// `release()` used to remove whatever was there. That is fine while
    /// nothing ever breaks a live lock, and it was a data-loss bug the
    /// moment something did: a remote save legitimately holding the lock
    /// past the old 30s staleness bound had it broken by a contender, the
    /// contender created its OWN lock, and then the first holder finished
    /// and deleted the contender's file — after which two writers ran the
    /// registry's read-modify-write concurrently with nothing serialising
    /// them, which is the exact race the type exists to close.
    ///
    /// Now the token decides. Ours → remove. Somebody else's, or an
    /// ownerless lock we did not write → log and walk away; the rightful
    /// owner removes it, and if there is no rightful owner the staleness
    /// bound collects it. Never a throw: release runs from a `defer` on the
    /// error path too, and a failure to tidy up must not mask the caller's
    /// own error.
    ///
    /// The read-then-remove is itself a hair-thin TOCTOU (a contender could
    /// break the lock as stale between the two). Left as is on purpose:
    /// closing it needs an atomic compare-and-delete no POSIX filesystem
    /// offers, the window is microseconds against a staleness bound of
    /// tens of seconds, and the outcome is the old behaviour rather than a
    /// new one. The check removes the systematic case (a whole slow write's
    /// worth of window), which is the one that actually fired.
    private nonisolated func release(token: String) {
        let onDisk = Self.ownerToken(atPath: lockURL.path)
        guard onDisk == token else {
            #if canImport(os)
            Self.logger.warning(
                "Not releasing the registry write lock at \(self.lockURL.path, privacy: .public): it is no longer ours (probably broken as stale and re-taken). Leaving it to its owner."
            )
            #endif
            return
        }
        try? FileManager.default.removeItem(at: lockURL)
    }
}
