import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R2's YAML hardening: what the surgical patcher does when handed a
/// `config.yaml` that isn't the one Hermes wrote.
///
/// The stakes are the whole file, not one value. The patcher is line-based
/// and assumes an exact shape; the only failure mode worth designing for is
/// "we didn't understand this, so we changed nothing". Every case below is
/// legal YAML that Hermes reads fine — the assertion is always that Scarf
/// left it byte-identical and said no.
@Suite struct HermesConfigPatchSafetyTests {

    private static func write(_ yaml: String, to home: TempHermesHome) throws {
        try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
    }

    private static func read(_ home: TempHermesHome) throws -> String {
        try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
    }

    // MARK: - Fail closed

    /// Each case is `(label, config)`. All of them contain a
    /// `scarf-projects` entry that a naive patcher would happily "fix".
    static let unpatchable: [(String, String)] = [
        ("three-space indent", """
            mcp_servers:
              scarf-projects:
                 command: /old/path
                 enabled: true
            """),
        ("tab indentation", "mcp_servers:\n  scarf-projects:\n\tcommand: /old/path\n"),
        ("block scalar", """
            mcp_servers:
              scarf-projects:
                command: |
                  /old/path
                enabled: true
            """),
        ("folded block scalar", """
            mcp_servers:
              scarf-projects:
                command: >-
                  /old/path
            """),
        ("anchor", """
            mcp_servers:
              scarf-projects:
                command: &cmd /old/path
                enabled: true
            """),
        ("alias", """
            mcp_servers:
              other:
                command: &cmd /old/path
              scarf-projects:
                command: *cmd
            """),
        ("merge key", """
            mcp_servers:
              scarf-projects:
                <<: *defaults
                command: /old/path
            """),
        ("flow mapping entry", """
            mcp_servers:
              scarf-projects: {command: /old/path}
            """),
        // Consistent, legal, and NOT indent 4: `replaceOrInsertScalar` would
        // find no indent-4 `command` to replace and insert one, giving this
        // mapping two indentations.
        ("six-space keys", """
            mcp_servers:
              scarf-projects:
                  command: /old/path
                  enabled: true
            """),
        ("five-space key", """
            mcp_servers:
              scarf-projects:
                command: /old/path
                 enabled: true
            """),
    ]

    @Test("a config shape the patcher doesn't understand is left byte-identical", arguments: unpatchable)
    func unrecognizedShapesFailClosed(label: String, yaml: String) throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try Self.write(yaml, to: home)

        let ok = HermesFileService(context: home.context)
            .setMCPServerCommand(name: "scarf-projects", command: "/new/path")

        #expect(!ok, "\(label): the patch reported success")
        #expect(try Self.read(home) == yaml, "\(label): the file was modified")
    }

    @Test("the shape Hermes actually writes is still patched")
    func theNormalShapeStillWorks() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try Self.write("""
            mcp_servers:
              scarf-projects:
                command: /old/path
                enabled: true
              other:
                url: https://example.com/mcp
            """, to: home)

        let service = HermesFileService(context: home.context)
        #expect(service.setMCPServerCommand(name: "scarf-projects", command: "/new/path"))

        let written = try Self.read(home)
        #expect(written.contains("    command: /new/path"))
        #expect(written.contains("    enabled: true"))
        #expect(written.contains("  other:"))
        #expect(service.loadMCPServers().count == 2)
    }

    // MARK: - Backup + restore

    @Test("the first mutating patch of a launch leaves a timestamped backup")
    func firstPatchBacksUpTheConfig() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let original = """
            mcp_servers:
              scarf-projects:
                command: /old/path
            """
        try Self.write(original, to: home)

        let service = HermesFileService(context: home.context)
        #expect(service.setMCPServerCommand(name: "scarf-projects", command: "/new/path"))
        // A SECOND patch in the same process must not take a second backup:
        // the point is a copy of what the user had before Scarf touched
        // anything today, not a copy of Scarf's own previous edit.
        #expect(service.setMCPServerCommand(name: "scarf-projects", command: "/newer/path"))

        let dir = (home.context.paths.configYAML as NSString).deletingLastPathComponent
        let base = (home.context.paths.configYAML as NSString).lastPathComponent
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix(base + ".scarf-backup-") }
        #expect(backups.count == 1, "expected exactly one backup per launch, got \(backups)")
        let kept = try String(contentsOfFile: dir + "/" + backups[0], encoding: .utf8)
        #expect(kept == original, "the backup must hold what the user had BEFORE the patch")
    }

    @Test("a verification failure is a restore, not a shrug")
    func verificationRejectsAMangledResult() {
        // The verifier is what stands between "the write returned no error"
        // and "the file is still a config". Exercised directly, because
        // producing a mangled write through the patcher is exactly what the
        // gate now prevents.
        let before = ["scarf-projects", "other"]
        let lostAServer = """
            mcp_servers:
              scarf-projects:
                command: /new/path
            """
        #expect(
            HermesFileService.verifyPatchedConfig(
                text: lostAServer, name: "scarf-projects", expecting: [], namesBefore: before
            ) != nil
        )
        let intact = """
            mcp_servers:
              scarf-projects:
                command: /new/path
              other:
                url: https://example.com/mcp
            """
        #expect(
            HermesFileService.verifyPatchedConfig(
                text: intact, name: "scarf-projects",
                expecting: ["    command: /new/path"], namesBefore: before
            ) == nil
        )
        #expect(
            HermesFileService.verifyPatchedConfig(
                text: intact, name: "scarf-projects",
                expecting: ["    command: /somewhere/else"], namesBefore: before
            ) != nil,
            "a value that didn't land must not pass verification"
        )
    }

    // MARK: - Parser hardening (M11)

    @Test("a CRLF config is read, not mistaken for an empty one")
    func crlfConfigIsParsed() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let yaml = "mcp_servers:\r\n  scarf-projects:\r\n    command: /old/path\r\n    enabled: true\r\n"
        try Self.write(yaml, to: home)

        let service = HermesFileService(context: home.context)
        let entry = service.loadMCPServers().first { $0.name == "scarf-projects" }
        #expect(entry != nil, "a CRLF config read as having no servers — the retry storm's cause")
        #expect(entry?.command == "/old/path")

        #expect(service.setMCPServerCommand(name: "scarf-projects", command: "/new/path"))
        let written = try Self.read(home)
        #expect(written.contains("    command: /new/path\r\n"), "the file's line endings changed")
        #expect(
            service.loadMCPServers().first { $0.name == "scarf-projects" }?.command == "/new/path"
        )
    }

    @Test("a quoted entry key is the same entry")
    func quotedEntryKeyIsFound() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try Self.write("""
            mcp_servers:
              "scarf-projects":
                command: /old/path
            """, to: home)

        let service = HermesFileService(context: home.context)
        #expect(service.loadMCPServers().first?.name == "scarf-projects")
        #expect(service.setMCPServerCommand(name: "scarf-projects", command: "/new/path"))
        #expect(
            service.loadMCPServers().first { $0.name == "scarf-projects" }?.command == "/new/path"
        )
    }

    @Test("a trailing comment is not part of the value")
    func inlineCommentsAreStripped() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try Self.write("""
            mcp_servers:
              scarf-projects:
                command: /old/path  # installed by Scarf
                timeout: 180 # seconds
            """, to: home)

        let entry = HermesFileService(context: home.context)
            .loadMCPServers().first { $0.name == "scarf-projects" }
        #expect(entry?.command == "/old/path", "the comment rode along as part of the path")
        #expect(entry?.timeout == 180)
    }

    @Test("a # inside a quoted value is not a comment")
    func hashInsideQuotesSurvives() {
        #expect(HermesFileService.stripInlineComment("\"/opt/a#b/x\"") == "\"/opt/a#b/x\"")
        #expect(HermesFileService.stripInlineComment("/opt/a#b") == "/opt/a#b")
        #expect(HermesFileService.stripInlineComment("/opt/x # note") == "/opt/x")
        #expect(HermesFileService.stripInlineComment("# all comment") == "")
    }

    // MARK: - Quote/unquote symmetry

    @Test("yamlScalar and unquote are inverses, backslashes included")
    func quotingRoundTrips() {
        for value in [
            #"/Users/a/Scarf.app/x"#,
            #"/Users/a/Scarf Dev.app/x"#,
            #"/Users/a/we\ird/x"#,
            // Forces the QUOTED branch (the colon) while carrying a
            // backslash — the combination the escape/unescape pair got
            // wrong, and the one an unquoted value never exercises.
            #"/Users/a/we\ird:x"#,
            #"/Users/a/tra\\iling\"#,
            #"/Users/a/"quoted"/x"#,
            #"/Users/a/c:olon/x"#,
            #"-leading-dash"#,
            "true",
        ] {
            #expect(
                HermesFileService.unquote(HermesFileService.yamlScalar(value)) == value,
                "round-trip lost \(value)"
            )
        }
        // Single-quoted YAML, which Hermes may write and we must read.
        #expect(HermesFileService.unquote("'/opt/it''s/x'") == "/opt/it's/x")
    }

    // MARK: - The gate's own vocabulary

    @Test("the gate accepts the shapes it is supposed to accept")
    func gateAcceptsNormalEntries() {
        #expect(HermesFileService.unpatchableReason(entryLines: [
            "  scarf-projects:",
            "    command: /x",
            "    args:",
            "      - --flag",
            "    tools:",
            "      include:",
            "        - a",
            "      resources: false",
            "",
            "    # a comment",
        ]) == nil)
    }
}
