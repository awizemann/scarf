import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P10 — the MCP-entry scalar writers and the platform-section detector must
/// not produce (or mis-read) a config.yaml PyYAML rejects.
///
/// At Hermes v2026.9.7, `gateway/config.py:776-791` wraps the config.yaml
/// load in a bare `except Exception` that logs "Failed to process
/// config.yaml — falling back to .env / gateway.json values." and CONTINUES.
/// A single unquoted `#` or `:` in a path therefore doesn't fail loudly — it
/// silently discards the user's ENTIRE config.yaml layer.
struct ConfigYAMLScalarQuotingTests {

    // MARK: - PyYAML harness (structural checks run regardless)

    private static let pyYAMLAvailable: Bool = { run("import yaml") != nil }()

    @discardableResult
    private static func run(_ script: String, stdin text: String = "") -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", script]
        let out = Pipe(), err = Pipe(), input = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = input
        do { try proc.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(text.utf8))
        input.fileHandleForWriting.closeFile()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `yaml.safe_load(stdin)['mcp_servers'][server][key]` as a repr, or nil
    /// when PyYAML refuses the document.
    private static func mcpValue(_ yaml: String, _ server: String, _ key: String) -> String? {
        let script = """
        import sys,yaml
        d = yaml.safe_load(sys.stdin.read())
        print(repr(d['mcp_servers']['\(server)']['\(key)']))
        """
        return run(script, stdin: yaml)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parses(_ yaml: String) -> Bool {
        run("import sys,yaml; yaml.safe_load(sys.stdin.read())", stdin: yaml) != nil
    }

    // MARK: - Fixture

    private static let fixtureYAML = """
    mcp_servers:
      remote_api:
        url: https://my-mcp-server.example.com/mcp
        transport: http
        enabled: true
    """

    private func loadFixture() throws -> (service: HermesFileService, home: TempHermesHome) {
        let home = try TempHermesHome()
        try Self.fixtureYAML.write(
            toFile: home.context.paths.configYAML,
            atomically: true,
            encoding: .utf8
        )
        return (HermesFileService(context: home.context), home)
    }

    private func readConfig(_ home: TempHermesHome) throws -> String {
        try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
    }

    // MARK: - 4. Path/scalar writers route through `yamlScalar`

    /// Every one of these values is legal on disk and illegal as a bare YAML
    /// scalar. Written unquoted they either raise (`{`, `[`, `*`, `&`, a
    /// leading `%`) or silently truncate at the ` #` comment marker.
    private static let hostilePaths = [
        "/Users/alan/Library/Application Support/certs/client.pem",
        "/certs/a#b.pem",
        "/certs/a:b.pem",
        "/certs/{tmpl}.pem",
        "/certs/[x].pem",
        "*glob.pem",
        "&anchor.pem",
        "%directive.pem",
        "`tick.pem",
        "@leading.pem",
        "-leading.pem",
    ]

    @Test func clientCertPathIsQuotedAndParsesBack() throws {
        for path in Self.hostilePaths {
            let (service, home) = try loadFixture()
            #expect(service.setMCPServerClientCert(name: "remote_api", path: path))
            let yaml = try readConfig(home)
            if Self.pyYAMLAvailable {
                #expect(Self.parses(yaml), "PyYAML rejected client_cert \(path):\n\(yaml)")
                let readBack = Self.mcpValue(yaml, "remote_api", "client_cert")
                #expect(
                    readBack == "'\(path)'",
                    "client_cert did not round-trip for \(path): got \(readBack ?? "nil")"
                )
            }
            // Structural, for the values a bare emission genuinely breaks:
            // a plain scalar may legally contain spaces and (in block
            // context) brackets/braces, so those need no quoting — but a
            // ` #`, a `: `, or a leading indicator MUST be quoted.
            if path.contains("#") || path.contains(":")
                || "*&%`@-".contains(path.first ?? "x") {
                #expect(!yaml.contains("client_cert: \(path)"), "emitted bare: \(path)")
            }
        }
    }

    @Test func clientKeyPathIsQuotedAndParsesBack() throws {
        let path = "/certs/a#b key.pem"
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerClientKey(name: "remote_api", path: path))
        let yaml = try readConfig(home)
        #expect(!yaml.contains("client_key: \(path)"))   // has a `#`
        if Self.pyYAMLAvailable {
            #expect(Self.parses(yaml))
            #expect(Self.mcpValue(yaml, "remote_api", "client_key") == "'\(path)'")
        }
    }

    /// `ssl_verify` is either a bool string or a CA-bundle PATH, so it takes
    /// the same hostile inputs.
    @Test func sslVerifyCABundlePathIsQuotedAndParsesBack() throws {
        let path = "/etc/ssl/ca#bundle: prod.pem"
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerSSLVerify(name: "remote_api", value: path))
        let yaml = try readConfig(home)
        #expect(!yaml.contains("ssl_verify: \(path)"))
        if Self.pyYAMLAvailable {
            #expect(Self.parses(yaml))
            #expect(Self.mcpValue(yaml, "remote_api", "ssl_verify") == "'\(path)'")
        }
    }

    /// `ssl_verify: true` / `false` must still land as a BOOLEAN, not the
    /// string `"true"` — quoting that would flip Hermes's meaning.
    @Test func sslVerifyBooleansStayBooleans() throws {
        for raw in ["true", "false"] {
            let (service, home) = try loadFixture()
            #expect(service.setMCPServerSSLVerify(name: "remote_api", value: raw))
            let yaml = try readConfig(home)
            if Self.pyYAMLAvailable {
                #expect(Self.parses(yaml))
                #expect(
                    Self.mcpValue(yaml, "remote_api", "ssl_verify") == (raw == "true" ? "True" : "False"),
                    "ssl_verify \(raw) stopped being a bool"
                )
            }
        }
    }

    @Test func cwdPathIsQuotedAndParsesBack() throws {
        let path = "/Users/alan/Projects/my repo #2"
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerCwd(name: "remote_api", path: path))
        let yaml = try readConfig(home)
        #expect(!yaml.contains("cwd: \(path)"))
        if Self.pyYAMLAvailable {
            #expect(Self.parses(yaml))
            #expect(Self.mcpValue(yaml, "remote_api", "cwd") == "'\(path)'")
        }
    }

    /// A plain path must stay UNQUOTED — the fix must not churn every
    /// existing config.yaml on the next save (charter C1: a pre-target host
    /// renders byte-identical).
    @Test func ordinaryPathsAreStillEmittedBare() throws {
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerCwd(name: "remote_api", path: "/Users/alan/Projects/repo"))
        #expect(try readConfig(home).contains("cwd: /Users/alan/Projects/repo"))
    }

    // MARK: - 5. The SSE transport stamp is not discarded

    /// `transport: sse` is the ONLY thing that discriminates an SSE entry
    /// from the plain HTTP entry `hermes mcp add --url` writes. The patcher
    /// returns `false` when it cannot find the entry to stamp; that Bool used
    /// to be dropped on the floor with `_ =`, so the UI reported a
    /// successful SSE add for a server that is, on disk, HTTP.
    ///
    /// Driving `addMCPServerSSE` end-to-end needs a live `hermes` binary, so
    /// this pins the seam two ways: the patcher's Bool is real (it says
    /// `false` for an entry that isn't there), and the call site consumes it.
    @Test func transportStampFailureIsObservable() throws {
        let (service, home) = try loadFixture()
        // A name with no entry: the stamp cannot land. Any user of
        // `patchMCPServerField` proves that (the SSE-specific one is gone —
        // `sse_read_timeout` is a key no supported Hermes reads, see P24).
        #expect(service.setMCPServerTimeouts(name: "no_such_server", timeout: 30, connectTimeout: nil) == false)
        // …and the real entry is untouched.
        #expect(try readConfig(home) == Self.fixtureYAML)
    }


    /// Source-scan (the repo's established guard for a write seam that
    /// cannot be driven in a unit test without a live `hermes` binary — see
    /// the `unguarded-write-seam` convention): `addMCPServerSSE` must not
    /// discard the transport stamp's result.
    @Test func addMCPServerSSEDoesNotDiscardTheStampResult() throws {
        let source = try String(
            contentsOfFile: Self.repoFile("scarf/scarf/Core/Services/HermesFileService.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "func addMCPServerSSE(") else {
            Issue.record("addMCPServerSSE not found — did it move?")
            return
        }
        let body = source[start.upperBound...].prefix(3000)
        guard let stamp = body.range(of: #"replaceOrInsertScalar(key: "transport", value: "sse""#) else {
            Issue.record("the transport stamp is no longer in addMCPServerSSE")
            return
        }
        let before = body[body.startIndex..<stamp.lowerBound]
        #expect(
            !before.contains("_ = patchMCPServerField"),
            "addMCPServerSSE discards the transport stamp's result again"
        )
        #expect(before.contains("let stamped = patchMCPServerField"))
        #expect(body.contains("guard stamped else"))
    }

    private static func repoFile(_ relative: String) -> String {
        // …/scarf/scarfTests/ThisFile.swift → repo root
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // scarfTests
        url.deleteLastPathComponent()   // scarf
        url.deleteLastPathComponent()   // repo root
        return url.appendingPathComponent(relative).path
    }

    // MARK: - 8. Platform-section detection

    /// `slack: {}` (what Hermes itself emits for a preserved-but-empty
    /// section) and `slack:  # comment` are BOTH configured sections. The old
    /// `hasSuffix(":")` test saw neither, so the platform row rendered as
    /// unconfigured and the setup sheet offered to create a section that
    /// already existed.
    @Test func flowEmptyAndCommentedSectionsCountAsConfigured() throws {
        let cases: [(String, String)] = [
            ("slack: {}\n", "flow-empty section"),
            ("slack:  # work workspace\n", "section with a trailing comment"),
            ("slack: {reply_to_mode: first}\n", "non-empty flow section"),
            ("slack:\n  reply_to_mode: first\n", "ordinary block section"),
            ("slack:\r\n  reply_to_mode: first\r\n", "CRLF block section"),
        ]
        for (yaml, label) in cases {
            let home = try TempHermesHome()
            try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
            let configured = PlatformsViewModel.computeConfiguredPlatforms(context: home.context)
            #expect(configured.contains("slack"), "\(label) was not detected as configured")
        }
    }

    /// …and nothing that isn't a top-level section becomes one.
    @Test func nonSectionLinesAreNotMistakenForPlatforms() throws {
        let home = try TempHermesHome()
        let yaml = """
        # slack: not a section, a comment
        toolsets:
        - slack
        agent:
          note: 'slack: still not a section'
        """
        try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        #expect(!PlatformsViewModel.computeConfiguredPlatforms(context: home.context).contains("slack"))
    }

    /// P26 — the comment above the split claimed it cut at the `key: value`
    /// separator colon; the code cut at `firstIndex(of: ":")`. On a top-level
    /// key that CONTAINS a colon those disagree, and the plain-first-colon
    /// version invented a platform the file never configured. Neither line
    /// below is a `slack` / `teams` section.
    @Test func colonInsideATopLevelKeyDoesNotInventAPlatform() throws {
        let home = try TempHermesHome()
        let yaml = """
        slack:dev: {}
        teams:staging:
          reply_to_mode: first
        discord: {}
        """
        try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let configured = PlatformsViewModel.computeConfiguredPlatforms(context: home.context)
        #expect(!configured.contains("slack"), "`slack:dev:` is not a `slack` section")
        #expect(!configured.contains("teams"), "`teams:staging:` is not a `teams` section")
        // The separator rule still finds an ordinary section in the same file.
        #expect(configured.contains("discord"))
    }
}
