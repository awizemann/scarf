import Testing
import Foundation
@testable import ScarfCore

/// R18c (Hermes v0.21.5 audit, R15 touched-surface findings).
///
/// - T6-F1: a custom remote ROOT home now carries `HERMES_HOME=<root>` next
///   to `-p default`, so Hermes resolves the root the window reads instead
///   of the SSH user's `~/.hermes`. Run through the real shells.
/// - T6-F3: a remote command's own "Permission denied" is not an SSH
///   authentication failure.
/// - T3-F3: the Nous `/models` key is the one Hermes sends, an expired one
///   is not sent, and `inference_base_url` is honoured.
/// - T4-F1: the MCP catalog roster per host, and the install answers fed to
///   `hermes mcp install` on stdin.
@Suite struct AuditFollowupsR18cTests {

    // MARK: - Helpers

    /// A throwaway `$HOME` holding an executable fake `hermes` in
    /// `~/.local/bin` that prints its `HERMES_HOME` and argv.
    private static func homeWithHermes() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-r18c-\(UUID().uuidString)")
        let hermes = home.appendingPathComponent(".local/bin/hermes")
        try FileManager.default.createDirectory(
            at: hermes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"HOME_PIN=${HERMES_HOME:-none} ARGS=$*\"\n"
            .write(to: hermes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hermes.path)
        return home
    }

    /// `<shell> -c <command>`, the way sshd runs a remote command with the
    /// user's login shell program, with no rc files and a bare PATH.
    private static func run(_ shell: String, _ command: String, home: URL) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-c", command]
        proc.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell]
        proc.currentDirectoryURL = home
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func singleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The login shells on this Mac (fish runs too when installed).
    static let shells: [String] = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh",
                                   "/bin/csh", "/bin/tcsh",
                                   "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }

    private static func remote(_ remoteHome: String?) -> ServerContext {
        ServerContext(id: UUID(), displayName: "box", kind: .ssh(SSHConfig(
            host: "box", remoteHome: remoteHome)))
    }

    // MARK: - T6-F1: custom root home

    /// The SSH one-shot path: ssh hands `sh -c '<command>'` to the login
    /// shell. For a custom root the fake hermes sees `HERMES_HOME=<root>`
    /// AND `-p default`; for `~/.hermes` it sees only the pin, as before.
    @Test(arguments: shells)
    func theRemoteOneShotCarriesACustomRootInEveryShell(shell: String) throws {
        let home = try Self.homeWithHermes()
        defer { try? FileManager.default.removeItem(at: home) }

        for (configured, expectedPin) in [
            ("/srv/hermes data/.hermes", "/srv/hermes data/.hermes"),
            ("~/hermes-root", "\(home.path)/hermes-root"),
            ("~/.hermes", "none"),
        ] {
            let transport = SSHTransport(
                contextID: UUID(), config: SSHConfig(host: "box", remoteHome: configured), displayName: "box")
            let cmd = transport.remoteShellCommand(executable: "hermes", args: ["config", "path"])
            let (code, out) = try Self.run(shell, "sh -c " + Self.singleQuote(cmd), home: home)
            #expect(code == 0, "\(shell) \(configured): \(out)")
            #expect(out == "HOME_PIN=\(expectedPin) ARGS=-p default config path", "\(shell) \(configured)")
        }
    }

    /// The Terminal launch (no `sh -c` in between: the login shell parses
    /// the words itself, csh included).
    @Test(arguments: shells)
    func theTerminalLaunchCarriesACustomRootInEveryShell(shell: String) throws {
        let home = try Self.homeWithHermes()
        defer { try? FileManager.default.removeItem(at: home) }
        let words = try #require(Self.remote("/opt/data").remoteLoginShellHermesWords(args: ["gateway", "setup"]))
        #expect(try Self.run(shell, words.joined(separator: " "), home: home)
            == (0, "HOME_PIN=/opt/data ARGS=-p default gateway setup"), "\(shell)")
    }

    /// A named profile under a custom root keeps its own assignment and
    /// no pin; the root pin rule is unchanged.
    @Test func aNamedProfileUnderACustomRootIsUnchanged() {
        #expect(HermesProfileScope.hermesHomeShellAssignment(forHome: "/opt/data/profiles/work")
            == "HERMES_HOME='/opt/data/profiles/work' ")
        #expect(HermesProfileScope.pinnedRemoteArguments(
            executable: "hermes", args: ["acp"], home: "/opt/data/profiles/work") == ["acp"])
        #expect(!HermesProfileScope.needsHomeAssignment("~/.hermes"))
        #expect(HermesProfileScope.needsHomeAssignment("/root/.hermes"))
    }

    // MARK: - T6-F3: SSH failure classification

    @Test func aRemoteFilePermissionErrorIsACommandFailure() {
        let err = TransportError.classifySSHFailure(
            host: "h", exitCode: 1, stderr: "cat: /home/hermes/.hermes/auth.json: Permission denied")
        guard case .commandFailed(let code, let stderr) = err else {
            Issue.record("expected commandFailed, got \(err)")
            return
        }
        #expect(code == 1)
        #expect(stderr.contains("auth.json"))
        #expect(err.errorDescription?.contains("SSH authentication") == false)

        let mv = TransportError.classifySSHFailure(
            host: "h", exitCode: 1, stderr: "mv: cannot move 'a' to 'b': Permission denied")
        if case .commandFailed = mv {} else { Issue.record("mv: expected commandFailed, got \(mv)") }
    }

    @Test func realSSHFailuresStillClassify() {
        func kind(_ exit: Int32, _ stderr: String) -> String {
            TransportError.classifySSHFailure(host: "h", exitCode: exit, stderr: stderr).analyticsErrorKind
        }
        #expect(kind(255, "user@h: Permission denied (publickey,password).") == "auth_failed")
        #expect(kind(255, "Permission denied, please try again.") == "auth_failed")
        #expect(kind(255, "Received disconnect: Authentication failed.") == "auth_failed")
        // ssh-only phrases count at any exit: legacy `scp -O` exits 1.
        #expect(kind(1, "user@h: Permission denied (publickey).\nlost connection") == "auth_failed")
        #expect(kind(1, "ssh: connect to host h port 22: Connection refused\nlost connection") == "host_unreachable")
        #expect(kind(1, "Host key verification failed.") == "host_key_mismatch")
        // A remote tool's own network error is not ssh's.
        #expect(kind(7, "curl: (7) Failed to connect to localhost port 8080: Connection refused") == "command_failed")
        #expect(kind(255, "ssh: Could not resolve hostname h: nodename nor servname provided") == "host_unreachable")
        // Rust tools (uv, rg) print their own parenthesised form.
        #expect(kind(2, "error: failed to open file: Permission denied (os error 13)") == "command_failed")
        #expect(kind(1, "Connection closed by 10.0.0.2 port 22\nlost connection") == "host_unreachable")
    }

    // MARK: - T3-F3: Nous /models bearer

    private static func jwt(exp: TimeInterval) -> String {
        func b64(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return b64(#"{"alg":"none"}"#) + "." + b64("{\"exp\":\(Int(exp)),\"scope\":\"inference:invoke\"}") + ".sig"
    }

    private static func auth(_ nous: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["providers": ["nous": nous], "active_provider": "nous"])
    }

    @Test func theAgentKeyIsPreferredAndTheDefaultURLUsed() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try Self.auth([
            "access_token": "portal-token", "agent_key": "opaque-agent-key",
            "agent_key_expires_at": "2027-01-15T09:00:00+00:00",
        ])
        #expect(NousModelCatalogService.bearerLookup(authJSON: data, now: now)
            == .usable(token: "opaque-agent-key", url: NousModelCatalogService.baseURL))
    }

    @Test func anExpiredKeyIsNotSent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Recorded expiry, microseconds and `+00:00` as Python writes them.
        let recorded = try Self.auth([
            "access_token": "tok", "agent_key": "tok",
            "agent_key_expires_at": "2027-01-15T07:59:30.123456+00:00",
        ])
        #expect(NousModelCatalogService.bearerLookup(authJSON: recorded, now: now) == .expired)
        // No recorded expiry: the JWT's own `exp`.
        let token = Self.jwt(exp: now.timeIntervalSince1970 - 10)
        let fromJWT = try Self.auth(["access_token": token])
        #expect(NousModelCatalogService.bearerLookup(authJSON: fromJWT, now: now) == .expired)
        // Inside the skew counts as expired too.
        let closeCall = try Self.auth(["access_token": Self.jwt(exp: now.timeIntervalSince1970 + 30)])
        #expect(NousModelCatalogService.bearerLookup(authJSON: closeCall, now: now) == .expired)
    }

    @Test func aLiveOrUnknownExpiryIsSent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let live = Self.jwt(exp: now.timeIntervalSince1970 + 3600)
        #expect(NousModelCatalogService.bearerLookup(authJSON: try Self.auth(["access_token": live]), now: now)
            == .usable(token: live, url: NousModelCatalogService.baseURL))
        // An opaque token with no expiry is sent, as before.
        #expect(NousModelCatalogService.bearerLookup(authJSON: try Self.auth(["access_token": "opaque"]), now: now)
            == .usable(token: "opaque", url: NousModelCatalogService.baseURL))
        // A recorded expiry in the future (`Z` form) is sent.
        #expect(NousModelCatalogService.bearerLookup(authJSON: try Self.auth([
            "access_token": "opaque", "expires_at": "2027-01-15T09:00:00Z"]), now: now)
            == .usable(token: "opaque", url: NousModelCatalogService.baseURL))
    }

    @Test func theStoredInferenceBaseURLIsHonouredWhenHTTPS() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staging = try Self.auth(["access_token": "t", "inference_base_url": "https://staging.example/v1/"])
        #expect(NousModelCatalogService.bearerLookup(authJSON: staging, now: now)
            == .usable(token: "t", url: URL(string: "https://staging.example/v1/models")!))
        // A plain-http base never gets the token.
        let plain = try Self.auth(["access_token": "t", "inference_base_url": "http://evil.example/v1"])
        #expect(NousModelCatalogService.bearerLookup(authJSON: plain, now: now)
            == .usable(token: "t", url: NousModelCatalogService.baseURL))
    }

    @Test func noNousRecordIsMissing() throws {
        #expect(NousModelCatalogService.bearerLookup(authJSON: Data("{}".utf8)) == .missing)
        #expect(NousModelCatalogService.bearerLookup(authJSON: try Self.auth(["access_token": " "])) == .missing)
        #expect(NousModelCatalogService.bearerLookup(authJSON: Data("not json".utf8)) == .missing)
        #expect(NousModelCatalogError.tokenExpired.userMessage.contains("Hermes renews it"))
        #expect(!NousModelCatalogError.http(status: 401).userMessage.hasSuffix("Sign in again."))
    }

    // MARK: - T4-F1: MCP catalog

    @Test func eachHostGetsTheRosterItsCatalogKnows() {
        let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
        let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        let current = OptionalMCPCatalog.entries(for: v0214)
        let older = OptionalMCPCatalog.entries(for: v0213)
        #expect(current.count == 65 && older.count == 65)
        #expect(current.contains { $0.name == "n8n-official" })
        #expect(!current.contains { $0.name == "n8n" })
        #expect(current.first { $0.name == "asana" }?.url == "https://mcp.asana.com/v2/mcp")
        #expect(older.contains { $0.name == "n8n" })
        #expect(!older.contains { $0.name == "n8n-official" })
        #expect(older.first { $0.name == "asana" }?.url == "https://mcp.asana.com/sse")
        #expect(older.allSatisfy { $0.installPrompts.isEmpty })
        // Everything else is the same entry in the same place.
        #expect(zip(current, older).filter { $0.0 != $0.1 }.map(\.0.name) == ["asana", "n8n-official"])
        #expect(OptionalMCPCatalog.entries(for: .empty) == older)
    }

    @Test func installAnswersBecomeOneStdinLineEach() throws {
        let asana = try #require(OptionalMCPCatalog.entries.first { $0.name == "asana" })
        #expect(asana.installPrompts.map(\.name) == ["ASANA_CLIENT_ID", "ASANA_CLIENT_SECRET"])
        #expect(asana.installPrompts.map(\.isSecret) == [false, true])
        // The plain value is required; a secret may be left for Hermes to
        // reuse from .env (or to refuse with its own message).
        #expect(!asana.installValuesComplete(["ASANA_CLIENT_SECRET": "s"]))
        #expect(!asana.installValuesComplete(["ASANA_CLIENT_ID": "  ", "ASANA_CLIENT_SECRET": "s"]))
        #expect(asana.installValuesComplete(["ASANA_CLIENT_ID": "id"]))
        let values = ["ASANA_CLIENT_ID": "  id-123 ", "ASANA_CLIENT_SECRET": "s3cret\nextra line"]
        #expect(asana.installValuesComplete(values))
        // Trimmed, and a pasted newline cannot push text into the next prompt.
        #expect(asana.installStdin(values: values) == "id-123\ns3cret\n")

        let n8n = try #require(OptionalMCPCatalog.entries.first { $0.name == "n8n-official" })
        #expect(n8n.url == nil)
        #expect(n8n.installStdin(values: ["N8N_MCP_SERVER_URL": "https://n8n.example/mcp-server/http"])
            == "https://n8n.example/mcp-server/http\n")

        let linear = try #require(OptionalMCPCatalog.entries.first { $0.name == "linear" })
        #expect(linear.installStdin(values: [:]) == nil)
        #expect(linear.installValuesComplete([:]))
    }

    /// Hermes skips a secret it already has and says so; the typed value is
    /// dropped while the install succeeds, so Scarf says so too. Output
    /// line as `_prompt_env_vars` prints it (`mcp_catalog.py:486`).
    @Test func aSecretHermesAlreadyHadIsReported() throws {
        let asana = try #require(OptionalMCPCatalog.entries.first { $0.name == "asana" })
        let typed = try #require(asana.installRequest(values: ["ASANA_CLIENT_ID": "id", "ASANA_CLIENT_SECRET": "new"]))
        #expect(typed.suppliedSecrets == ["ASANA_CLIENT_SECRET"])
        let output = "  Configure credentials:\n  ✓ ASANA_CLIENT_SECRET already set in .env\n  ✓ Installed 'asana' (enabled)."
        let note = try #require(typed.reusedSecretNote(in: output))
        #expect(note.hasPrefix("Note: ASANA_CLIENT_SECRET was already set"))
        #expect(typed.reusedSecretNote(in: "  ✓ Installed 'asana' (enabled).") == nil)
        // Nothing typed, nothing to report.
        let blank = try #require(asana.installRequest(values: ["ASANA_CLIENT_ID": "id"]))
        #expect(blank.suppliedSecrets.isEmpty)
        #expect(blank.reusedSecretNote(in: output) == nil)
    }

    @Test func theFetchPresetRunsThePythonPackage() throws {
        let fetch = try #require(MCPServerPreset.gallery.first { $0.id == "fetch" })
        #expect(fetch.command == "uvx")
        #expect(fetch.args == ["mcp-server-fetch"])
    }
}
