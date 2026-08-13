import Foundation
#if canImport(os)
import os
#endif

/// Load/save the first-class `ScarfProject` record + keep the registry
/// index in sync. The transport-independent, `ServerContext`-aware
/// counterpart to `ProjectDashboardService` (same shape: a `context` +
/// a `transport`, all `nonisolated`, no actor).
///
/// **Two stores, one truth.**
/// - **Canonical**: `<rootPath>/.scarf/project.json` — the portable,
///   versionable `ScarfProject`. Travels with the repo.
/// - **Index**: the existing `~/.hermes/scarf/projects.json` registry
///   (`ProjectRegistry`/`ProjectEntry`), extended with `ProjectEntry.uuid`
///   so the canonical record can be located per host without walking
///   the filesystem. This is the design's "per-server fleet index" —
///   it already existed as Scarf's registry, so we EXTEND it rather
///   than create a parallel index.
///
/// **Migration is additive + idempotent + non-destructive** (`derive()`):
/// for any registry row lacking a record or a UUID, it builds a
/// `ScarfProject` by *reading the facets that already exist on disk*
/// (manifest `modelPresetID`/`kanbanTenant`, cron `[tmpl:]`/`[proj:]`
/// tags, `config.json` Keychain refs, `template.lock.json`) and writes
/// the record + back-fills the UUID. Nothing is destroyed; re-running
/// in steady state writes nothing.
///
/// **SECRET-SAFE**: `secretsScope` carries `config.json` keys whose
/// values are `keychain://…` refs — the field NAMES, never the values.
/// Failures `ProjectStore` raises on its own (as opposed to transport
/// I/O errors it lets through).
public enum ProjectStoreError: LocalizedError, Sendable, Equatable {
    /// `save` was handed a project whose root directory no longer exists
    /// — usually a stale in-memory `ProjectEntry` for a project that was
    /// just uninstalled or deleted out from under the UI.
    case projectRootMissing(String)

    public var errorDescription: String? {
        switch self {
        case .projectRootMissing(let path):
            return "Project directory no longer exists at \(path); refusing to re-create it."
        }
    }
}

public struct ProjectStore: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectStore")
    #endif

    /// Size ceiling for JSON we read off disk/SFTP. A `project.json` is
    /// a few KB; anything past this is corrupt or hostile and is treated
    /// as "missing" so the caller's derive path runs. Mirrors
    /// `ProjectDashboardService.maxJSONBytes`.
    public static let maxJSONBytes = 4 * 1024 * 1024

    public let context: ServerContext
    public let transport: any ServerTransport

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    // MARK: - Paths

    /// Canonical record path for a project rooted at `projectPath`.
    public nonisolated static func recordPath(forProjectPath projectPath: String) -> String {
        projectPath + "/.scarf/project.json"
    }

    // MARK: - Load / Save / List

    /// Read `<projectPath>/.scarf/project.json`. `nil` when absent,
    /// oversize, or unparseable — the caller falls back to `derive`.
    public nonisolated func load(projectPath: String) -> ScarfProject? {
        let path = Self.recordPath(forProjectPath: projectPath)
        guard let data = try? transport.readFile(path) else { return nil }
        if data.count > Self.maxJSONBytes {
            #if canImport(os)
            Self.logger.warning("project.json at \(path, privacy: .public) is \(data.count) bytes (cap \(Self.maxJSONBytes)); treating as missing")
            #endif
            return nil
        }
        do {
            return try JSONDecoder().decode(ScarfProject.self, from: data)
        } catch {
            #if canImport(os)
            Self.logger.error("failed to decode project.json at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
            return nil
        }
    }

    /// Write the canonical record AND index it into the registry
    /// (back-filling `ProjectEntry.uuid`). Throws on any I/O failure so
    /// callers can roll back; fire-and-forget callers use `try?`.
    ///
    /// **Refuses to save a project whose root directory is gone.**
    /// `writeRecord` does `mkdir -p <root>/.scarf` and `indexInRegistry`
    /// appends a registry row, so saving a deleted project *resurrects*
    /// it: the dir comes back holding only `.scarf/project.json`, and the
    /// registry row returns carrying its original UUID. That is exactly
    /// how template uninstall used to "fail": the uninstaller removed
    /// files + row correctly, the file watcher fired, the cockpit
    /// reloaded with `force`, `load()` missed the just-deleted
    /// `project.json`, and its `derive() + save()` fallback re-created
    /// both. A save can only ever *describe* a project that exists on
    /// disk — never conjure one.
    public nonisolated func save(_ project: ScarfProject) throws {
        // `fileExists` cannot distinguish "absent" from "transport down"
        // (SSH returns false for both). Refuse only when the parent
        // directory is reachable — proof the transport works and the
        // root alone is gone. When the parent is unreachable too, fall
        // through: a dead transport makes writeRecord throw the real
        // error instead of a misleading "directory no longer exists".
        if !transport.fileExists(project.rootPath) {
            let parent = (project.rootPath as NSString).deletingLastPathComponent
            if transport.fileExists(parent) {
                throw ProjectStoreError.projectRootMissing(project.rootPath)
            }
        }
        try writeRecord(project)
        try indexInRegistry(project)
    }

    /// Every project the registry knows, as `ScarfProject`s — the
    /// canonical record when present, otherwise derived on the fly.
    /// Read-only: deriving here does not persist (use `derive()` for the
    /// persisting migration).
    public nonisolated func list() -> [ScarfProject] {
        let registry = ProjectDashboardService(context: context).loadRegistry()
        return registry.projects.map { entry in
            load(projectPath: entry.path) ?? derive(from: entry)
        }
    }

    // MARK: - Migration

    /// Additive, idempotent, non-destructive migration. For every
    /// registry row missing a record OR a UUID, derive a `ScarfProject`
    /// from existing on-disk state and persist it (record + UUID
    /// back-fill). Returns the number of rows touched. Re-running in
    /// steady state touches nothing and writes nothing.
    @discardableResult
    public nonisolated func derive() -> Int {
        let dashboardService = ProjectDashboardService(context: context)
        let registry = dashboardService.loadRegistry()
        var migrated = 0
        for entry in registry.projects {
            let hasRecord = transport.fileExists(Self.recordPath(forProjectPath: entry.path))
            if hasRecord && entry.uuid != nil { continue }  // already migrated
            do {
                if hasRecord {
                    // Record is canonical — only the index UUID is stale.
                    // Don't rewrite project.json (avoid file-watcher churn);
                    // just back-fill the registry.
                    if let existing = load(projectPath: entry.path) {
                        try indexInRegistry(existing)
                    } else {
                        try save(derive(from: entry))
                    }
                } else {
                    try save(derive(from: entry))
                }
                migrated += 1
            } catch {
                #if canImport(os)
                Self.logger.error("derive() failed for \(entry.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                #endif
            }
        }
        return migrated
    }

    /// Build a `ScarfProject` from a registry entry by reading the
    /// facets that already exist on disk. Pure read — does not persist.
    /// Reuses the entry's UUID when set (stable id), mints one otherwise.
    public nonisolated func derive(from entry: ProjectEntry) -> ScarfProject {
        let id = entry.uuid ?? UUID()
        let projectPath = entry.path

        let modelPresetId = ProjectModelPresetReader(context: context)
            .presetID(forProjectPath: projectPath)
        let board = KanbanTenantReader(context: context)
            .tenant(forProjectPath: projectPath)

        let lockPath = projectPath + "/.scarf/template.lock.json"
        let templateLockRef = transport.fileExists(lockPath) ? lockPath : nil

        let templateId = templateInfo(projectPath: projectPath)?.id
        let cronJobIds = cronJobIds(projectId: id, templateId: templateId)
        let secretsScope = secretKeys(projectPath: projectPath)
        let memoryNamespace = memoryBlockId(projectPath: projectPath)
        let miniApps = MiniAppService(context: context).discoverRefs(projectPath: projectPath)

        let binding = ScarfProject.HostBinding(
            serverId: context.id.uuidString,
            rootPath: projectPath,
            materializedAt: Date()
        )

        return ScarfProject(
            id: id,
            name: entry.name,
            rootPath: projectPath,
            modelPresetId: modelPresetId,
            board: board,
            cronJobIds: cronJobIds,
            memoryNamespace: memoryNamespace,
            secretsScope: secretsScope,
            templateLockRef: templateLockRef,
            hostBindings: [binding],
            miniApps: miniApps
        )
    }

    // MARK: - Agent context block (shared Mac + iOS)

    /// Gather the inputs for the Scarf-managed AGENTS.md block from
    /// on-disk project state via the transport (works on Mac AND over
    /// iOS SFTP). The cron / config-fields sub-strings flow through
    /// `ProjectContextBlock`'s shared formatters so both platforms emit
    /// byte-identical blocks for identical state.
    public nonisolated func agentContextBlockInput(for project: ScarfProject) -> ProjectContextBlock.ManagedBlockInput {
        let projectPath = project.rootPath
        let tpl = templateInfo(projectPath: projectPath)
        let cronLines = ProjectContextBlock.cronLines(
            from: loadCronJobs(),
            projectId: project.id,
            templateId: tpl?.id
        )
        let slashNames = ProjectSlashCommandService(context: context)
            .loadCommands(at: projectPath)
            .map(\.name)
        // Prefer the structured binding on the object; fall back to the
        // canonical on-disk reader so a minimally-constructed record renders.
        let kanbanTenant = project.board ?? KanbanTenantReader(context: context).tenant(forProjectPath: projectPath)
        let lockFilePresent = project.templateLockRef != nil
            || transport.fileExists(projectPath + "/.scarf/template.lock.json")
        return ProjectContextBlock.ManagedBlockInput(
            projectName: project.name,
            projectPath: projectPath,
            templateId: tpl?.id,
            templateVersion: tpl?.version,
            configFieldsLine: ProjectContextBlock.configFieldsLine(fields: configSchemaFields(projectPath: projectPath)),
            cronLines: cronLines,
            slashCommandNames: slashNames,
            kanbanTenant: kanbanTenant,
            lockFilePresent: lockFilePresent
        )
    }

    /// Render the full Scarf-managed block for `project`. Single source of
    /// truth for both apps' project-chat context injection.
    public nonisolated func renderAgentContextBlock(for project: ScarfProject) -> String {
        ProjectContextBlock.renderManagedBlock(agentContextBlockInput(for: project))
    }

    /// `(key, isSecret)` for each field in `<project>/.scarf/manifest.json`
    /// → `config.schema`. Empty when absent/oversize/unparseable.
    /// SECRET-SAFE: field NAMES + secret flag only, never values. Mirrors
    /// the source the Mac's `ProjectAgentContextService.renderConfigFieldsLine`
    /// reads (`manifest.config?.fields`, where `fields` decodes from the
    /// JSON key `schema`).
    private nonisolated func configSchemaFields(projectPath: String) -> [(key: String, isSecret: Bool)] {
        let path = projectPath + "/.scarf/manifest.json"
        guard transport.fileExists(path),
              let data = try? transport.readFile(path),
              data.count <= Self.maxJSONBytes
        else { return [] }
        struct Projection: Decodable {
            struct Config: Decodable {
                struct Field: Decodable { let key: String; let type: String }
                let schema: [Field]?
            }
            let config: Config?
        }
        guard let p = try? JSONDecoder().decode(Projection.self, from: data),
              let fields = p.config?.schema
        else { return [] }
        return fields.map { (key: $0.key, isSecret: $0.type == "secret") }
    }

    // MARK: - Private writers

    private nonisolated func writeRecord(_ project: ScarfProject) throws {
        let scarfDir = project.rootPath + "/.scarf"
        // createDirectory is mkdir -p across every transport.
        try transport.createDirectory(scarfDir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try transport.writeFile(Self.recordPath(forProjectPath: project.rootPath), data: data)
    }

    /// Ensure the registry has a row for this project carrying its
    /// stable UUID. Matches by host path. Writes the registry only when
    /// something actually changes (idempotent — no churn).
    private nonisolated func indexInRegistry(_ project: ScarfProject) throws {
        let dashboardService = ProjectDashboardService(context: context)
        var registry = dashboardService.loadRegistry()
        if let idx = registry.projects.firstIndex(where: { $0.path == project.rootPath }) {
            guard registry.projects[idx].uuid != project.id else { return }  // already indexed
            registry.projects[idx].uuid = project.id
        } else {
            registry.projects.append(
                ProjectEntry(name: project.name, path: project.rootPath, uuid: project.id)
            )
        }
        try dashboardService.saveRegistry(registry)
    }

    // MARK: - Facet readers (lightweight projections — the full manifest
    // / config / lock Codable types live in the Mac app target)

    /// `(id, version)` from `<project>/.scarf/manifest.json`, or `nil`
    /// for a bare project or a `KanbanTenantResolver`-minted sentinel
    /// manifest (`id` "scarf/…" + version "0.0.0"). Matches the
    /// suppression rule in `ProjectAgentContextService.readTemplateInfo`.
    private nonisolated func templateInfo(projectPath: String) -> (id: String, version: String)? {
        let path = projectPath + "/.scarf/manifest.json"
        guard transport.fileExists(path), let data = try? transport.readFile(path) else { return nil }
        struct Projection: Decodable { let id: String; let version: String }
        guard let p = try? JSONDecoder().decode(Projection.self, from: data) else { return nil }
        if p.id.hasPrefix("scarf/") && p.version == "0.0.0" { return nil }
        return (p.id, p.version)
    }

    /// Ids of cron jobs attributed to this project — either the new
    /// `[proj:<uuid>]` tag or the legacy template `[tmpl:<id>]` prefix.
    private nonisolated func cronJobIds(projectId: UUID, templateId: String?) -> [String] {
        let jobs = loadCronJobs()
        let projPrefix = "[proj:\(projectId.uuidString)]"
        let tmplPrefix = templateId.map { "[tmpl:\($0)]" }
        return jobs.compactMap { job in
            if job.name.hasPrefix(projPrefix) { return job.id }
            if let tmplPrefix, job.name.hasPrefix(tmplPrefix) { return job.id }
            return nil
        }
    }

    private nonisolated func loadCronJobs() -> [HermesCronJob] {
        guard let data = try? transport.readFile(context.paths.cronJobsJSON),
              data.count <= Self.maxJSONBytes
        else {
            return []
        }
        return (try? JSONDecoder().decode(CronJobsFile.self, from: data))?.jobs ?? []
    }

    /// `config.json` keys whose values are Keychain refs — secret field
    /// NAMES only, sorted. **Never** the values (SECRET-SAFE).
    private nonisolated func secretKeys(projectPath: String) -> [String] {
        let path = projectPath + "/.scarf/config.json"
        guard transport.fileExists(path), let data = try? transport.readFile(path) else { return [] }
        struct Projection: Decodable { let values: [String: SecretProbe]? }
        /// Single-value probe: a `keychain://…` string is a secret; any
        /// other JSON scalar/array is not. Never throws.
        enum SecretProbe: Decodable {
            case secret
            case other
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self), s.hasPrefix("keychain://") {
                    self = .secret
                } else {
                    self = .other
                }
            }
        }
        guard let p = try? JSONDecoder().decode(Projection.self, from: data),
              let values = p.values else { return [] }
        return values.compactMap { key, probe in
            if case .secret = probe { return key } else { return nil }
        }.sorted()
    }

    /// `memory_block_id` from `<project>/.scarf/template.lock.json`, the
    /// MEMORY.md marker id when the project was template-installed.
    private nonisolated func memoryBlockId(projectPath: String) -> String? {
        let path = projectPath + "/.scarf/template.lock.json"
        guard transport.fileExists(path), let data = try? transport.readFile(path) else { return nil }
        struct Projection: Decodable {
            let memoryBlockId: String?
            enum CodingKeys: String, CodingKey { case memoryBlockId = "memory_block_id" }
        }
        return (try? JSONDecoder().decode(Projection.self, from: data))?.memoryBlockId
    }
}
