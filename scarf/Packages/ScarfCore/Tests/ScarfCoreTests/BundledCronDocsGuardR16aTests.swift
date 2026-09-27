import Foundation
import Testing

/// Content guards for the agent-facing docs Scarf ships (R16a). They are
/// markdown the agent follows literally, so a wrong argv in them is a
/// command that fails on the user's host. Read from the repo, the way the
/// P50b source-shape tests read view sources neither test host builds.
@Suite struct BundledCronDocsGuardR16aTests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    static func resource(_ relative: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("scarf/scarf/Resources/" + relative),
            encoding: .utf8)
    }

    static let cronCommand = "BuiltinSlashCommands.bundle/scarf-cron.md"
    static let exportCommand = "BuiltinSlashCommands.bundle/scarf-export.md"
    static let authorSkill = "BuiltinSkills.bundle/scarf-template-author/SKILL.md"

    /// S03-F6: `hermes cron create` takes the schedule and prompt as
    /// positionals, `cron list` has no `--json`, and `print` is not a
    /// delivery target (`hermes cron create --help`, `cron list --help`
    /// @ v2026.9.24).
    @Test func scarfCronUsesOnlyRealArgv() throws {
        let text = try Self.resource(Self.cronCommand)
        for bad in ["--schedule", "--prompt", "--json", "--context-from", "`print`"] {
            #expect(!text.contains(bad), "scarf-cron.md mentions \(bad)")
        }
        #expect(text.contains("hermes cron create"))
        #expect(text.contains("\"<schedule>\""))
    }

    /// Every `hermes cron create` any bundled doc tells the agent to run
    /// avoids the flags that don't exist, and one that names a job gives it
    /// the `[proj:<id>]` prefix Scarf attributes jobs by.
    @Test(arguments: [cronCommand, authorSkill])
    func cronCreateLinesUseTheProjectTag(file: String) throws {
        let lines = try Self.resource(file).split(separator: "\n")
            .filter { $0.contains("hermes cron create") && $0.contains("--name") }
        for line in lines {
            #expect(line.contains("[proj:"), "\(file): \(line)")
            #expect(!line.contains("--schedule") && !line.contains("--prompt"), "\(file): \(line)")
        }
    }

    /// Template installs name jobs `[tmpl:<id>] [proj:<project-id>] …`
    /// (`ProjectCronAttribution.templateJobName`), and the memory markers
    /// carry a hash of the id, not the id.
    @Test(arguments: [exportCommand, authorSkill])
    func templateDocsDescribeTheCurrentNaming(file: String) throws {
        let text = try Self.resource(file)
        for stale in ["prefixed with `[tmpl:<template-id>]`.", "prefixes the name with `[tmpl:<id>]`.",
                      "(`[tmpl:<id>]` name prefix"] {
            #expect(!text.contains(stale), "\(file): \(stale)")
        }
        #expect(text.contains("[proj:<project-id>]"), "\(file)")
        #expect(!text.contains("scarf-template:<id>:begin"), "\(file) still documents the id-spelling memory markers")
    }
}
