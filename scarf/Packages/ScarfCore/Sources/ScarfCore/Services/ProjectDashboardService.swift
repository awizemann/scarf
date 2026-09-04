import Foundation
import os

public struct ProjectDashboardService: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectDashboardService")

    /// Size ceiling for JSON files we read off SFTP/disk. Both the
    /// registry and individual dashboards are tens-of-KB even on
    /// heavy multi-project setups (one row per project; one widget
    /// list per dashboard). Anything north of 4 MB is either
    /// corrupt or hostile, and decoding it on a memory-pressured
    /// device — the kind that produces the iOS resume-time crashes
    /// in TestFlight feedback AJy1fD58 / AL8Hjm06 (Berlin, iOS 26.5,
    /// 2.87 GB free disk) — risks an OOM kill before the
    /// JSONDecoder can even bail. We treat oversize files as
    /// "missing" so the caller's fallback path runs.
    public static let maxJSONBytes = 4 * 1024 * 1024

    public let context: ServerContext
    public let transport: any ServerTransport

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    // MARK: - Registry

    /// Registry load outcome, including whatever damage the decode had
    /// to work around. `loadRegistry()` throws this detail away; the
    /// surfaces that want to tell the user ("Projects registry is
    /// damaged — Repair") call `loadRegistryDetailed()`.
    public struct RegistryLoadResult: Sendable {
        public var registry: ProjectRegistry
        public var salvage: RegistrySalvageReport
        /// Path the unreadable file was copied to, when the file could
        /// not be parsed as a registry at all. `nil` otherwise.
        public var quarantinePath: String?
        /// The file existed but produced no usable bytes — zero-length or
        /// a failed read. `registry` is empty in that case, and that
        /// emptiness is a lie about the file, not a fact about it.
        /// Carries the path so `loss` can name it.
        public var unreadablePath: String?
        /// The registry file this result describes. Carried so `loss` can
        /// name the file in a message the user has to act on.
        public var registryPath: String
        /// Cheap fingerprint of the BYTES this result was decoded from, or
        /// `nil` when the file wasn't there / produced none.
        ///
        /// The one thing a caller needs to answer "is the file still what I
        /// read?" at write time. `saveRegistry(_:expecting:)` compares it;
        /// see `refusedStaleOverwrite`. Not a security digest — it exists
        /// to catch a concurrent writer, not to resist one.
        public var contentFingerprint: String?

        public init(
            registry: ProjectRegistry,
            salvage: RegistrySalvageReport = .clean,
            quarantinePath: String? = nil,
            unreadablePath: String? = nil,
            registryPath: String = "",
            contentFingerprint: String? = nil
        ) {
            self.registry = registry
            self.salvage = salvage
            self.quarantinePath = quarantinePath
            self.unreadablePath = unreadablePath
            self.registryPath = registryPath
            self.contentFingerprint = contentFingerprint
        }

        /// `true` when the file on disk did not read cleanly — a row or
        /// field was dropped, the file was quarantined, or its bytes were
        /// unusable. This is the BANNER's question ("tell the user
        /// something happened"), NOT the write guard's: field-level
        /// salvage is worth saying out loud and is not worth blocking on.
        public var salvaged: Bool {
            !salvage.isClean || quarantinePath != nil || unreadablePath != nil
        }

        /// Why writing this registry back would DESTROY something, or
        /// `nil` when a rewrite is safe. The single definition of "lossy"
        /// (see `RegistryLoss`) — every refusal in the app asks this, and
        /// `saveRegistry` enforces it whether or not a caller remembered.
        public var loss: RegistryLoss? {
            if let quarantinePath { return .quarantined(path: quarantinePath) }
            if let unreadablePath { return .unreadable(path: unreadablePath) }
            if salvage.droppedCount > 0 {
                return .rowsDropped(count: salvage.droppedCount, path: registryPath)
            }
            return nil
        }

        public var droppedCount: Int { salvage.droppedCount }
    }

    public func loadRegistry() -> ProjectRegistry {
        loadRegistryDetailed().registry
    }

    public func loadRegistryDetailed() -> RegistryLoadResult {
        // Tracks time spent reading + decoding projects.json from the transport
        // (local file or SSH). Helps spot slow remote round-trips.
        ScarfMon.measure(.diskIO, "dashboard.loadRegistry") {
            inspectRegistry().result
        }
    }

    /// The registry as it is on disk, plus the raw bytes behind it.
    ///
    /// One read serves three questions `saveRegistry` has to answer — is
    /// this file lossy, how many projects does it still hold, and what
    /// should the `.bak` capture — so a save costs the same single read it
    /// always did rather than one per question.
    private func inspectRegistry() -> (result: RegistryLoadResult, bytes: Data?) {
        let path = context.paths.projectsRegistry
        var read = try? transport.readFile(path)
        if read == nil {
            // ABSENT vs UNREADABLE, and the answer gates every write in the
            // app, so it takes PROOF rather than an inference.
            //
            // A registry that isn't there is the normal first-launch state
            // and must stay writable. A file that is there but won't read is
            // damage: handing back a clean-looking empty list is what let a
            // save persist that emptiness over the user's projects.
            //
            // Two things make this safe on a remote context, where
            // `readFile` is `cat` over SSH and a dropped connection, a
            // timeout or a re-auth all look exactly like a read failure:
            //
            // 1. `stat` has to CONFIRM the file. No stat, no damage — a
            //    transport too sick to stat is reported as absent, which
            //    refuses nothing (the write then fails on its own with the
            //    real transport error rather than a misleading refusal).
            // 2. The read is RETRIED once past a confirming stat. A blip
            //    that took out one `cat` rarely takes out the retry too, so
            //    a healthy remote file stops being reported as damage —
            //    which would otherwise have frozen every registry write
            //    until the next successful load.
            //
            // Both probes run only on the failure path; a healthy load is
            // still exactly one read.
            guard let info = transport.stat(path) else {
                return (RegistryLoadResult(registry: ProjectRegistry(projects: []), registryPath: path), nil)
            }
            read = try? transport.readFile(path)
            if read == nil {
                Self.logger.error(
                    "Project registry at \(path, privacy: .public) exists (\(info.size) bytes) but could not be read twice; treating as damaged"
                )
                return (
                    RegistryLoadResult(
                        registry: ProjectRegistry(projects: []), unreadablePath: path, registryPath: path
                    ),
                    nil
                )
            }
        }
        guard let data = read else {
            return (RegistryLoadResult(registry: ProjectRegistry(projects: []), registryPath: path), nil)
        }
        guard !data.isEmpty else {
            // Zero bytes is never something Scarf writes (the smallest
            // registry it encodes is `{"projects":[]}`), so it is a
            // truncation by somebody else — damage, not an empty list.
            Self.logger.error(
                "Project registry at \(path, privacy: .public) is zero bytes; treating as damaged"
            )
            return (RegistryLoadResult(registry: ProjectRegistry(projects: []), unreadablePath: path, registryPath: path), data)
        }
        var decoded = decodeRegistry(data: data, path: path)
        decoded.contentFingerprint = Self.fingerprint(data)
        return (decoded, data)
    }

    /// FNV-1a over the file's bytes, prefixed with its length.
    ///
    /// Deliberately not a cryptographic hash: both sides of every
    /// comparison are produced by this process within seconds of each
    /// other, and the question is "did these bytes change", not "can an
    /// attacker forge a collision". Cheap enough to run on every registry
    /// read without thinking about it.
    nonisolated static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return "\(data.count):\(String(hash, radix: 16))"
    }

    private func decodeRegistry(data: Data, path: String) -> RegistryLoadResult {
        if data.count > Self.maxJSONBytes {
            Self.logger.warning(
                "Project registry at \(path, privacy: .public) is \(data.count) bytes (cap \(Self.maxJSONBytes)); treating as missing"
            )
            // Quarantined like any other unusable file: we are about
            // to hand callers an empty registry, and the next save
            // would otherwise write over content we never read.
            return unusable(data: data, path: path)
        }
        do {
            let (registry, salvage) = try ProjectRegistry.decodeSalvaging(from: data)
            if !salvage.isClean {
                Self.logger.warning(
                    "Project registry salvaged: dropped \(salvage.droppedCount) row(s), dropped fields \(salvage.salvagedFields.joined(separator: ", "), privacy: .public)"
                )
            }
            return RegistryLoadResult(registry: registry, salvage: salvage, registryPath: path)
        } catch {
            Self.logger.error("Failed to decode project registry: \(error.localizedDescription, privacy: .public)")
            return unusable(data: data, path: path)
        }
    }

    /// A file we hold bytes for but cannot use: quarantine it and report
    /// the damage.
    ///
    /// If the quarantine copy itself fails to write, the result is marked
    /// `unreadable` instead — otherwise a failed copy would leave a load
    /// that looks CLEAN and empty (no quarantine path, no dropped rows),
    /// and the next save would overwrite bytes that now exist nowhere else.
    private func unusable(data: Data, path: String) -> RegistryLoadResult {
        if let quarantine = quarantineRegistry(data: data, path: path) {
            return RegistryLoadResult(
                registry: ProjectRegistry(projects: []),
                quarantinePath: quarantine,
                registryPath: path
            )
        }
        return RegistryLoadResult(
            registry: ProjectRegistry(projects: []),
            unreadablePath: path,
            registryPath: path
        )
    }

    /// Copy an unparseable registry aside as `projects.json.corrupt-<ts>`
    /// so the bytes survive whatever the app writes next, and return
    /// where it landed. Goes through `transport`, so it works the same
    /// over SSH as locally.
    ///
    /// Deduplicated against existing quarantine copies: `loadRegistry`
    /// runs on every sidebar refresh and watcher tick, and a corrupt
    /// file stays corrupt until a human fixes it — one copy per load
    /// would bury the directory.
    private func quarantineRegistry(data: Data, path: String) -> String? {
        // Shared with every other guarded sidecar (grants, session map) —
        // the dedup-by-size-then-bytes and the filename-safe stamp are one
        // implementation in `GuardedJSONStore`, not a copy per store.
        GuardedJSONStore.quarantine(
            data: data, path: path, transport: transport, label: "projects.json"
        )
    }

    /// Filename-safe UTC stamp (`20260903T142530Z`). Deliberately not
    /// ISO-8601-with-colons: those are legal on APFS but not on every
    /// remote filesystem Scarf writes to over SSH.
    static func quarantineStamp(_ date: Date) -> String {
        GuardedJSONStore.quarantineStamp(date)
    }

    /// Persist the project registry to `~/.hermes/scarf/projects.json`.
    ///
    /// **Throws** on every non-success path — the previous version of
    /// this method silently swallowed `createDirectory` and `writeFile`
    /// failures with `try?`, which meant the installer could return a
    /// valid-looking `ProjectEntry` while the registry on disk never
    /// received the new row (project would complete install, show a
    /// success screen, then be invisible in the sidebar). Callers that
    /// want fire-and-forget behaviour can still use `try?`, but the
    /// choice is now theirs.
    /// - Parameter allowEmpty: pass `true` only for a DELIBERATE
    ///   emptying of the registry — the user removing their last
    ///   project, or an uninstall taking the last row with it. The
    ///   default refuses, because the dangerous empty save is the
    ///   accidental one: a load that failed for any reason hands the
    ///   caller `[]`, and the caller's next mutation would persist that
    ///   emptiness over a file full of real projects.
    ///
    /// **THE CHOKEPOINT.** Every registry write in the app lands here
    /// (`ProjectStore.indexInRegistry` included), so this is where the
    /// lossy-write refusal belongs — not at call sites. It used to live in
    /// `ProjectsViewModel.registryForMutation`, the doctor and the MCP
    /// tools, which left five writers with no guard at all: the cockpit's
    /// `try? store.save(derived)`, `ProjectUpgradeService`, the template
    /// installer (twice) and `FleetApplyExecutor` could all persist a
    /// salvaged short list over a file that still held the missing rows.
    /// Guarding here means a forgotten call site now silently does
    /// NOTHING instead of silently destroying something. Call-site checks
    /// that survive exist only to say it better (a named verb, an alert),
    /// never to be the enforcement.
    ///
    /// - Throws: `ProjectRegistryError.refusedLossyOverwrite` when the file
    ///   currently on disk lost rows, was quarantined, or is unreadable
    ///   (see `RegistryLoss`); `.refusedEmptyOverwrite` per `allowEmpty`.
    /// - Parameter expecting: the `contentFingerprint` of the load this
    ///   write is based on. When supplied, the write is REFUSED if the file
    ///   on disk no longer matches it — somebody else changed it in
    ///   between, and this write would erase their change.
    ///
    ///   `RegistryWriteLock` already serialises same-machine writers, so
    ///   this is about the case a local lock cannot see: a REMOTE registry,
    ///   where the read and the write are seconds apart over SSH. A cheap
    ///   comparison, not a protocol — there is no negotiation, no merge,
    ///   and no retry here. Callers that pass `nil` (an installer writing a
    ///   registry it just built, a caller with no baseline) behave exactly
    ///   as before.
    public func saveRegistry(
        _ registry: ProjectRegistry, allowEmpty: Bool = false, expecting: String? = nil
    ) throws {
        let path = context.paths.projectsRegistry
        // Encode BEFORE touching the filesystem, so an encode failure
        // can't leave a half-updated directory behind — and before the
        // lock, so a doomed write never contends for it.
        let writeData = try Self.encodeRegistry(registry)

        // CROSS-PROCESS LOCK (t-db8c745b). Everything from the inspect to
        // the publish happens inside it: without one, the refusal above is
        // a TOCTOU against the `scarf-projects` MCP helper — both sides
        // inspect a healthy file, both publish atomically, and the loser's
        // rows are gone with `.bak` holding the loser's state rather than
        // the user's previous one. Reentrant, so `indexInRegistry` can hold
        // it across its own read-modify-write. A context with no derivable
        // lock path proceeds unlocked rather than losing the ability to
        // save at all.
        guard let lock = RegistryWriteLock(context: context) else {
            return try saveRegistryLocked(
                writeData, registry: registry, allowEmpty: allowEmpty, path: path,
                expecting: expecting
            )
        }
        try lock.withLock(path: path) {
            try saveRegistryLocked(
                writeData, registry: registry, allowEmpty: allowEmpty, path: path,
                expecting: expecting
            )
        }
    }

    private func saveRegistryLocked(
        _ writeData: Data, registry: ProjectRegistry, allowEmpty: Bool, path: String,
        expecting: String? = nil
    ) throws {
        // ONE read of what is already there, answering all three
        // questions below. Reading per question would also mean three
        // SSH round-trips per save on a remote context.
        let (existingState, existingBytes) = inspectRegistry()

        // 1. Never write over damage: the rows we could not read exist
        //    only in that file, and this write would be their end.
        if let loss = existingState.loss {
            throw ProjectRegistryError.refusedLossyOverwrite(path: path, loss: loss)
        }

        // 1b. Never write over somebody ELSE'S change. Inside the lock, so
        //     the file we compare is the file we are about to replace.
        if let expecting, existingState.contentFingerprint != expecting {
            Self.logger.error(
                "Refusing a stale registry write to \(path, privacy: .public): the file changed since it was read"
            )
            throw ProjectRegistryError.refusedStaleOverwrite(path: path)
        }

        let dir = context.paths.scarfDir
        // `createDirectory` is mkdir -p across every transport (Local
        // uses withIntermediateDirectories, SSH/Citadel both ignore
        // "already exists"), so we don't need to fileExists-guard it.
        try transport.createDirectory(dir)

        if let existing = existingBytes, !existing.isEmpty {
            // 2. Never blank a file that still holds projects, unless the
            //    caller says the emptying is the point.
            if registry.projects.isEmpty, !allowEmpty {
                let existingCount = existingState.registry.projects.count
                if existingCount > 0 {
                    throw ProjectRegistryError.refusedEmptyOverwrite(path: path, existingCount: existingCount)
                }
            }
            // 3. Rolling one-deep backup of the previous contents. Best
            //    effort: losing the backup is not a reason to fail the
            //    save the user asked for.
            if existing != writeData {
                do {
                    try transport.writeFile(path + ".bak", data: existing)
                } catch {
                    Self.logger.warning(
                        "Could not refresh projects.json.bak: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        // `transport.writeFile` is atomic on every transport — Local
        // writes `.atomic` (temp + rename(2)), SSH scps to a per-write
        // `<path>.scarf-<nonce>.tmp` and `mv`s it into place, and iOS
        // Citadel stages the same way over SFTP and renames. A second
        // temp-file dance here would add a non-atomic window over SSH,
        // not remove one.
        //
        // That third clause was FALSE until t-a6f22379: Citadel opened
        // the destination with `.truncate` and streamed 32KB chunks into
        // it, so a dropped cellular link left this file a fragment. If a
        // fourth transport ever appears, it owes this contract before any
        // of the guarding above means anything.
        try transport.writeFile(path, data: writeData)
    }

    /// Pretty-printed + sorted-keys JSON. Agents read this file by hand,
    /// so the formatting is part of the contract, not a nicety.
    static func encodeRegistry(_ registry: ProjectRegistry) throws -> Data {
        let data = try JSONEncoder().encode(registry)
        if let pretty = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted, .sortedKeys]) {
            return formatted
        }
        return data
    }

    // MARK: - Dashboard

    public func loadDashboard(for project: ProjectEntry) -> ProjectDashboard? {
        guard let data = try? transport.readFile(project.dashboardPath) else {
            return nil
        }
        if data.count > Self.maxJSONBytes {
            Self.logger.warning(
                "Dashboard for \(project.name, privacy: .public) is \(data.count) bytes (cap \(Self.maxJSONBytes)); treating as missing"
            )
            return nil
        }
        do {
            return try JSONDecoder().decode(ProjectDashboard.self, from: data)
        } catch {
            Self.logger.error("Failed to decode dashboard for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func dashboardExists(for project: ProjectEntry) -> Bool {
        transport.fileExists(project.dashboardPath)
    }

    public func dashboardModificationDate(for project: ProjectEntry) -> Date? {
        transport.stat(project.dashboardPath)?.mtime
    }

    // MARK: - Dashboard writes

    /// Validate then write `<project>/.scarf/dashboard.json`.
    ///
    /// The dashboard has always been an agent-authored file with no
    /// writer on Scarf's side, which is precisely why broken ones reach
    /// the renderer. This is the one writer, and it refuses anything the
    /// renderer could not draw: the bytes must decode as a
    /// `ProjectDashboard` AND satisfy `DashboardWidgetCatalog`.
    ///
    /// Bytes in are re-serialized pretty-printed with sorted keys — the
    /// same formatting contract `encodeRegistry` keeps, since agents read
    /// this file by hand — but through `JSONSerialization`, NOT through
    /// `ProjectDashboard`'s encoder: a round-trip through the model would
    /// silently delete every key the model doesn't declare, and this file
    /// belongs to whoever wrote it.
    ///
    /// One write, one FSEvent: `transport.writeFile` is atomic on every
    /// transport, so `HermesFileWatcher` sees a single change rather than
    /// a truncate followed by a fill.
    public func saveDashboard(rawJSON: Data, for project: ProjectEntry) throws {
        guard rawJSON.count <= Self.maxJSONBytes else {
            throw ProjectDashboardWriteError.tooLarge(bytes: rawJSON.count, cap: Self.maxJSONBytes)
        }

        let decoded: ProjectDashboard
        do {
            decoded = try JSONDecoder().decode(ProjectDashboard.self, from: rawJSON)
        } catch {
            throw ProjectDashboardWriteError.undecodable(Self.describe(error))
        }

        let problems = DashboardWidgetCatalog.validate(decoded)
        guard problems.isEmpty else {
            throw ProjectDashboardWriteError.invalid(problems)
        }

        // Preserves keys the model doesn't declare; normalizes layout.
        let writeData: Data
        if let object = try? JSONSerialization.jsonObject(with: rawJSON),
           let formatted = try? JSONSerialization.data(
               withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
           ) {
            writeData = formatted
        } else {
            writeData = rawJSON
        }

        try transport.createDirectory(project.scarfDir)
        try transport.writeFile(project.dashboardPath, data: writeData)
    }

    /// A `DecodingError` rendered as one line an agent can act on —
    /// `localizedDescription` on a decoding error is famously "The data
    /// couldn’t be read because it isn’t in the correct format."
    static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath
                .map { $0.intValue.map { i in "[\(i)]" } ?? ".\($0.stringValue)" }
                .joined()
            return joined.isEmpty ? "(root)" : String(joined.drop(while: { $0 == "." }))
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "\(path(context)): missing required key \"\(key.stringValue)\""
        case .typeMismatch(let type, let context):
            return "\(path(context)): expected \(type)"
        case .valueNotFound(let type, let context):
            return "\(path(context)): expected \(type), found null"
        case .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return decoding.localizedDescription
        }
    }
}

/// Why a dashboard write was refused. Every case is phrased for the
/// agent that sent the JSON, not for a log line.
public enum ProjectDashboardWriteError: LocalizedError, Sendable, Equatable {
    /// The bytes are not a `ProjectDashboard` at all.
    case undecodable(String)
    /// It decoded, but carries something the renderer cannot draw.
    case invalid([String])
    case tooLarge(bytes: Int, cap: Int)

    public var errorDescription: String? {
        switch self {
        case .undecodable(let detail):
            return "dashboard.json is not a valid dashboard: \(detail)"
        case .invalid(let problems):
            return "dashboard.json has \(problems.count) problem"
                + (problems.count == 1 ? "" : "s") + ": "
                + problems.joined(separator: "; ")
        case .tooLarge(let bytes, let cap):
            return "dashboard.json is \(bytes) bytes; the cap is \(cap)."
        }
    }
}
