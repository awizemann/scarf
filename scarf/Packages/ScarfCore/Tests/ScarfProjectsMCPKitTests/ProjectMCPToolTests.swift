import Testing
import Foundation
@testable import ScarfProjectsMCPKit
@testable import ScarfCore

/// Tool-level coverage for the `scarf-projects` MCP server, driven against
/// a real temp Hermes home through `ServerContext.local(home:)` — the same
/// isolation every other ScarfCore disk test uses, so nothing here can
/// touch the developer's `~/.hermes`.
///
/// The cases that matter most are the REFUSALS: a tool that writes when it
/// should have refused is how the projects registry got corrupted in the
/// first place.
@Suite struct ProjectMCPToolTests {

    // MARK: - Harness

    struct Harness {
        let context: ServerContext
        let tools: ProjectMCPTools
        let home: URL
        let projectRoot: URL

        var registryPath: String { context.paths.projectsRegistry }
    }

    static func withHarness(_ body: (Harness) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-projects-mcp-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let home = base.appendingPathComponent("hermes", isDirectory: true)
        let projectRoot = base.appendingPathComponent("demo", isDirectory: true)
        let context = ServerContext.local(home: home)
        try FileManager.default.createDirectory(
            atPath: context.paths.scarfDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        try body(Harness(
            context: context,
            tools: ProjectMCPTools(context: context),
            home: home,
            projectRoot: projectRoot
        ))
    }

    /// Parse a tool's JSON payload so assertions read fields, not substrings.
    static func payload(_ outcome: ProjectMCPTools.Outcome) throws -> [String: JSONValue] {
        guard case .object(let fields) = try JSONDecoder()
            .decode(JSONValue.self, from: Data(outcome.text.utf8))
        else {
            Issue.record("tool output was not a JSON object: \(outcome.text)")
            return [:]
        }
        return fields
    }

    static func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static let validDashboard = """
        {"version": 1, "title": "Demo", "sections": [
          {"title": "Overview", "columns": 2, "widgets": [
            {"type": "stat", "title": "Runs", "value": 12},
            {"type": "text", "title": "Notes", "content": "hello"}
          ]}
        ]}
        """

    // MARK: - project_register (happy path)

    @Test("register writes project.json, adds the registry row, and derives a stable id")
    func registerHappyPath() throws {
        try Self.withHarness { h in
            let outcome = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"),
                "path": .string(h.projectRoot.path),
            ])
            #expect(!outcome.isError)

            let fields = try Self.payload(outcome)
            #expect(fields["registered"] == .bool(true))

            // The record exists and is a real ScarfProject.
            let record = ProjectStore(context: h.context).load(projectPath: h.projectRoot.path)
            #expect(record != nil)

            // The row exists and carries the SAME id — the two halves the
            // skill's hand-append did separately, and often wrongly.
            let registry = ProjectDashboardService(context: h.context).loadRegistry()
            #expect(registry.projects.count == 1)
            #expect(registry.projects.first?.name == "Demo")
            #expect(registry.projects.first?.uuid == record?.id)

            // Derived from (host, path), never minted on a read.
            let expected = ProjectIdentity.deterministicID(
                forProjectPath: h.projectRoot.path,
                hostKey: ProjectIdentity.hostKey(for: h.context)
            )
            #expect(record?.id == expected)
        }
    }

    @Test("register is refused for a duplicate name and for an already-registered path")
    func registerRefusesDuplicates() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])

            let sibling = h.projectRoot.deletingLastPathComponent()
                .appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

            let sameName = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(sibling.path),
            ])
            #expect(sameName.isError)
            #expect(sameName.text.contains("already registered"))

            let samePath = h.tools.call(name: "project_register", arguments: [
                "name": .string("Second"), "path": .string(h.projectRoot.path),
            ])
            #expect(samePath.isError)
            #expect(samePath.text.contains("two identities"))

            #expect(ProjectDashboardService(context: h.context).loadRegistry().projects.count == 1)
        }
    }

    @Test("register refuses a relative path, a tilde path, and a directory that isn't there")
    func registerRefusesBadPaths() throws {
        try Self.withHarness { h in
            for path in ["relative/dir", "~/projects/demo"] {
                let outcome = h.tools.call(name: "project_register", arguments: [
                    "name": .string("Demo"), "path": .string(path),
                ])
                #expect(outcome.isError)
                #expect(outcome.text.contains("absolute"))
            }

            let missing = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"),
                "path": .string(h.projectRoot.path + "-does-not-exist"),
            ])
            #expect(missing.isError)
            #expect(missing.text.contains("never creates its directory"))
            #expect(ProjectDashboardService(context: h.context).loadRegistry().projects.isEmpty)
        }
    }

    // MARK: - The lossy-registry refusal (Phase 2's rule)

    @Test("register refuses while the registry decode is dropping rows")
    func registerRefusesLossyRegistry() throws {
        try Self.withHarness { h in
            // A row with no `name` is undecodable, so the salvaging
            // decoder drops the whole ROW — writing back would erase it
            // from the file permanently.
            try Self.write("""
                {"projects": [
                  {"name": "Kept", "path": "/tmp/kept"},
                  {"path": "/tmp/nameless"}
                ]}
                """, to: h.registryPath)

            let before = try String(contentsOfFile: h.registryPath, encoding: .utf8)
            let outcome = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])

            #expect(outcome.isError)
            #expect(outcome.text.contains("Refusing to register"))
            #expect(outcome.text.contains("permanently"))
            // The whole point: the damaged file is byte-identical after.
            #expect(try String(contentsOfFile: h.registryPath, encoding: .utf8) == before)
        }
    }

    @Test("a salvaged FIELD does not block a write, and read tools surface the damage")
    func fieldSalvageDoesNotBlock() throws {
        try Self.withHarness { h in
            // The live 2026-09-02 corruption: a uuid that isn't one. The
            // field drops, the row survives, and writing is still correct.
            try Self.write("""
                {"projects": [
                  {"name": "Kept", "path": "/tmp/kept", "uuid": "NOT-A-UUID-2026"}
                ]}
                """, to: h.registryPath)

            let outcome = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])
            #expect(!outcome.isError)
            #expect(ProjectDashboardService(context: h.context).loadRegistry().projects.count == 2)
        }
    }

    @Test("project_list reports a damaged registry so an agent knows before it writes")
    func listReportsRegistryDamage() throws {
        try Self.withHarness { h in
            try Self.write("""
                {"projects": [{"name": "Kept", "path": "/tmp/kept"}, {"path": "/tmp/nameless"}]}
                """, to: h.registryPath)

            let fields = try Self.payload(h.tools.call(name: "project_list", arguments: [:]))
            guard case .object(let registry)? = fields["registry"] else {
                Issue.record("no registry block in project_list output")
                return
            }
            #expect(registry["healthy"] == .bool(false))
            #expect(registry["droppedRows"] == .int(1))
            #expect(registry["warning"] != nil)
        }
    }

    // MARK: - project_list / project_get

    @Test("list and get resolve a project by name or by absolute path")
    func listAndGet() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])

            let listed = try Self.payload(h.tools.call(name: "project_list", arguments: [:]))
            #expect(listed["count"] == .int(1))

            let byName = h.tools.call(name: "project_get", arguments: ["project": .string("Demo")])
            #expect(!byName.isError)

            // A trailing slash is not a "no such project".
            let byPath = h.tools.call(name: "project_get", arguments: [
                "project": .string(h.projectRoot.path + "/"),
            ])
            #expect(!byPath.isError)

            let missing = h.tools.call(name: "project_get", arguments: [
                "project": .string("Nope"),
            ])
            #expect(missing.isError)
            #expect(missing.text.contains("Known projects: Demo"))
        }
    }

    @Test("get reports an unparseable project.json instead of overwriting it")
    func getReportsMalformedRecord() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])
            let recordPath = ProjectStore.recordPath(forProjectPath: h.projectRoot.path)
            try Self.write("{ this is not json", to: recordPath)

            let outcome = h.tools.call(name: "project_get", arguments: ["project": .string("Demo")])
            #expect(!outcome.isError)
            #expect(outcome.text.contains("could not be parsed"))
            // Untouched: it is the only copy of whatever was meant.
            #expect(try String(contentsOfFile: recordPath, encoding: .utf8) == "{ this is not json")
        }
    }

    // MARK: - project_update_dashboard

    @Test("a valid dashboard is written once, pretty-printed")
    func dashboardHappyPath() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])

            let outcome = h.tools.call(name: "project_update_dashboard", arguments: [
                "project": .string("Demo"),
                "dashboard": .string(Self.validDashboard),
            ])
            #expect(!outcome.isError)

            let entry = ProjectDashboardService(context: h.context)
                .loadRegistry().projects.first!
            let loaded = ProjectDashboardService(context: h.context).loadDashboard(for: entry)
            #expect(loaded?.title == "Demo")
            #expect(loaded?.sections.first?.widgets.count == 2)
        }
    }

    @Test("an unknown widget type is refused by JSON path, and nothing is written")
    func dashboardRejectsUnknownWidget() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])
            _ = h.tools.call(name: "project_update_dashboard", arguments: [
                "project": .string("Demo"), "dashboard": .string(Self.validDashboard),
            ])
            let dashboardPath = h.projectRoot.path + "/.scarf/dashboard.json"
            let before = try String(contentsOfFile: dashboardPath, encoding: .utf8)

            let outcome = h.tools.call(name: "project_update_dashboard", arguments: [
                "project": .string("Demo"),
                "dashboard": .string("""
                    {"version": 1, "title": "Demo", "sections": [
                      {"title": "S", "widgets": [{"type": "metric", "title": "Nope"}]}
                    ]}
                    """),
            ])
            #expect(outcome.isError)
            #expect(outcome.text.contains("sections[0].widgets[0].type"))
            #expect(outcome.text.contains("unknown widget type"))
            #expect(try String(contentsOfFile: dashboardPath, encoding: .utf8) == before)
        }
    }

    @Test("a widget missing a field its type requires names the field")
    func dashboardRejectsMissingRequiredField() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])
            let outcome = h.tools.call(name: "project_update_dashboard", arguments: [
                "project": .string("Demo"),
                "dashboard": .string("""
                    {"version": 1, "title": "Demo", "sections": [
                      {"title": "S", "widgets": [{"type": "table", "title": "T"}]}
                    ]}
                    """),
            ])
            #expect(outcome.isError)
            #expect(outcome.text.contains("sections[0].widgets[0].columns"))
            #expect(outcome.text.contains("sections[0].widgets[0].rows"))
        }
    }

    @Test("a file widget can't point outside the project")
    func dashboardRejectsPathEscape() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])
            for escape in ["../../etc/passwd", "/etc/passwd"] {
                let outcome = h.tools.call(name: "project_update_dashboard", arguments: [
                    "project": .string("Demo"),
                    "dashboard": .string("""
                        {"version": 1, "title": "D", "sections": [
                          {"title": "S", "widgets": [
                            {"type": "markdown_file", "title": "M", "path": "\(escape)"}
                          ]}
                        ]}
                        """),
                ])
                #expect(outcome.isError)
                #expect(outcome.text.contains("stay inside the project"))
            }
        }
    }

    @Test("a webview can't be pointed at a local file")
    func dashboardRejectsFileURL() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])
            let outcome = h.tools.call(name: "project_update_dashboard", arguments: [
                "project": .string("Demo"),
                "dashboard": .string("""
                    {"version": 1, "title": "D", "sections": [
                      {"title": "S", "widgets": [
                        {"type": "webview", "title": "W", "url": "file:///etc/passwd"}
                      ]}
                    ]}
                    """),
            ])
            #expect(outcome.isError)
            #expect(outcome.text.contains("http:// or https://"))
        }
    }

    @Test("a damaged registry says so instead of claiming the project doesn't exist")
    func selectorFailureReportsRegistryDamage() throws {
        try Self.withHarness { h in
            // Not a registry at all: quarantined, and every caller sees an
            // EMPTY project list as a result.
            try Self.write("this is not json at all", to: h.registryPath)

            let outcome = h.tools.call(name: "project_get", arguments: [
                "project": .string("Demo"),
            ])
            #expect(outcome.isError)
            #expect(outcome.text.contains("set aside"))
            #expect(outcome.text.contains("project_validate"))
            // The old message sent the agent off to re-register everything.
            #expect(!outcome.text.contains("No projects are registered yet"))
        }
    }

    @Test("structurally broken JSON comes back as a decode error, not a write")
    func dashboardRejectsGarbage() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])

            let notJSON = h.tools.call(name: "project_update_dashboard", arguments: [
                "project": .string("Demo"), "dashboard": .string("{ nope"),
            ])
            #expect(notJSON.isError)

            let missingTitle = h.tools.call(name: "project_update_dashboard", arguments: [
                "project": .string("Demo"),
                "dashboard": .string(#"{"version": 1, "sections": []}"#),
            ])
            #expect(missingTitle.isError)
            #expect(missingTitle.text.contains("title"))

            #expect(!FileManager.default.fileExists(
                atPath: h.projectRoot.path + "/.scarf/dashboard.json"
            ))
        }
    }

    @Test("the dashboard may arrive as an object as well as a string")
    func dashboardAcceptsObjectForm() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])
            let document = try JSONDecoder()
                .decode(JSONValue.self, from: Data(Self.validDashboard.utf8))
            let outcome = h.tools.call(name: "project_update_dashboard", arguments: [
                "project": .string("Demo"), "dashboard": document,
            ])
            #expect(!outcome.isError)
        }
    }

    @Test("keys the dashboard model doesn't declare survive the write")
    func dashboardPreservesUnknownKeys() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])
            _ = h.tools.call(name: "project_update_dashboard", arguments: [
                "project": .string("Demo"),
                "dashboard": .string("""
                    {"version": 1, "title": "Demo", "futureKey": {"a": 1}, "sections": [
                      {"title": "S", "widgets": [{"type": "stat", "title": "N", "value": 1}]}
                    ]}
                    """),
            ])
            let written = try String(
                contentsOfFile: h.projectRoot.path + "/.scarf/dashboard.json", encoding: .utf8
            )
            #expect(written.contains("futureKey"))
        }
    }

    // MARK: - project_add_slash_command

    @Test("a slash command is written, and not silently replaced")
    func slashCommand() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])

            let created = h.tools.call(name: "project_add_slash_command", arguments: [
                "project": .string("Demo"),
                "name": .string("review"),
                "description": .string("Review the branch"),
                "body": .string("Review {{argument}}."),
            ])
            #expect(!created.isError)

            let commands = ProjectSlashCommandService(context: h.context)
                .loadCommands(at: h.projectRoot.path)
            #expect(commands.map(\.name) == ["review"])

            let clash = h.tools.call(name: "project_add_slash_command", arguments: [
                "project": .string("Demo"),
                "name": .string("review"),
                "description": .string("Different"),
                "body": .string("Different."),
            ])
            #expect(clash.isError)
            #expect(clash.text.contains("overwrite: true"))

            let replaced = h.tools.call(name: "project_add_slash_command", arguments: [
                "project": .string("Demo"),
                "name": .string("review"),
                "description": .string("Different"),
                "body": .string("Different."),
                "overwrite": .bool(true),
            ])
            #expect(!replaced.isError)
        }
    }

    @Test("an invalid command name is refused by the model's own validator")
    func slashCommandRejectsBadName() throws {
        try Self.withHarness { h in
            _ = h.tools.call(name: "project_register", arguments: [
                "name": .string("Demo"), "path": .string(h.projectRoot.path),
            ])
            let outcome = h.tools.call(name: "project_add_slash_command", arguments: [
                "project": .string("Demo"),
                "name": .string("Not A Command"),
                "description": .string("d"),
                "body": .string("b"),
            ])
            #expect(outcome.isError)
        }
    }

    // MARK: - project_validate

    @Test("validate reports a registry row with no record, and repair: true fixes it")
    func validateAndRepair() throws {
        try Self.withHarness { h in
            // A hand-written row, exactly as the old skill step 8 produced:
            // no uuid, no project.json.
            try Self.write("""
                {"projects": [{"name": "Demo", "path": "\(h.projectRoot.path)"}]}
                """, to: h.registryPath)

            let report = h.tools.call(name: "project_validate", arguments: [:])
            #expect(!report.isError)
            let fields = try Self.payload(report)
            #expect(fields["healthy"] == .bool(false))

            let repaired = h.tools.call(name: "project_validate", arguments: ["repair": .bool(true)])
            #expect(!repaired.isError)
            #expect(ProjectStore(context: h.context).load(projectPath: h.projectRoot.path) != nil)

            let after = try Self.payload(h.tools.call(name: "project_validate", arguments: [:]))
            #expect(after["healthy"] == .bool(true))
        }
    }

    @Test("repairs stay blocked while the registry decode is lossy")
    func validateRepairBlockedOnLossyRegistry() throws {
        try Self.withHarness { h in
            try Self.write("""
                {"projects": [
                  {"name": "Demo", "path": "\(h.projectRoot.path)"},
                  {"path": "/tmp/nameless"}
                ]}
                """, to: h.registryPath)
            let before = try String(contentsOfFile: h.registryPath, encoding: .utf8)

            let outcome = h.tools.call(name: "project_validate", arguments: ["repair": .bool(true)])
            #expect(!outcome.isError)
            let fields = try Self.payload(outcome)
            #expect(fields["repairsBlocked"] != nil)
            #expect(fields["repaired"] == .array([]))
            #expect(try String(contentsOfFile: h.registryPath, encoding: .utf8) == before)
        }
    }

    // MARK: - Argument handling

    @Test("missing, mistyped and unknown inputs are actionable errors, never crashes")
    func argumentErrors() throws {
        try Self.withHarness { h in
            let missing = h.tools.call(name: "project_get", arguments: [:])
            #expect(missing.isError)
            #expect(missing.text.contains("Missing required argument \"project\""))

            let mistyped = h.tools.call(name: "project_get", arguments: ["project": .int(7)])
            #expect(mistyped.isError)
            #expect(mistyped.text.contains("must be a string"))

            let empty = h.tools.call(name: "project_get", arguments: ["project": .string("   ")])
            #expect(empty.isError)
            #expect(empty.text.contains("must not be empty"))

            let badBool = h.tools.call(name: "project_list", arguments: [
                "includeArchived": .string("yes"),
            ])
            #expect(badBool.isError)
            #expect(badBool.text.contains("true or false"))

            let unknown = h.tools.call(name: "project_nuke", arguments: [:])
            #expect(unknown.isError)
            #expect(unknown.text.contains("Unknown tool"))
        }
    }
}
