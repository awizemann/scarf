import Foundation
#if canImport(os)
import os
#endif

/// Owns the sidecar that attributes Hermes session IDs to Scarf
/// project paths. Promoted to ScarfCore in M9 #4.2 so ScarfGo can
/// write project attributions over SFTP — the whole service is
/// transport-based, so Mac and iOS share the same code path.
///
/// File: `~/.hermes/scarf/session_project_map.json` (resolved via
/// `HermesPathSet.sessionProjectMap`).
///
/// Thread safety: all public methods are `nonisolated` and each
/// performs a single read-modify-write cycle that's atomic on
/// disk. Concurrent writers (two Scarf windows on the same
/// `~/.hermes`) are safe at the file level — last write wins —
/// but the in-memory read in one window may lag until that window
/// reloads.
public struct SessionAttributionService: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "SessionAttributionService")
    #endif

    public let context: ServerContext

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Read

    /// Maximum sidecar size, in bytes, that we'll accept off disk /
    /// SFTP. A legitimate `session_project_map.json` is in the tens
    /// of kilobytes even on heavy multi-project setups (one mapping
    /// per session id). Anything north of 1 MB is either corrupt,
    /// truncated, or hostile — we treat it as "no attribution" so a
    /// memory-pressured device doesn't OOM during decode on chat
    /// resume. iOS background launches with only a few hundred MB
    /// of available memory and the TestFlight crash reports
    /// AJy1fD58 / AL8Hjm06 (Berlin, iOS 26.5, 2.87 GB free disk)
    /// suggest memory pressure was implicated in the resume-time
    /// crashes — bounding the read here removes one credible OOM
    /// vector even when the file is legitimate-but-large.
    public static let maxSidecarBytes = 1 * 1024 * 1024

    /// Load the current sidecar contents. Missing file, oversize
    /// file, or unparseable JSON returns an empty map — the sidecar
    /// is a convenience index, not a source of truth for anything
    /// load-bearing.
    public nonisolated func load() -> SessionProjectMap {
        inspect().map
    }

    private nonisolated func store() -> GuardedJSONStore {
        GuardedJSONStore(transport: context.makeTransport(), label: "session_project_map.json")
    }

    /// One read serving both the map and the state of the bytes behind it —
    /// the state `persist` needs to know whether writing would destroy
    /// something. Two reads would be two SFTP round-trips per attribution.
    private nonisolated func inspect() -> (map: SessionProjectMap, inspection: GuardedJSONStore.Inspection) {
        let (inspection, decoded) = store().inspectDecoding(
            SessionProjectMap.self,
            at: context.paths.sessionProjectMap,
            maxBytes: Self.maxSidecarBytes
        )
        return (decoded ?? SessionProjectMap(), inspection)
    }

    /// Look up the project path a given session was attributed to.
    /// Returns nil for unattributed sessions.
    public nonisolated func projectPath(for sessionID: String) -> String? {
        load().mappings[sessionID]
    }

    /// Reverse lookup: every session ID attributed to the given
    /// project path.
    public nonisolated func sessionIDs(forProject projectPath: String) -> Set<String> {
        let map = load()
        return Set(map.mappings.filter { $0.value == projectPath }.keys)
    }

    /// Resolve the project a chat is scoped to, for threading the
    /// project dir into a `hermes acp` spawn (process cwd → AGENTS.md)
    /// and the ACP `session/new` cwd (tool dirs). A caller-known path
    /// wins and costs no I/O; otherwise we fall back to the attribution
    /// recorded for `sessionID` when the chat was first created. Returns
    /// nil for a non-empty-but-unattributed or unknown session — the
    /// caller then uses the user's home (the global-chat default).
    ///
    /// This is the recovery seam for resuming / reconnecting / auto-
    /// starting a project chat, where the project path isn't passed in
    /// by the UI. It reads the sidecar (`load()` → transport I/O, SSH on
    /// remote), so call it OFF the MainActor.
    public nonisolated func resolveProjectPath(known: String?, sessionID: String?) -> String? {
        // A whitespace-only `known` is "no path", not a cwd — but a real
        // path is returned verbatim (a trailing space can be a legitimate
        // directory name on Unix), so we only trim for the emptiness test.
        if let known, !known.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return known
        }
        guard let sessionID else { return nil }
        return projectPath(for: sessionID)
    }

    // MARK: - Write

    /// Record that `sessionID` was created under the given project
    /// path. Idempotent.
    public nonisolated func attribute(sessionID: String, toProjectPath projectPath: String) {
        mutate { map in
            let now = SessionProjectMap.nowISO8601()
            if map.mappings[sessionID] == projectPath {
                // Idempotent, as it has always been — the one exception is
                // a pre-t-3b855719 row that carries no recency stamp: give
                // it one so pruning can rank it, then never write again.
                guard map.touched?[sessionID] == nil else { return false }
                map.touched = (map.touched ?? [:]).merging([sessionID: now]) { _, new in new }
                return true
            }
            map.mappings[sessionID] = projectPath
            map.touched = (map.touched ?? [:]).merging([sessionID: now]) { _, new in new }
            map.updatedAt = now
            return true
        }
    }

    /// Remove a mapping. Exposed for future "detach from project"
    /// UIs and tests; today's Mac + iOS call sites don't invoke it
    /// because Hermes owns session lifecycle.
    public nonisolated func forget(sessionID: String) {
        mutate { map in
            guard map.mappings.removeValue(forKey: sessionID) != nil else { return false }
            map.touched?.removeValue(forKey: sessionID)
            map.updatedAt = SessionProjectMap.nowISO8601()
            return true
        }
    }

    // MARK: - Private

    /// THE SIDECAR CHOKEPOINT. This file is the SOLE record of
    /// session↔project attribution, and every write is a whole-file
    /// read-modify-write. The old shape returned an empty map on ANY read
    /// failure and then wrote that emptiness back over the file — one SFTP
    /// blip on iOS (the likeliest trigger: it shares this exact path) erased
    /// every attribution the install had ever made, silently, with no
    /// backup. Now the read and the write share ONE inspection, a
    /// stat-confirmed twice-failed read REFUSES the write, undecodable
    /// bytes are quarantined before the rebuild, and the replaced bytes
    /// land in `session_project_map.json.bak`.
    ///
    /// Failures stay non-throwing here — attribution is best-effort and its
    /// callers are fire-and-forget — but they are logged, and the refusal
    /// means "did nothing" rather than "destroyed the file".
    ///
    /// **Serialised on this machine, last-write-wins across devices
    /// (t-07e909e0 / DI-M4).** Same story as `MiniAppGrantStore`: the RMW
    /// takes `RegistryWriteLock` on this file's own lock path, which ends
    /// same-machine attribution loss; a Mac and an iPhone on one remote
    /// `~/.hermes` remain unserialised by construction (their locks are
    /// local stand-ins that cannot see each other) and the later write
    /// wins whole-file. Documented in `RegistryWriteLock`'s header, and
    /// tolerable here because an attribution is re-derived on the next
    /// session rather than being the sole record of something the user
    /// created. Non-throwing, like the rest of this path: a lock we could
    /// not take is logged by `withLock` and the mutation is skipped, which
    /// is "did nothing", not "destroyed the file".
    private nonisolated func mutate(_ body: (inout SessionProjectMap) -> Bool) {
        let path = context.paths.sessionProjectMap
        guard let lock = RegistryWriteLock(context: context, path: path) else {
            return mutateLocked(body)
        }
        do {
            try lock.withLock(path: path) { mutateLocked(body) }
        } catch {
            #if canImport(os)
            Self.logger.error("couldn't take the session-project-map write lock at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }

    private nonisolated func mutateLocked(_ body: (inout SessionProjectMap) -> Bool) {
        let path = context.paths.sessionProjectMap
        let (loaded, inspection) = inspect()
        var map = loaded
        guard body(&map) else { return }
        map.prune()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(map)
            try store().write(data, to: path, after: inspection)
        } catch {
            #if canImport(os)
            Self.logger.error("failed to persist session-project-map at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }
}
