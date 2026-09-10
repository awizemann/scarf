import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P24 — MCP OAuth state on disk, the `_parse_boolish` type gate, the
/// exact-case transport discriminator, and the remote reap's ERE.
///
/// Each of these is a place where Scarf described a server that does not
/// exist on the host: an OAuth section that never appeared, a "Clear Token"
/// that deleted nothing, a disabled badge on a server the gateway is
/// happily using, and an SSE label on an entry Hermes drives over
/// Streamable HTTP.
@Suite("P24 MCP OAuth, boolish and transport")
struct MCPOAuthAndTransportP24Tests {

    // MARK: - Fixtures

    private func home(config: String) throws -> (HermesFileService, TempHermesHome) {
        let home = try TempHermesHome()
        try config.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            atPath: home.context.paths.mcpTokensDir, withIntermediateDirectories: true)
        return (HermesFileService(context: home.context), home)
    }

    private func touch(_ path: String) throws {
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - OAuth token detection

    /// The reported bug: a server named `github.com` has its token at
    /// `github_com.json` (`_safe_filename`, `tools/mcp_oauth.py:104-106` at
    /// `v2026.9.7`), so a detector keyed on the raw name found nothing —
    /// no "oauth" badge, no token section, no way to clear it.
    @Test func dottedServerNameIsDetectedUnderTheSanitizedFilename() throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          github.com:
            url: https://api.githubcopilot.com/mcp/
            auth: oauth
        """)
        defer { temp.cleanup() }
        try touch(temp.context.paths.mcpTokensDir + "/github_com.json")

        let server = try #require(service.loadMCPServers().first)
        #expect(server.name == "github.com")
        #expect(server.hasOAuthToken, "the token at github_com.json was not found")
    }

    /// A token written by a pre-v0.8.0 Hermes sits under the RAW name.
    /// Both spellings are probed, so an old install still reads correctly
    /// (charter C1).
    @Test func legacyRawFilenameIsStillDetected() throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          github.com:
            url: https://example.com/mcp
            auth: oauth
        """)
        defer { temp.cleanup() }
        try touch(temp.context.paths.mcpTokensDir + "/github.com.json")

        #expect(service.loadMCPServers().first?.hasOAuthToken == true)
    }

    /// No token file at all still reads as "no token" — the probe widened,
    /// it did not become permissive.
    @Test func absentTokenStillReadsAsNoToken() throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          github.com:
            url: https://example.com/mcp
            auth: oauth
        """)
        defer { temp.cleanup() }
        #expect(service.loadMCPServers().first?.hasOAuthToken == false)
    }

    // MARK: - Clear Token

    /// `remove_oauth_tokens` deletes the whole state set
    /// (`tools/mcp_oauth.py:690-693` → `HermesTokenStorage.remove`,
    /// `:391-394`). Deleting only `<name>.json` left the cached DCR
    /// registration, and the next login re-sent a `client_id` the server
    /// had forgotten — the exact state Hermes drops on its own when it can
    /// see the rejection (`tools/mcp_oauth_manager.py:174`).
    @Test func clearTokenRemovesTheWholeStateSet() throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          github.com:
            url: https://example.com/mcp
            auth: oauth
        """)
        defer { temp.cleanup() }
        let dir = temp.context.paths.mcpTokensDir
        let sidecars = [".json", ".client.json", ".meta.json", ".cimd-off"]
        for suffix in sidecars { try touch(dir + "/github_com" + suffix) }
        // An unrelated server's state must survive.
        try touch(dir + "/other.json")

        #expect(service.deleteMCPOAuthToken(name: "github.com"))
        for suffix in sidecars {
            #expect(
                !FileManager.default.fileExists(atPath: dir + "/github_com" + suffix),
                "github_com\(suffix) survived Clear Token"
            )
        }
        #expect(FileManager.default.fileExists(atPath: dir + "/other.json"))
    }

    /// A sidecar an older Hermes never wrote (`.meta.json` is v0.16+,
    /// `.cimd-off` is v0.20.5+) is a no-op, not a failure — both transports'
    /// `removeFile` is `rm -f`-shaped. Clearing a server with only a
    /// tokens file must still report success.
    @Test func clearTokenSucceedsWhenOnlySomeSidecarsExist() throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          plain:
            url: https://example.com/mcp
        """)
        defer { temp.cleanup() }
        try touch(temp.context.paths.mcpTokensDir + "/plain.json")

        #expect(service.deleteMCPOAuthToken(name: "plain"))
        #expect(!FileManager.default.fileExists(atPath: temp.context.paths.mcpTokensDir + "/plain.json"))
    }

    // MARK: - `_parse_boolish` type gate

    /// `_parse_boolish` matches the word sets only for a `str`
    /// (`tools/mcp_tool_common.py:124-137` at `v2026.9.7`). PyYAML types a
    /// bare `0` as an `int`, so Hermes warns and returns the DEFAULT —
    /// `enabled: 0` is an ENABLED server. Scarf showed it as disabled.
    @Test(arguments: ["0", "1", "007", "0x1F", "1.0", "~", "null"])
    func bareNonBoolScalarsFallToTheEnabledDefault(_ scalar: String) throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          srv:
            url: https://example.com/mcp
            enabled: \(scalar)
        """)
        defer { temp.cleanup() }
        #expect(service.loadMCPServers().first?.enabled == true, "enabled: \(scalar)")
    }

    /// The other direction, and the one that reads as a lie in the UI:
    /// `supports_parallel_tool_calls` defaults FALSE, so a bare `1` is OFF
    /// on the host. `nil` here renders as "Default (Hermes decides)".
    @Test(arguments: ["1", "0", "2026-09-09"])
    func bareNonBoolScalarsLeaveParallelToolCallsAtTheDefault(_ scalar: String) throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          srv:
            url: https://example.com/mcp
            supports_parallel_tool_calls: \(scalar)
        """)
        defer { temp.cleanup() }
        #expect(service.loadMCPServers().first?.supportsParallelToolCalls == nil, "= \(scalar)")
    }

    /// QUOTED is the case that flips back: PyYAML loads `"0"` as a `str`,
    /// which `_parse_boolish` DOES match, so the server really is disabled.
    /// This is why the type gate has to run on the raw scalar, before the
    /// unquote.
    @Test(arguments: ["\"0\"", "'0'", "\"no\"", "'off'"])
    func quotedFalseWordsAreStillFalse(_ scalar: String) throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          srv:
            url: https://example.com/mcp
            enabled: \(scalar)
        """)
        defer { temp.cleanup() }
        #expect(service.loadMCPServers().first?.enabled == false, "enabled: \(scalar)")
    }

    /// Real bool spellings are untouched by the gate — PyYAML resolves all
    /// of these to `bool`, which `_parse_boolish` returns as-is.
    @Test(arguments: [("false", false), ("no", false), ("off", false), ("FALSE", false),
                      ("true", true), ("yes", true), ("on", true)])
    func boolWordsStillReadAsBools(_ row: (String, Bool)) throws {
        let (scalar, expected) = row
        let (service, temp) = try home(config: """
        mcp_servers:
          srv:
            url: https://example.com/mcp
            enabled: \(scalar)
        """)
        defer { temp.cleanup() }
        #expect(service.loadMCPServers().first?.enabled == expected, "enabled: \(scalar)")
    }

    /// The same gate governs the `tools:` sub-block, whose Hermes default
    /// is True for both keys.
    @Test func bareIntsUnderToolsFallToTheirDefaults() throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          srv:
            url: https://example.com/mcp
            tools:
              resources: 0
              prompts: 0
        """)
        defer { temp.cleanup() }
        let server = try #require(service.loadMCPServers().first)
        #expect(server.resourcesEnabled)
        #expect(server.promptsEnabled)
    }

    /// `ssl_verify` deliberately keeps its own semantics: it never reaches
    /// `_parse_boolish`, it is forwarded to httpx, and a CA-bundle path is
    /// a legal value. It stays a raw string all the way to the UI.
    @Test func sslVerifyIsUntouchedByTheBoolishGate() throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          srv:
            url: https://example.com/mcp
            ssl_verify: 0
        """)
        defer { temp.cleanup() }
        #expect(service.loadMCPServers().first?.sslVerify == "0")
    }

    // MARK: - Transport discriminator

    /// `if config.get("transport") == "sse"` — exact case, no `.lower()`
    /// anywhere on the path (`tools/mcp_tool_transport.py:412` at
    /// `v2026.9.7`). `transport: SSE` goes down the Streamable-HTTP arm on
    /// the host, so Scarf must not label it SSE.
    @Test(arguments: ["SSE", "Sse", "sSe"])
    func nonLowercaseTransportIsNotSSE(_ spelling: String) throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          srv:
            url: https://example.com/mcp
            transport: \(spelling)
        """)
        defer { temp.cleanup() }
        #expect(service.loadMCPServers().first?.transport == .http, "transport: \(spelling)")
    }

    /// Lowercase — quoted or not, with or without a trailing comment — is
    /// the same `str` to PyYAML and still SSE.
    @Test(arguments: ["sse", "\"sse\"", "'sse'", "sse  # streamed"])
    func lowercaseTransportIsStillSSE(_ spelling: String) throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          srv:
            url: https://example.com/mcp
            transport: \(spelling)
        """)
        defer { temp.cleanup() }
        #expect(service.loadMCPServers().first?.transport == .sse, "transport: \(spelling)")
    }

    /// P29 · `url` is the FIRST discriminator, because Hermes's is.
    /// `_is_http()` is `"url" in self._config`
    /// (`tools/mcp_tool_health.py:27` @ `v2026.9.7`) and `:412`'s
    /// `transport == "sse"` is only reached on the HTTP path; the status
    /// payload agrees — `cfg.get("transport", "http") if "url" in cfg else
    /// "stdio"` (`tools/mcp_tool_discovery.py:484`). So a url-less entry is
    /// stdio whatever its `transport:` key says, and testing `transport` first
    /// made Scarf render a transport the host does not run.
    @Test(arguments: ["sse", "\"sse\"", "'sse'"])
    func aURLlessEntryIsStdioWhateverItsTransportKeySays(_ spelling: String) throws {
        let (service, temp) = try home(config: """
        mcp_servers:
          srv:
            command: uvx
            args: [some-server]
            transport: \(spelling)
        """)
        defer { temp.cleanup() }
        #expect(service.loadMCPServers().first?.transport == .stdio, "transport: \(spelling)")
    }

    /// …and with no `transport:` key at all, a url-bearing entry is still
    /// `.http` and a command-bearing one still `.stdio`. The reorder must not
    /// move the other two arms.
    @Test func theOtherTwoArmsAreUnchanged() throws {
        let (http, t1) = try home(config: """
        mcp_servers:
          srv:
            url: https://example.com/mcp
        """)
        defer { t1.cleanup() }
        #expect(http.loadMCPServers().first?.transport == .http)

        let (stdio, t2) = try home(config: """
        mcp_servers:
          srv:
            command: uvx
            args: [some-server]
        """)
        defer { t2.cleanup() }
        #expect(stdio.loadMCPServers().first?.transport == .stdio)
    }

    // MARK: - Remote reap ERE

    /// Run one POSIX ERE against one subject with the real `grep -E`, so
    /// this tests what `pkill -f` will do rather than what
    /// `NSRegularExpression` would.
    private static func ereMatches(_ pattern: String, _ subject: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        proc.arguments = ["-E", "-q", "--", pattern]
        let input = Pipe()
        proc.standardInput = input
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        input.fileHandleForWriting.write(Data((subject + "\n").utf8))
        input.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    /// What the remote host actually shows for the process Scarf started.
    /// `env` execs the hermes script, so the quotes the shell consumed are
    /// gone from this one.
    private static func execedCmdline(_ server: String) -> String {
        "/usr/bin/python3 /home/u/.local/bin/hermes mcp login --flow device -- \(server)"
    }

    /// …and for the `bash -lc` wrapper, which still carries the literal
    /// double quotes `SSHTransport.remotePathArg` put there
    /// (`SSHTransport.swift:303-322` — it quotes UNCONDITIONALLY).
    private static func wrapperCmdline(_ server: String) -> String {
        "bash -lc HERMES_HOME=\"/home/u/.hermes\" \"env\" \"PYTHONUNBUFFERED=1\" "
            + "\"/home/u/.local/bin/hermes\" \"mcp\" \"login\" \"--\" \"\(server)\""
    }

    @Test(arguments: ["github", "github.com", "my server", "a|b", "x+y", "s(1)"])
    func reapPatternMatchesTheLoginItStarted(_ server: String) {
        let pattern = MCPLoginController.reapPattern(server: server)
        #expect(Self.ereMatches(pattern, Self.execedCmdline(server)), "did not reap \(server)")
    }

    /// The `$` anchor is what keeps the wrapper out: its command line ends
    /// with a literal `"` after the name. If `remotePathArg` ever stops
    /// quoting, this is the test that says so.
    @Test(arguments: ["github", "github.com", "my server"])
    func reapPatternDoesNotMatchTheBashWrapper(_ server: String) {
        let pattern = MCPLoginController.reapPattern(server: server)
        #expect(!Self.ereMatches(pattern, Self.wrapperCmdline(server)))
    }

    /// Every ERE metacharacter in a user-chosen server name is escaped, so
    /// one name cannot widen into another's process.
    @Test func reapPatternDoesNotMatchANeighbouringServer() {
        let pattern = MCPLoginController.reapPattern(server: "a.c")
        #expect(!Self.ereMatches(pattern, Self.execedCmdline("abc")))
        #expect(Self.ereMatches(pattern, Self.execedCmdline("a.c")))
    }

    /// And the anchor rejects a longer name that merely starts with ours.
    @Test func reapPatternIsEndAnchored() {
        let pattern = MCPLoginController.reapPattern(server: "github")
        #expect(!Self.ereMatches(pattern, Self.execedCmdline("github-enterprise")))
    }

    /// Source-scan (the repo's `unguarded-write-seam` convention, used
    /// wherever a seam needs a live remote host to drive): the reap must be
    /// owner-scoped, and must ABANDON rather than widen when it cannot
    /// resolve the uid. `pkill` without `-u` matches every user on the box,
    /// so on a shared host one person closing a login sheet would kill a
    /// colleague's login to the same server. `-u` is an effective-uid
    /// restriction on both platforms Scarf reaches (macOS `pkill(1)` `-u
    /// euid`; Linux procps `-u, --euid`), so one argv is correct on either.
    @Test func remoteReapIsOwnerScopedAndFailsClosed() throws {
        let source = try String(
            contentsOfFile: Self.repoFile(
                "scarf/scarf/Features/MCPServers/ViewModels/MCPLoginController.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "private func reapRemoteLogin(") else {
            Issue.record("reapRemoteLogin not found — did it move?")
            return
        }
        let body = source[start.upperBound...].prefix(2000)
        #expect(
            body.contains(#"args: ["-u", uid, "-f", pattern]"#),
            "the remote reap is no longer owner-scoped"
        )
        // The uid is probed on the remote, not guessed from the SSH config.
        #expect(body.contains(#"executable: "id", args: ["-u"]"#))
        // …and an unresolvable uid abandons the reap instead of running it
        // unscoped.
        guard let probe = body.range(of: #"executable: "id""#),
              let kill = body.range(of: #"executable: "pkill""#) else {
            Issue.record("the reap no longer probes then kills")
            return
        }
        let between = body[probe.upperBound..<kill.lowerBound]
        #expect(between.contains("return"), "no bail-out between the uid probe and the kill")
    }

    private static func repoFile(_ relative: String) -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // scarfTests
        url.deleteLastPathComponent()   // scarf
        url.deleteLastPathComponent()   // repo root
        return url.appendingPathComponent(relative).path
    }
}
