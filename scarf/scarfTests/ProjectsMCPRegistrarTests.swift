import Testing
import Foundation
import ScarfCore
@testable import scarf

/// The launch-time registration of the bundled `scarf-projects` MCP server.
///
/// The creation path shells `hermes mcp add` and is not exercised here —
/// the argv it builds is pinned by `HermesMCPAdd`'s own tests, and
/// spawning the real CLI would make this suite depend on the developer's
/// Hermes install. What IS covered is everything that runs on EVERY
/// launch: the idempotent no-op, the re-point after the app moves, and
/// the refusal to trample an entry that isn't ours.
struct ProjectsMCPRegistrarTests {

    /// A fake bundled helper. `isExecutableFile` is what the registrar
    /// checks, so the file has to actually be one.
    private static func makeHelper(named name: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    private static func config(command: String) -> String {
        """
        mcp_servers:
          scarf-projects:
            command: \(command)
            timeout: 180
            tools:
              exclude:
                - project_validate
          other_server:
            url: https://example.com/mcp
        """
    }

    @Test("a launch where nothing moved writes nothing at all")
    func unchangedIsANoOp() throws {
        let home = try TempHermesHome()
        let helper = try Self.makeHelper(
            named: "scarf-projects-mcp",
            in: home.url.appendingPathComponent("bundle", isDirectory: true)
        )
        try Self.config(command: helper.path)
            .write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let before = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)

        let outcome = ProjectsMCPRegistrar(context: home.context, binaryURL: helper)
            .ensureRegistered()

        #expect(outcome == .unchanged(path: helper.path))
        // Byte-identical: Hermes watches this file, and a rewrite on every
        // launch is churn a running agent would see.
        #expect(try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8) == before)
    }

    @Test("moving the app re-points the command in place, keeping the user's own settings")
    func relocationRepointsInPlace() throws {
        let home = try TempHermesHome()
        try Self.config(command: "/Applications/Old Location/Scarf.app/Contents/Helpers/scarf-projects-mcp")
            .write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let helper = try Self.makeHelper(
            named: "scarf-projects-mcp",
            in: home.url.appendingPathComponent("new-bundle", isDirectory: true)
        )

        let outcome = ProjectsMCPRegistrar(context: home.context, binaryURL: helper)
            .ensureRegistered()

        guard case .repointed(let from, let to) = outcome else {
            Issue.record("expected a re-point, got \(outcome)")
            return
        }
        #expect(from.hasSuffix("Old Location/Scarf.app/Contents/Helpers/scarf-projects-mcp"))
        #expect(to == helper.path)

        let servers = HermesFileService(context: home.context).loadMCPServers()
        let entry = servers.first { $0.name == "scarf-projects" }
        #expect(entry?.command == helper.path)
        // Remove-and-re-add would have discarded these; patching keeps them.
        #expect(entry?.timeout == 180)
        #expect(entry?.toolsExclude == ["project_validate"])
        // And the unrelated server is untouched.
        #expect(servers.contains { $0.name == "other_server" })
    }

    @Test("a re-point is idempotent — running it twice writes once")
    func repointThenNoOp() throws {
        let home = try TempHermesHome()
        try Self.config(command: "/old/path/scarf-projects-mcp")
            .write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let helper = try Self.makeHelper(
            named: "scarf-projects-mcp",
            in: home.url.appendingPathComponent("bundle", isDirectory: true)
        )
        let registrar = ProjectsMCPRegistrar(context: home.context, binaryURL: helper)

        _ = registrar.ensureRegistered()
        let afterFirst = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        let second = registrar.ensureRegistered()

        #expect(second == .unchanged(path: helper.path))
        #expect(try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8) == afterFirst)
    }

    @Test("a path with a space is quoted, so the YAML still parses")
    func spacedPathIsQuoted() throws {
        let home = try TempHermesHome()
        try Self.config(command: "/old/path/scarf-projects-mcp")
            .write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        // "Scarf Dev.app" is a real bundle name this project builds.
        let helper = try Self.makeHelper(
            named: "scarf-projects-mcp",
            in: home.url.appendingPathComponent("Scarf Dev.app/Contents/Helpers", isDirectory: true)
        )

        _ = ProjectsMCPRegistrar(context: home.context, binaryURL: helper).ensureRegistered()

        let entry = HermesFileService(context: home.context)
            .loadMCPServers().first { $0.name == "scarf-projects" }
        #expect(entry?.command == helper.path)
    }

    @Test("a user's own non-stdio server squatting the name is left alone")
    func urlServerIsNotTrampled() throws {
        let home = try TempHermesHome()
        try """
            mcp_servers:
              scarf-projects:
                url: https://example.com/mcp
            """.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let before = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        let helper = try Self.makeHelper(
            named: "scarf-projects-mcp",
            in: home.url.appendingPathComponent("bundle", isDirectory: true)
        )

        let outcome = ProjectsMCPRegistrar(context: home.context, binaryURL: helper)
            .ensureRegistered()

        guard case .skipped(let reason) = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason.contains("not a stdio server"))
        #expect(try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8) == before)
    }

    @Test("a dev copy, a /tmp copy and a DerivedData build never claim the config")
    func transientBundlesAreSkipped() {
        let transient = [
            "/tmp/scarf-agent-build/scarf.app/Contents/Helpers/scarf-projects-mcp",
            "/private/var/folders/x/T/scarf.app/Contents/Helpers/scarf-projects-mcp",
            "/Users/me/Library/Developer/Xcode/DerivedData/scarf-abc/Build/Products/Debug/scarf.app/Contents/Helpers/scarf-projects-mcp",
            "/Applications/scarf-dev.app/Contents/Helpers/scarf-projects-mcp",
        ]
        for path in transient {
            #expect(
                ProjectsMCPRegistrar.transientBundleReason(path) != nil,
                "\(path) should not claim the Hermes config"
            )
        }
        // The installed app is the one copy that may.
        #expect(ProjectsMCPRegistrar.transientBundleReason(
            "/Applications/Scarf.app/Contents/Helpers/scarf-projects-mcp"
        ) == nil)
    }

    @Test("a build with no bundled helper does nothing rather than failing")
    func missingHelperIsASkip() throws {
        let home = try TempHermesHome()
        let absent = home.url.appendingPathComponent("nope/scarf-projects-mcp")

        let outcome = ProjectsMCPRegistrar(context: home.context, binaryURL: absent)
            .ensureRegistered()

        // The injected URL isn't executable, so it falls through to the
        // bundle lookup, which finds nothing in a test runner.
        guard case .skipped = outcome else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: home.context.paths.configYAML))
    }
}
