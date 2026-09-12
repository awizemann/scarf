import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P41 — `HermesFileService.yamlScalar` is a forwarder over
/// `YAMLScalar.quoteIfNeeded`, not a fourth copy of the rule.
///
/// The routine P32 left standing had a double-quoted arm that escaped
/// exactly `\\` and `\"`. Every other C0/C1 control, DEL, NEL and
/// U+2028/U+2029 therefore went out RAW inside the quotes, and PyYAML's
/// READER refuses those in every quoting style — so Hermes swallowed the
/// error and discarded the WHOLE config.yaml layer
/// (`gateway/config.py:775-791` @ `v2026.9.7`). Neither editor guarded it
/// and `patchMCPServerField(expecting:)` could not see it, because the
/// expected rows are built by the same `subMapRows` that emitted the
/// damage.
///
/// Every case here runs the value through a REAL writer (`setMCPServerEnv`
/// / `setMCPServerHeaders` / `setMCPServerCommand` / `updateMCPToolFilters`
/// / `setMCPServerCwd`) and reads it back through `YAMLScalar.unquote`, and
/// — when PyYAML is installed for `python3` — through PyYAML itself.
@Suite("P41 MCP scalar emission")
struct HermesP41MCPScalarTests {

    // MARK: - PyYAML harness (same shape as `MCPYAMLMapKeyP19Tests`)

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

    /// `yaml.safe_load(stdin)['mcp_servers'][server]` re-emitted as JSON, or
    /// `nil` when PyYAML refuses the document — which is exactly the failure
    /// Hermes turns into "the whole config.yaml layer is gone".
    private static func entryJSON(_ yaml: String, _ server: String) -> String? {
        let script = """
        import sys, json, yaml
        d = yaml.safe_load(sys.stdin.read())
        print(json.dumps(d['mcp_servers']['\(server)'], sort_keys=True, ensure_ascii=False))
        """
        return run(script, stdin: yaml)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Named so the round-trip lane's absence is a reported known issue
    /// rather than a silent vacuous pass.
    @Test func pyYAMLRoundTripLaneIsPresent() {
        withKnownIssue(
            """
            PyYAML is not installed for `python3` on this machine — the \
            round-trip half of HermesP41MCPScalarTests did NOT run. Install \
            it (`python3 -m pip install pyyaml`) to exercise the lane that \
            proves Hermes can still read what Scarf writes.
            """,
            isIntermittent: true
        ) {
            #expect(Self.pyYAMLAvailable)
        }
    }

    // MARK: - Fixture

    private static let fixtureYAML = """
    mcp_servers:
      remote_api:
        url: https://my-mcp-server.example.com/mcp
        transport: http
        enabled: true
      local_tool:
        command: /usr/local/bin/tool
        transport: stdio
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

    /// The reviewer's failing classes, one per case. Each is a value a user
    /// can paste into the MCP entry editor today.
    ///
    /// `\u{0085}` is NEL, `\u{2028}`/`\u{2029}` the Unicode line and
    /// paragraph separators, `\u{7F}` DEL, `\u{0090}` a C1 control. The tab,
    /// the leading `-`, the `: ` and the `#` are the plain-scalar hazards
    /// the old routine DID cover — they are here so a regression in either
    /// half fails.
    static let hazards: [String] = [
        "a\u{0}b", "a\u{1}b", "a\u{1B}b", "a\u{7F}b",
        "a\u{85}b", "a\u{90}b", "a\u{2028}b", "a\u{2029}b",
        "a\tb", "-leading", "key: value", "trail # note",
    ]

    // MARK: - The writer

    @Test(arguments: hazards)
    func anEnvValueSurvivesTheWriterAndPyYAML(_ raw: String) throws {
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerEnv(name: "local_tool", env: ["TOKEN": raw]))
        let written = try readConfig(home)

        // The emitted row must not carry the character raw — that is the
        // byte PyYAML's reader refuses.
        let emitted = HermesFileService.yamlScalar(raw)
        #expect(emitted == YAMLScalar.quoteIfNeeded(raw),
                "the MCP writer emits its own spelling again")
        #expect(YAMLScalar.unquote(emitted) == raw, "the pair is not lossless")
        #expect(written.contains("      TOKEN: \(emitted)"))

        guard Self.pyYAMLAvailable else { return }
        let json = try #require(
            Self.entryJSON(written, "local_tool"),
            "PyYAML refused the document — Hermes would discard the whole config.yaml layer"
        )
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let env = try #require(decoded["env"] as? [String: String])
        #expect(env["TOKEN"] == raw, "PyYAML read back a different string")
    }

    @Test(arguments: hazards)
    func aHeaderValueSurvivesTheWriterAndPyYAML(_ raw: String) throws {
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerHeaders(name: "remote_api", headers: ["X-Note": raw]))
        let written = try readConfig(home)
        guard Self.pyYAMLAvailable else { return }
        let json = try #require(Self.entryJSON(written, "remote_api"))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let headers = try #require(decoded["headers"] as? [String: String])
        #expect(headers["X-Note"] == raw)
    }

    /// A KEY carrying the same characters. Keys already went through
    /// `quoteIfNeeded` since P19 — this is the clamp that the two halves of
    /// one emitted row stay on the same rule.
    @Test(arguments: hazards)
    func aHeaderKeySurvivesTheWriterAndPyYAML(_ raw: String) throws {
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerHeaders(name: "remote_api", headers: [raw: "v"]))
        let written = try readConfig(home)
        guard Self.pyYAMLAvailable else { return }
        let json = try #require(Self.entryJSON(written, "remote_api"))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let headers = try #require(decoded["headers"] as? [String: String])
        #expect(headers[raw] == "v")
    }

    /// The tool-filter list writer (`:2256-2259` before P41) and the two
    /// path scalars go through the same routine.
    @Test(arguments: hazards)
    func aToolNameAndACwdSurviveTheWriterAndPyYAML(_ raw: String) throws {
        let (service, home) = try loadFixture()
        #expect(service.updateMCPToolFilters(
            name: "local_tool", include: [raw], exclude: [], resources: true, prompts: true))
        #expect(service.setMCPServerCwd(name: "local_tool", path: "/tmp/\(raw)"))
        let written = try readConfig(home)
        guard Self.pyYAMLAvailable else { return }
        let json = try #require(Self.entryJSON(written, "local_tool"))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let tools = try #require(decoded["tools"] as? [String: Any])
        #expect((tools["include"] as? [String]) == [raw])
        // `cwd` is trimmed by the writer, so compare against the trimmed form.
        #expect(decoded["cwd"] as? String
                == "/tmp/\(raw)".trimmingCharacters(in: .whitespaces))
    }

    /// `setMCPServerCommand` is the one patch that runs UNATTENDED on every
    /// launch and states its expected row — so the expectation has to be
    /// built from the same (now shared) emitter, and the write has to land.
    @Test(arguments: hazards)
    func theCommandWriterAndItsExpectationAgree(_ raw: String) throws {
        let (service, home) = try loadFixture()
        let path = "/Applications/My App/\(raw)/tool"
        #expect(service.setMCPServerCommand(name: "local_tool", command: path))
        let written = try readConfig(home)
        #expect(written.contains("    command: \(YAMLScalar.quoteIfNeeded(path))"))
        guard Self.pyYAMLAvailable else { return }
        let json = try #require(Self.entryJSON(written, "local_tool"))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(decoded["command"] as? String == path)
    }

    // MARK: - What must NOT change

    /// The unification must not churn every config in the world: an
    /// ordinary value still goes out bare.
    @Test func anOrdinaryValueStaysBare() throws {
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerEnv(name: "local_tool", env: ["API_KEY": "abc123"]))
        #expect(try readConfig(home).contains("      API_KEY: abc123"))
    }

    /// `ssl_verify`'s BOOL form must stay a bare `true` / `false` — a quoted
    /// `"true"` is a CA-bundle path named `true` to Hermes, i.e. a silent
    /// downgrade of certificate verification (P10). The carve-out lives at
    /// the call site, so unifying the emitter must not have moved it.
    @Test func sslVerifyBoolStaysBareAndAPathIsQuoted() throws {
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerSSLVerify(name: "remote_api", value: "true"))
        #expect(try readConfig(home).contains("    ssl_verify: true"))
        #expect(service.setMCPServerSSLVerify(name: "remote_api", value: "/etc/ca: bundle.pem"))
        let written = try readConfig(home)
        #expect(written.contains("    ssl_verify: \(YAMLScalar.quoteIfNeeded("/etc/ca: bundle.pem"))"))
        #expect(!written.contains("    ssl_verify: /etc/ca: bundle.pem"))
    }
}
