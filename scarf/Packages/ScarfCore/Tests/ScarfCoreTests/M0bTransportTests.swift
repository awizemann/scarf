import Testing
import Foundation
@testable import ScarfCore

/// Exercises the Transport types + ServerContext that moved in M0b. Same
/// contract as the M0a tests: if any `public init` drifted away from its
/// stored properties, this suite fails fast on Linux CI before a reviewer
/// has to build on a Mac.
@Suite struct M0bTransportTests {

    @Test func sshConfigMemberwiseAndDefaults() {
        // Only `host` is required; all other params default to nil.
        let minimal = SSHConfig(host: "home.local")
        #expect(minimal.host == "home.local")
        #expect(minimal.user == nil)
        #expect(minimal.port == nil)
        #expect(minimal.identityFile == nil)
        #expect(minimal.remoteHome == nil)
        #expect(minimal.hermesBinaryHint == nil)

        let full = SSHConfig(
            host: "h",
            user: "u",
            port: 2222,
            identityFile: "/k",
            remoteHome: "/opt/hermes",
            hermesBinaryHint: "/usr/local/bin/hermes"
        )
        #expect(full.user == "u")
        #expect(full.port == 2222)
        #expect(full.remoteHome == "/opt/hermes")
    }

    @Test func sshConfigCodableRoundTrip() throws {
        let src = SSHConfig(host: "h", user: "u", port: 22, identityFile: nil, remoteHome: nil, hermesBinaryHint: nil)
        let data = try JSONEncoder().encode(src)
        let dec = try JSONDecoder().decode(SSHConfig.self, from: data)
        #expect(dec == src)
    }

    @Test func serverKindCases() {
        let local = ServerKind.local
        let ssh = ServerKind.ssh(SSHConfig(host: "h"))
        #expect(local != ssh)
        if case .local = local { } else { Issue.record("expected .local") }
        if case .ssh(let cfg) = ssh { #expect(cfg.host == "h") } else { Issue.record("expected .ssh") }
    }

    @Test func serverContextLocalIsStable() {
        // The static .local has a hard-coded UUID so window-state restoration
        // across launches resolves. Pin that invariant.
        #expect(ServerContext.local.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(ServerContext.local.displayName == "Local")
        #expect(ServerContext.local.isRemote == false)
    }

    @Test func serverContextPathsLocalVsRemote() {
        let local = ServerContext.local
        #expect(local.paths.isRemote == false)
        // Local home picks up $HOME or NSHomeDirectory(), then appends /.hermes.
        #expect(local.paths.home.hasSuffix("/.hermes"))

        let remote = ServerContext(
            id: UUID(),
            displayName: "remote",
            kind: .ssh(SSHConfig(host: "h", remoteHome: "/opt/hermes"))
        )
        #expect(remote.isRemote == true)
        #expect(remote.paths.home == "/opt/hermes")
        // Default remote home when SSHConfig.remoteHome is nil:
        let remoteDefault = ServerContext(
            id: UUID(),
            displayName: "r2",
            kind: .ssh(SSHConfig(host: "h"))
        )
        #expect(remoteDefault.paths.home == "~/.hermes")
    }

    @Test func serverContextMakeTransportDispatches() {
        let local = ServerContext.local.makeTransport()
        #expect(local is LocalTransport)
        #expect(local.isRemote == false)
        #expect(local.contextID == ServerContext.local.id)

        let remoteCtx = ServerContext(
            id: UUID(),
            displayName: "r",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let remote = remoteCtx.makeTransport()
        #expect(remote is SSHTransport)
        #expect(remote.isRemote == true)
        #expect(remote.contextID == remoteCtx.id)
    }

    @Test func fileStatMemberwise() {
        let s = FileStat(size: 123, mtime: Date(timeIntervalSince1970: 100), isDirectory: false)
        #expect(s.size == 123)
        #expect(s.mtime == Date(timeIntervalSince1970: 100))
        #expect(s.isDirectory == false)
    }

    @Test func processResultMemberwiseAndStringAccessors() {
        let r = ProcessResult(exitCode: 0, stdout: Data("hello\n".utf8), stderr: Data("warn\n".utf8))
        #expect(r.exitCode == 0)
        #expect(r.stdoutString == "hello\n")
        #expect(r.stderrString == "warn\n")

        // Non-UTF8 bytes should still return an (empty) String, never crash.
        let weird = ProcessResult(exitCode: 1, stdout: Data([0xff, 0xfe]), stderr: Data())
        #expect(weird.exitCode == 1)
        #expect(weird.stdoutString == "")
    }

    @Test func watchEventHasOnlyAnyChanged() {
        // We rely on .anyChanged as the single coalesced signal. A future
        // addition of fine-grained cases would break consumers that pattern-
        // match exhaustively; this test guards against that.
        let e = WatchEvent.anyChanged
        switch e {
        case .anyChanged: break
        }
    }

    @Test func localTransportConstructsWithDefaultID() {
        let t = LocalTransport()
        #expect(t.isRemote == false)
        #expect(t.contextID == ServerContext.local.id)

        let explicit = LocalTransport(contextID: UUID())
        #expect(explicit.contextID != ServerContext.local.id)
    }

    @Test func sshTransportStaticPathsAreStable() {
        // controlDirPath() is used by Mac tests (`ControlPathTests`) to check
        // the macOS 104-byte sun_path limit. Pin the format here so the
        // per-uid suffix never drifts away.
        let dir = SSHTransport.controlDirPath()
        #expect(dir.hasPrefix("/tmp/scarf-ssh-"))

        let id = UUID()
        let snapshot = SSHTransport.snapshotDirPath(for: id)
        #expect(snapshot.contains(id.uuidString))
        #expect(snapshot.hasSuffix("/scarf/snapshots/\(id.uuidString)"))

        let root = SSHTransport.snapshotRootPath()
        #expect(root.hasSuffix("/scarf/snapshots"))
    }

    @Test func sshTransportConstructsWithConfig() {
        let cfg = SSHConfig(host: "box.local", user: "alan")
        let t = SSHTransport(contextID: UUID(), config: cfg, displayName: "Home")
        #expect(t.isRemote == true)
        #expect(t.config.host == "box.local")
        #expect(t.displayName == "Home")
    }

    @Test func transportErrorDescriptionsAreUserFacing() {
        #expect(TransportError.hostUnreachable(host: "h", stderr: "").errorDescription?.contains("h") == true)
        #expect(TransportError.authenticationFailed(host: "h", stderr: "").errorDescription?.contains("authentication") == true)
        #expect(TransportError.hostKeyMismatch(host: "h", stderr: "").errorDescription?.contains("Host key") == true)
        #expect(TransportError.commandFailed(exitCode: 7, stderr: "no such file").errorDescription?.contains("7") == true)
        #expect(TransportError.fileIO(path: "/p", underlying: "boom").errorDescription?.contains("/p") == true)
        #expect(TransportError.timeout(seconds: 10, partialStdout: Data()).errorDescription?.contains("10") == true)
        #expect(TransportError.other(message: "x").errorDescription == "x")
    }

    @Test func transportErrorClassifierHandlesKnownStderrPatterns() {
        let auth = TransportError.classifySSHFailure(
            host: "h", exitCode: 255,
            stderr: "Permission denied (publickey).")
        if case .authenticationFailed = auth {} else { Issue.record("expected authFailed") }

        let mismatch = TransportError.classifySSHFailure(
            host: "h", exitCode: 255,
            stderr: "Host key verification failed.")
        if case .hostKeyMismatch = mismatch {} else { Issue.record("expected hostKeyMismatch") }

        let unreach = TransportError.classifySSHFailure(
            host: "h", exitCode: 255,
            stderr: "ssh: connect to host h port 22: Connection refused")
        if case .hostUnreachable = unreach {} else { Issue.record("expected hostUnreachable") }

        let generic = TransportError.classifySSHFailure(
            host: "h", exitCode: 1, stderr: "random failure")
        if case .commandFailed = generic {} else { Issue.record("expected commandFailed") }
    }

    @Test func transportErrorDiagnosticStderr() {
        #expect(TransportError.hostUnreachable(host: "h", stderr: "detail").diagnosticStderr == "detail")
        #expect(TransportError.timeout(seconds: 1, partialStdout: Data()).diagnosticStderr == "")
        #expect(TransportError.other(message: "x").diagnosticStderr == "")
    }

    @Test func serverContextCachesInvalidation() async {
        // Seed the process-wide home-cache for a made-up server, then invalidate.
        // The .local path doesn't hit the cache (isRemote == false), so we use a
        // remote context — its .resolvedUserHome() would do an SSH probe, which
        // we can't run here. We just assert the invalidate API is callable.
        let ctxID = UUID()
        await ServerContext.invalidateCaches(for: ctxID)
    }

    @Test func localTransportFileRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scarftest-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let transport = LocalTransport()
        let content = Data("hello scarf\n".utf8)
        try transport.writeFile(tmp.path, data: content)
        #expect(transport.fileExists(tmp.path))

        let read = try transport.readFile(tmp.path)
        #expect(read == content)

        let stat = transport.stat(tmp.path)
        #expect(stat != nil)
        #expect(stat?.size == Int64(content.count))
        #expect(stat?.isDirectory == false)

        try transport.removeFile(tmp.path)
        #expect(!transport.fileExists(tmp.path))
        // Re-remove is a no-op, not a throw.
        try transport.removeFile(tmp.path)
    }

    @Test func localTransportSnapshotSQLiteReturnsPathUnchanged() throws {
        let transport = LocalTransport()
        let url = try transport.snapshotSQLite(remotePath: "/tmp/some/state.db")
        #expect(url.path == "/tmp/some/state.db")
    }

    /// The Mac target wires `SSHTransport.environmentEnricher` at launch to
    /// `HermesFileService.enrichedEnvironment()` so SSH subprocesses
    /// inherit SSH_AUTH_SOCK from the user's login shell (1Password /
    /// Secretive / `.zshrc`-exported agents). iOS leaves it `nil` (Citadel
    /// owns the agent). Pin the injection-point shape — a regression here
    /// would silently break ssh-agent access for GUI-launched Scarf on
    /// machines where `ssh-add` lives in `.zshrc` rather than `.zprofile`.
    @Test func sshTransportEnvironmentEnricherInjection() {
        let previous = SSHTransport.environmentEnricher
        defer { SSHTransport.environmentEnricher = previous }

        // Default (no enricher) → nothing injected.
        SSHTransport.environmentEnricher = nil

        // With enricher → its keys merged into the returned env.
        SSHTransport.environmentEnricher = {
            ["SSH_AUTH_SOCK": "/tmp/fake.sock", "SSH_AGENT_PID": "4242"]
        }
        // We can't call `sshSubprocessEnvironment()` directly (it's
        // private). Instead assert the injection point exists + can be
        // overridden — exercising the full dispatch path is the
        // integration test's job, not this unit's.
        #expect(SSHTransport.environmentEnricher != nil)
        let sample = SSHTransport.environmentEnricher?()
        #expect(sample?["SSH_AUTH_SOCK"] == "/tmp/fake.sock")
        #expect(sample?["SSH_AGENT_PID"] == "4242")
    }
}
