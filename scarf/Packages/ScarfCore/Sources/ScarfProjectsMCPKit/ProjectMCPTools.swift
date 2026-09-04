import Foundation
import ScarfCore

/// The `scarf-projects` tool surface: structured project CRUD for a
/// LOCAL Hermes agent, wrapping the exact services Scarf's own UI uses.
///
/// **No parallel write paths.** Every mutation goes through
/// `ProjectStore` / `ProjectDashboardService` / `ProjectSlashCommandService`
/// / `ProjectDoctorService`, which is the whole point: the skill's
/// "read `projects.json`, append your entry, write it back" step is what
/// produced the 2026-09-02 corruption, and a tool that hand-wrote JSON
/// would just be that same step with a schema stapled to the front.
///
/// **Every REGISTRY write honours the Phase-2 refusal.** A registry whose
/// decode dropped rows, or that was quarantined, is not writable:
/// rewriting it makes the loss permanent. `project_register` refuses, and
/// `project_validate`'s repairs are blocked by the doctor's own rule.
/// `project_update_dashboard` and `project_add_slash_command` write
/// PROJECT-LOCAL files and are not blocked by a damaged registry — but
/// they resolve their target through it, so every failure to resolve says
/// whether the registry was readable rather than claiming the project
/// doesn't exist.
///
/// All I/O is synchronous transport I/O on the process's own thread. That
/// is correct here and only here — this is a short-lived CLI with no main
/// actor to block (charter C10 is about the app).
public struct ProjectMCPTools: Sendable {

    /// One tool's outcome. `isError` maps to MCP's `tools/call` result
    /// flag: the call SUCCEEDED at protocol level and the model is meant
    /// to read the failure and react, which is exactly the affordance a
    /// hand-written file append never had.
    public struct Outcome: Sendable, Equatable {
        public let text: String
        public let isError: Bool

        public static func ok(_ text: String) -> Outcome { Outcome(text: text, isError: false) }
        public static func failure(_ text: String) -> Outcome { Outcome(text: text, isError: true) }
    }

    public let context: ServerContext
    /// Made once, like every other service here does — `project_list`
    /// touches the transport twice per project row.
    private let transport: any ServerTransport

    private let dashboards: ProjectDashboardService
    private let store: ProjectStore
    private let slashCommands: ProjectSlashCommandService
    private let doctor: ProjectDoctorService

    public init(context: ServerContext) {
        self.context = context
        self.transport = context.makeTransport()
        self.dashboards = ProjectDashboardService(context: context)
        self.store = ProjectStore(context: context)
        self.slashCommands = ProjectSlashCommandService(context: context)
        self.doctor = ProjectDoctorService(context: context)
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: JSONValue]) -> Outcome {
        do {
            switch name {
            case "project_list": return try list(arguments)
            case "project_get": return try get(arguments)
            case "project_register": return try register(arguments)
            case "project_update_dashboard": return try updateDashboard(arguments)
            case "project_add_slash_command": return try addSlashCommand(arguments)
            case "project_validate": return try validate(arguments)
            default:
                return .failure(
                    "Unknown tool \"\(name)\". Available: "
                        + ProjectMCPToolCatalog.tools.map(\.name).joined(separator: ", ") + "."
                )
            }
        } catch let error as ArgumentError {
            return .failure(error.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - project_list

    private func list(_ arguments: [String: JSONValue]) throws -> Outcome {
        let includeArchived = try optionalBool(arguments, "includeArchived") ?? true
        let loaded = dashboards.loadRegistryDetailed()

        let rows = loaded.registry.projects
            .filter { includeArchived || !$0.archived }
            .map { entry -> JSONValue in
                var fields: [String: JSONValue] = [
                    "name": .string(entry.name),
                    "path": .string(entry.path),
                    "archived": .bool(entry.archived),
                    "hasRecord": .bool(
                        transport.fileExists(ProjectStore.recordPath(forProjectPath: entry.path))
                    ),
                    "hasDashboard": .bool(dashboards.dashboardExists(for: entry)),
                ]
                if let folder = entry.folder { fields["folder"] = .string(folder) }
                if let uuid = entry.uuid { fields["uuid"] = .string(uuid.uuidString) }
                return .object(fields)
            }

        return .ok(try render([
            "projects": .array(rows),
            "count": .int(rows.count),
            "registry": registryHealth(loaded),
        ]))
    }

    // MARK: - project_get

    private func get(_ arguments: [String: JSONValue]) throws -> Outcome {
        let selector = try requiredString(arguments, "project")
        let loaded = dashboards.loadRegistryDetailed()
        guard let entry = resolve(selector, in: loaded.registry.projects) else {
            return .failure(notFoundMessage(selector, in: loaded))
        }

        var fields: [String: JSONValue] = [
            "name": .string(entry.name),
            "path": .string(entry.path),
            "archived": .bool(entry.archived),
            "registry": registryHealth(loaded),
        ]
        if let folder = entry.folder { fields["folder"] = .string(folder) }
        if let uuid = entry.uuid { fields["uuid"] = .string(uuid.uuidString) }

        let recordPath = ProjectStore.recordPath(forProjectPath: entry.path)
        if transport.fileExists(recordPath) {
            if let record = store.load(projectPath: entry.path) {
                fields["record"] = .object([
                    "id": .string(record.id.uuidString),
                    "name": .string(record.name),
                    "rootPath": .string(record.rootPath),
                    "path": .string(recordPath),
                ])
            } else {
                // Reported, never repaired here: rewriting a record that
                // exists but doesn't parse destroys the only copy of
                // whatever the agent meant to say.
                fields["record"] = .object([
                    "path": .string(recordPath),
                    "error": .string(
                        "project.json exists but could not be parsed. It is left untouched — "
                            + "fix the file by hand, or run project_validate for a full report."
                    ),
                ])
            }
        }

        fields["dashboard"] = .object([
            "path": .string(entry.dashboardPath),
            "exists": .bool(dashboards.dashboardExists(for: entry)),
            "valid": .bool(dashboards.loadDashboard(for: entry) != nil),
        ])
        fields["slashCommands"] = .array(
            slashCommands.loadCommands(at: entry.path).map { .string($0.name) }
        )

        return .ok(try render(fields))
    }

    // MARK: - project_register

    private func register(_ arguments: [String: JSONValue]) throws -> Outcome {
        let name = try requiredString(arguments, "name")
        let rawPath = try requiredString(arguments, "path")

        if name.contains("/") || name.contains("\n") {
            return .failure("name must be a display name, not a path (got \"\(name)\").")
        }
        guard rawPath.hasPrefix("/") else {
            return .failure(
                "path must be absolute (got \"\(rawPath)\"). A `~` is not expanded — pass the "
                    + "resolved home directory instead."
            )
        }
        let path = ProjectIdentity.normalizedPath(rawPath)
        guard transport.fileExists(path) else {
            return .failure(
                "No directory at \(path). Create the project folder first — registering a "
                    + "project never creates its directory."
            )
        }

        let loaded = dashboards.loadRegistryDetailed()
        if let refusal = lossyRefusal(loaded, verb: "register “\(name)”") {
            return .failure(refusal)
        }

        if let clash = loaded.registry.projects.first(where: { $0.name == name }) {
            return .failure(
                "A project named “\(name)” is already registered at \(clash.path). "
                    + "The registry keys the sidebar on the display name, so names must be unique."
            )
        }
        if let existing = loaded.registry.projects.first(
            where: { ProjectIdentity.normalizedPath($0.path) == path }
        ) {
            return .failure(
                "\(path) is already registered as “\(existing.name)”. Use project_get to inspect "
                    + "it, or rename it in Scarf — re-registering the same path under a second "
                    + "name would give one folder two identities."
            )
        }

        // The identity comes from `ProjectStore.derive`, which is where
        // every other caller gets one: an id derived from (host, path)
        // when nothing has asserted one, never a fresh `UUID()`.
        let project = store.derive(from: ProjectEntry(name: name, path: path))

        // The re-assert that used to sit here is GONE. `derive` reads the
        // manifest, config, lock, cron and mini-apps off disk — tens of
        // milliseconds in which the registry can go lossy — and this
        // re-checked against a fresh read to shrink that window, because
        // `indexInRegistry` was salvage-BLIND. It no longer is: it and
        // `saveRegistry` both refuse a lossy registry from inside, against
        // the very read they write back, so re-checking here would only be
        // a third read of the same file with no window closed.
        do {
            // Writes `<path>/.scarf/project.json` AND upserts the registry
            // row carrying the id — the two halves the skill's step 8 did
            // by hand, in the order the app does them.
            try store.save(project)
        } catch {
            // `save` writes the record FIRST and indexes second, so a
            // failure here can still have left `project.json` on disk.
            // Telling the agent "nothing happened" would send it to
            // re-register a path the doctor is about to report as an
            // orphaned record.
            let recordPath = ProjectStore.recordPath(forProjectPath: path)
            let partial = transport.fileExists(recordPath)
                ? " The record at \(recordPath) WAS written; only the registry row is missing — "
                    + "run project_validate, which offers to re-index it."
                : ""
            return .failure(
                "Could not register “\(name)”: \(error.localizedDescription)" + partial
            )
        }

        return .ok(try render([
            "registered": .bool(true),
            "name": .string(name),
            "path": .string(path),
            "uuid": .string(project.id.uuidString),
            "recordPath": .string(ProjectStore.recordPath(forProjectPath: path)),
            "registryPath": .string(context.paths.projectsRegistry),
        ]))
    }

    // MARK: - project_update_dashboard

    private func updateDashboard(_ arguments: [String: JSONValue]) throws -> Outcome {
        let selector = try requiredString(arguments, "project")
        let loaded = dashboards.loadRegistryDetailed()
        guard let entry = resolve(selector, in: loaded.registry.projects) else {
            return .failure(notFoundMessage(selector, in: loaded))
        }

        // Accept the dashboard as an object (the natural shape) or as a
        // JSON string (what a model reaching for a text field produces).
        // Rejecting the string form would be pedantry with a retry loop
        // attached.
        guard let raw = arguments["dashboard"] else {
            throw ArgumentError(message: "Missing required argument \"dashboard\".")
        }
        let bytes: Data
        switch raw {
        case .string(let text):
            bytes = Data(text.utf8)
        case .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bytes = try encoder.encode(raw)
        default:
            throw ArgumentError(
                message: "\"dashboard\" must be a JSON object (or a string containing one)."
            )
        }

        do {
            // Validates by DECODING with the real `ProjectDashboard` types
            // and the widget catalog, then writes atomically through the
            // transport — one write, so the file watcher fires once and
            // the open cockpit repaints exactly once.
            try dashboards.saveDashboard(rawJSON: bytes, for: entry)
        } catch let error as ProjectDashboardWriteError {
            return .failure(
                (error.errorDescription ?? "Dashboard rejected.")
                    + " Nothing was written; the existing dashboard.json is untouched."
            )
        } catch {
            return .failure("Could not write dashboard.json: \(error.localizedDescription)")
        }

        return .ok(try render([
            "written": .bool(true),
            "project": .string(entry.name),
            "path": .string(entry.dashboardPath),
        ]))
    }

    // MARK: - project_add_slash_command

    private func addSlashCommand(_ arguments: [String: JSONValue]) throws -> Outcome {
        let selector = try requiredString(arguments, "project")
        let loaded = dashboards.loadRegistryDetailed()
        guard let entry = resolve(selector, in: loaded.registry.projects) else {
            return .failure(notFoundMessage(selector, in: loaded))
        }

        let name = try requiredString(arguments, "name")
        let description = try requiredString(arguments, "description")
        let body = try requiredString(arguments, "body")
        let overwrite = try optionalBool(arguments, "overwrite") ?? false

        // Validate BEFORE the path is built. `ProjectSlashCommandService`
        // validates too, so nothing escapes either way — but building a
        // path out of an unvalidated name and probing it means a name of
        // "../../etc/passwd" decides where we stat, and leaves the tool
        // one refactor away from deciding where we WRITE.
        if let reason = ProjectSlashCommand.validateName(name) {
            return .failure("\"name\" is not a usable command name: \(reason)")
        }
        let dir = ProjectSlashCommandService.slashCommandsDir(for: entry.path)
        let commandPath = dir + "/" + name + ".md"
        if !overwrite, transport.fileExists(commandPath) {
            return .failure(
                "/\(name) already exists at \(commandPath). Pass overwrite: true to replace it."
            )
        }

        let command = ProjectSlashCommand(
            name: name,
            description: description,
            argumentHint: try optionalString(arguments, "argumentHint"),
            model: try optionalString(arguments, "model"),
            tags: try optionalStringArray(arguments, "tags"),
            body: body,
            sourcePath: commandPath
        )
        do {
            try slashCommands.save(command, at: entry.path)
        } catch {
            return .failure("Could not write /\(name): \(error.localizedDescription)")
        }

        return .ok(try render([
            "written": .bool(true),
            "command": .string("/" + name),
            "project": .string(entry.name),
            "path": .string(commandPath),
        ]))
    }

    // MARK: - project_validate

    private func validate(_ arguments: [String: JSONValue]) throws -> Outcome {
        let selector = try optionalString(arguments, "project")
        let shouldRepair = try optionalBool(arguments, "repair") ?? false

        var entry: ProjectEntry?
        if let selector {
            let loaded = dashboards.loadRegistryDetailed()
            guard let found = resolve(selector, in: loaded.registry.projects) else {
                return .failure(notFoundMessage(selector, in: loaded))
            }
            entry = found
        }

        var report = doctor.diagnose()
        var repaired: [String] = []
        var repairFailures: [String: String] = [:]

        if shouldRepair {
            // `repairAllSafe` walks `report.safelyRepairable`, which is
            // empty while the registry decode is lossy — the refusal is
            // the service's, not re-implemented here. Scoping to one
            // project filters the findings we hand it, so `repair: true`
            // on one project never quietly fixes another.
            let scoped = entry.map { subject in
                ProjectDoctorReport(
                    findings: findings(of: report, concerning: subject),
                    repairBlock: report.repairBlock,
                    projectCount: report.projectCount,
                    generatedAt: report.generatedAt
                )
            } ?? report

            let attempted = scoped.safelyRepairable.map(\.id)
            repairFailures = doctor.repairAllSafe(scoped)
            repaired = attempted.filter { repairFailures[$0] == nil }
            // Repairs change what the next pass sees, so the report we
            // hand back is a fresh one — a stale report would tell the
            // agent to fix what it just fixed.
            report = doctor.diagnose()
        }

        let findings = entry.map { findings(of: report, concerning: $0) } ?? report.findings

        var fields: [String: JSONValue] = [
            "summary": .string(report.summary),
            "projectCount": .int(report.projectCount),
            "healthy": .bool(findings.filter { $0.severity > .info }.isEmpty),
            "findings": .array(findings.map(encode)),
        ]
        if let entry { fields["project"] = .string(entry.name) }
        if let block = report.repairBlock {
            fields["repairsBlocked"] = .string(block.message)
        }
        if shouldRepair {
            fields["repaired"] = .array(repaired.map { .string($0) })
            if !repairFailures.isEmpty {
                fields["repairFailures"] = .object(
                    repairFailures.mapValues { JSONValue.string($0) }
                )
            }
        }
        return .ok(try render(fields))
    }

    /// Every finding that concerns one project, INFORMATIONAL ONES
    /// INCLUDED.
    ///
    /// `ProjectDoctorReport.issues(forProjectPath:name:)` filters
    /// `issues`, which drops `.info` — right for a cockpit health row,
    /// wrong here twice over: the scoped report would hide history the
    /// unscoped one shows, and a safe repair attached to an info finding
    /// would run unscoped but not scoped. One tool, one contract.
    private func findings(
        of report: ProjectDoctorReport,
        concerning subject: ProjectEntry
    ) -> [ProjectDoctorFinding] {
        report.findings.filter { finding in
            if finding.projectName == subject.name { return true }
            guard let path = finding.path else { return false }
            return path == subject.path || path.hasPrefix(subject.path + "/")
        }
    }

    private func encode(_ finding: ProjectDoctorFinding) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(finding.id),
            "kind": .string(finding.kind.rawValue),
            "severity": .string(String(describing: finding.severity)),
            "title": .string(finding.title),
            "detail": .string(finding.detail),
        ]
        if let name = finding.projectName { fields["project"] = .string(name) }
        if let path = finding.path { fields["path"] = .string(path) }
        if let repair = finding.repair {
            fields["repair"] = .object([
                "action": .string(repair.actionLabel),
                "safe": .bool(repair.isSafe),
                "destructive": .bool(repair.isDestructive),
            ])
        }
        return .object(fields)
    }

    // MARK: - Shared helpers

    /// Resolve a `project` argument, which may be a display name or an
    /// absolute path. Paths are compared after the same normalization
    /// `ProjectIdentity` uses, so a trailing slash or a `./` is not a
    /// "no such project".
    private func resolve(_ selector: String, in rows: [ProjectEntry]) -> ProjectEntry? {
        if let byName = rows.first(where: { $0.name == selector }) { return byName }
        guard selector.hasPrefix("/") else { return nil }
        let normalized = ProjectIdentity.normalizedPath(selector)
        return rows.first { ProjectIdentity.normalizedPath($0.path) == normalized }
    }

    /// Why a selector didn't resolve — which is NOT always "there is no
    /// such project". A quarantined registry decodes to an EMPTY list, so
    /// the honest answer there is "the file is damaged", not "you have no
    /// projects": the latter sends the agent off to re-register projects
    /// that already exist.
    private func notFoundMessage(
        _ selector: String,
        in loaded: ProjectDashboardService.RegistryLoadResult
    ) -> String {
        let known = loaded.registry.projects.map(\.name).sorted()
        let head = "No project matches \"\(selector)\" (name or absolute path). "
        if loaded.salvaged {
            let damage = loaded.quarantinePath.map {
                "The registry at \(context.paths.projectsRegistry) could not be read at all and "
                    + "was set aside at \($0), so this list is empty for that reason — not "
                    + "because you have no projects."
            } ?? "\(loaded.salvage.droppedCount) row(s) in the registry could not be read, so "
                + "some projects are missing from this list."
            let visible = known.isEmpty ? "" : " Readable projects: " + known.joined(separator: ", ") + "."
            return head + damage + visible + " Run project_validate."
        }
        let list = known.isEmpty
            ? "No projects are registered yet — use project_register."
            : "Known projects: " + known.joined(separator: ", ") + "."
        return head + list
    }

    /// The registry's health, on every read tool's response. An agent
    /// that is about to write needs to know the file is damaged BEFORE
    /// its write is refused.
    private func registryHealth(
        _ loaded: ProjectDashboardService.RegistryLoadResult
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "path": .string(context.paths.projectsRegistry),
            "healthy": .bool(!loaded.salvaged),
        ]
        if loaded.salvaged {
            fields["droppedRows"] = .int(loaded.salvage.droppedCount)
            if let quarantine = loaded.quarantinePath {
                fields["quarantinePath"] = .string(quarantine)
            }
            fields["warning"] = .string(
                "The projects registry did not decode cleanly. Writes are refused until it is "
                    + "repaired, so a rewrite can't make the loss permanent. Run project_validate."
            )
        }
        return .object(fields)
    }

    /// The refusal an AGENT reads, for the app-wide lossy rule
    /// (`RegistryLoadResult.loss`). Field-level salvage does not block:
    /// the dropped field held an invalid value, and writing without it is
    /// the repair.
    ///
    /// Advisory only — `ProjectDashboardService.saveRegistry` refuses the
    /// write itself. What this adds is a message the model can act on
    /// (which tool, which file, what to run next) instead of a thrown
    /// error surfacing as a generic tool failure.
    private func lossyRefusal(
        _ loaded: ProjectDashboardService.RegistryLoadResult,
        verb: String
    ) -> String? {
        guard let loss = loaded.loss else { return nil }
        return "Refusing to \(verb). \(loss.message) "
            + "Run project_validate for what is wrong with \(context.paths.projectsRegistry)."
    }

    private func render(_ fields: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(JSONValue.object(fields)), as: UTF8.self)
    }

    // MARK: - Argument coercion

    struct ArgumentError: Error { let message: String }

    private func requiredString(_ arguments: [String: JSONValue], _ key: String) throws -> String {
        guard let value = arguments[key] else {
            throw ArgumentError(message: "Missing required argument \"\(key)\".")
        }
        guard case .string(let text) = value else {
            throw ArgumentError(message: "\"\(key)\" must be a string.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ArgumentError(message: "\"\(key)\" must not be empty.")
        }
        return trimmed
    }

    private func optionalString(_ arguments: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = arguments[key], value != .null else { return nil }
        guard case .string(let text) = value else {
            throw ArgumentError(message: "\"\(key)\" must be a string.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Accepts `"true"` / `"false"` as well as real booleans, for the same
    /// reason `dashboard` accepts a JSON string: models emit stringified
    /// booleans constantly, and refusing one buys a retry loop rather than
    /// any safety.
    private func optionalBool(_ arguments: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = arguments[key], value != .null else { return nil }
        switch value {
        case .bool(let flag):
            return flag
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return true
            case "false": return false
            default: break
            }
            throw ArgumentError(message: "\"\(key)\" must be true or false (got \"\(text)\").")
        default:
            throw ArgumentError(message: "\"\(key)\" must be true or false.")
        }
    }

    private func optionalStringArray(
        _ arguments: [String: JSONValue],
        _ key: String
    ) throws -> [String]? {
        guard let value = arguments[key], value != .null else { return nil }
        guard case .array(let items) = value else {
            throw ArgumentError(message: "\"\(key)\" must be an array of strings.")
        }
        var result: [String] = []
        for item in items {
            guard case .string(let text) = item else {
                throw ArgumentError(message: "\"\(key)\" must contain only strings.")
            }
            result.append(text)
        }
        return result.isEmpty ? nil : result
    }
}
