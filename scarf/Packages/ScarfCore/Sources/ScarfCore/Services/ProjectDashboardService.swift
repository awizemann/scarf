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

        public init(
            registry: ProjectRegistry,
            salvage: RegistrySalvageReport = .clean,
            quarantinePath: String? = nil
        ) {
            self.registry = registry
            self.salvage = salvage
            self.quarantinePath = quarantinePath
        }

        /// `true` when the file on disk did not decode cleanly — a row
        /// or field was dropped, or the whole file was quarantined.
        public var salvaged: Bool { !salvage.isClean || quarantinePath != nil }
        public var droppedCount: Int { salvage.droppedCount }
    }

    public func loadRegistry() -> ProjectRegistry {
        loadRegistryDetailed().registry
    }

    public func loadRegistryDetailed() -> RegistryLoadResult {
        // Tracks time spent reading + decoding projects.json from the transport
        // (local file or SSH). Helps spot slow remote round-trips.
        ScarfMon.measure(.diskIO, "dashboard.loadRegistry") {
            let path = context.paths.projectsRegistry
            guard let data = try? transport.readFile(path), !data.isEmpty else {
                return RegistryLoadResult(registry: ProjectRegistry(projects: []))
            }
            if data.count > Self.maxJSONBytes {
                Self.logger.warning(
                    "Project registry at \(path, privacy: .public) is \(data.count) bytes (cap \(Self.maxJSONBytes)); treating as missing"
                )
                // Quarantined like any other unusable file: we are about
                // to hand callers an empty registry, and the next save
                // would otherwise write over content we never read.
                return RegistryLoadResult(
                    registry: ProjectRegistry(projects: []),
                    quarantinePath: quarantineRegistry(data: data, path: path)
                )
            }
            do {
                let (registry, salvage) = try ProjectRegistry.decodeSalvaging(from: data)
                if !salvage.isClean {
                    Self.logger.warning(
                        "Project registry salvaged: dropped \(salvage.droppedCount) row(s), dropped fields \(salvage.salvagedFields.joined(separator: ", "), privacy: .public)"
                    )
                }
                return RegistryLoadResult(registry: registry, salvage: salvage)
            } catch {
                Self.logger.error("Failed to decode project registry: \(error.localizedDescription, privacy: .public)")
                return RegistryLoadResult(
                    registry: ProjectRegistry(projects: []),
                    quarantinePath: quarantineRegistry(data: data, path: path)
                )
            }
        }
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
        let dir = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + ".corrupt-"
        if let names = try? transport.listDirectory(dir) {
            for name in names where name.hasPrefix(prefix) {
                let candidate = dir + "/" + name
                // Size first: this runs on every load while the registry
                // stays corrupt, and the oversize case (up to
                // `maxJSONBytes`) would otherwise re-read megabytes per
                // watcher tick just to find the copy it already made.
                guard transport.stat(candidate)?.size == Int64(data.count) else { continue }
                if let existing = try? transport.readFile(candidate), existing == data {
                    return candidate
                }
            }
        }
        // Second-resolution stamp, so two DIFFERENT corruptions inside
        // the same second would otherwise land on the same name and the
        // later one would eat the earlier copy.
        var destination = dir + "/" + prefix + Self.quarantineStamp(Date())
        if transport.fileExists(destination) {
            destination += "-" + UUID().uuidString.prefix(8)
        }
        do {
            try transport.writeFile(destination, data: data)
            Self.logger.error(
                "Quarantined unreadable project registry to \(destination, privacy: .public)"
            )
            return destination
        } catch {
            Self.logger.error(
                "Could not quarantine unreadable project registry: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Filename-safe UTC stamp (`20260903T142530Z`). Deliberately not
    /// ISO-8601-with-colons: those are legal on APFS but not on every
    /// remote filesystem Scarf writes to over SSH.
    static func quarantineStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
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
    public func saveRegistry(_ registry: ProjectRegistry, allowEmpty: Bool = false) throws {
        let path = context.paths.projectsRegistry
        // Encode BEFORE touching the filesystem, so an encode failure
        // can't leave a half-updated directory behind.
        let writeData = try Self.encodeRegistry(registry)
        let dir = context.paths.scarfDir
        // `createDirectory` is mkdir -p across every transport (Local
        // uses withIntermediateDirectories, SSH/Citadel both ignore
        // "already exists"), so we don't need to fileExists-guard it.
        try transport.createDirectory(dir)

        if let existing = try? transport.readFile(path), !existing.isEmpty {
            if registry.projects.isEmpty, !allowEmpty {
                // An unparseable existing file counts as "content worth
                // keeping" (count `nil`): we could not read it, so we
                // certainly must not blank it.
                let existingCount = (try? ProjectRegistry.decodeSalvaging(from: existing))?.registry.projects.count
                if (existingCount ?? 1) > 0 {
                    throw ProjectRegistryError.refusedEmptyOverwrite(path: path, existingCount: existingCount)
                }
            }
            if existing != writeData {
                // Rolling one-deep backup of the previous contents. Best
                // effort: losing the backup is not a reason to fail the
                // save the user asked for.
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
        // writes `.atomic` (temp + rename(2)), SSH scps to `<path>.scarf.tmp`
        // and `mv`s it into place. A second temp-file dance here would
        // add a non-atomic window over SSH, not remove one.
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
}
