import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R07 (Hermes v0.21.5 audit): `HermesFileService`'s gateway probes for a
/// named profile — S15-F2 (profile-scoped `pgrep`), S15-F5 (the stop fallback
/// signals only the profile's own gateway) and S07-F2 (a multiplexer-served
/// profile's state comes from the root `gateway_state.json`).
@Suite("R07 — gateway probes scoped to the viewed profile")
struct GatewayProcessScopeR07Tests {

    /// Answers `runProcess` from a closure and `readFile` from a path map.
    final class Transport: ServerTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(exe: String, args: [String])] = []
        private let files: [String: Data]
        private let answer: @Sendable (String, [String]) -> ProcessResult

        var calls: [(exe: String, args: [String])] {
            lock.lock(); defer { lock.unlock() }; return _calls
        }

        init(files: [String: String] = [:],
             answer: @escaping @Sendable (String, [String]) -> ProcessResult) {
            self.files = files.mapValues { Data($0.utf8) }
            self.answer = answer
        }

        let contextID: ServerID = UUID()
        var isRemote: Bool { true }
        func readFile(_ path: String) throws -> Data {
            guard let data = files[path] else {
                throw TransportError.fileIO(path: path, underlying: "No such file or directory")
            }
            return data
        }
        func unguardedWriteFile(_ path: String, data: Data) throws {}
        func fileExists(_ path: String) -> Bool { files[path] != nil }
        func stat(_ path: String) -> FileStat? { nil }
        func statAll(_ paths: [String]) -> [String: FileStat]? { nil }
        func listDirectory(_ path: String) throws -> [String] { [] }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws {}
        func runProcess(
            executable: String, args: [String], stdin: Data?, timeout: TimeInterval
        ) throws -> ProcessResult {
            lock.lock(); _calls.append((executable, args)); lock.unlock()
            return answer(executable, args)
        }
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        func makeProcess(executable: String, args: [String], cwd: String?) -> Process { Process() }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { AsyncStream { $0.finish() } }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            answer("sh", [script])
        }
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private static func context(home: String) -> ServerContext {
        ServerContext(
            id: UUID(), displayName: "Box",
            kind: .ssh(SSHConfig(host: "box.local", remoteHome: home,
                                 hermesBinaryHint: "/usr/local/bin/hermes"))
        )
    }

    private static func result(_ stdout: String, _ exit: Int32) -> ProcessResult {
        ProcessResult(exitCode: exit, stdout: Data(stdout.utf8), stderr: Data())
    }

    static let root = "/home/u/.hermes"
    static let workHome = "/home/u/.hermes/profiles/work"
    static let servedRoot = #"""
    {"pid": 4242, "gateway_state": "running", "updated_at": "2026-09-27T01:50:28+00:00",
     "served_profiles": ["default", "work"],
     "platforms": {"telegram": {"state": "connected"},
                   "work:telegram": {"state": "connected", "error_code": null, "error_message": null},
                   "work:discord": {"state": "fatal", "error_code": "auth_failed",
                                    "error_message": "Improper token has been passed."}}}
    """#

    private static func isDefaultPattern(_ args: [String]) -> Bool {
        args.last == HermesGatewayProcessMatch.pgrepPattern(profile: nil)
    }
    private static func isWorkPattern(_ args: [String]) -> Bool {
        args.last == HermesGatewayProcessMatch.pgrepPattern(profile: "work")
    }

    @Test func aNamedProfileProbesWithItsOwnPattern() {
        let transport = Transport { exe, args in
            Self.isWorkPattern(args) ? Self.result("777\n", 0) : Self.result("", 1)
        }
        let svc = HermesFileService(context: Self.context(home: Self.workHome), transport: transport)
        guard case .success(let pid) = svc.hermesPIDResult() else {
            Issue.record("probe failed"); return
        }
        #expect(pid == 777)
        #expect(transport.calls.count == 1)
    }

    /// Served by the default multiplexer, no gateway of its own: the display
    /// probe reports the multiplexer's process.
    @Test func aServedProfileReportsTheMultiplexerPID() {
        let transport = Transport(files: [Self.root + "/gateway_state.json": Self.servedRoot]) { _, args in
            Self.isDefaultPattern(args) ? Self.result("4242\n", 0) : Self.result("", 1)
        }
        let svc = HermesFileService(context: Self.context(home: Self.workHome), transport: transport)
        guard case .success(let pid) = svc.hermesPIDResult() else {
            Issue.record("probe failed"); return
        }
        #expect(pid == 4242)
    }

    /// Not served, and no gateway of its own: stopped — even though the
    /// default profile's gateway is up (the old unscoped pattern said running).
    @Test func anUnservedProfileIsNotRunningBecauseTheDefaultIs() {
        let transport = Transport { _, args in
            Self.isDefaultPattern(args) ? Self.result("4242\n", 0) : Self.result("", 1)
        }
        let svc = HermesFileService(context: Self.context(home: Self.workHome), transport: transport)
        guard case .success(let pid) = svc.hermesPIDResult() else {
            Issue.record("probe failed"); return
        }
        #expect(pid == nil)
    }

    /// The stop fallback must never SIGTERM the multiplexer on behalf of a
    /// profile it serves — that would take every other profile down with it.
    @Test func theStopFallbackNeverSignalsTheMultiplexer() {
        let transport = Transport(files: [Self.root + "/gateway_state.json": Self.servedRoot]) { exe, args in
            if exe.hasSuffix("hermes") {
                return Self.result("✗ Refusing to stop the gateway from inside the gateway process.", 1)
            }
            if exe.contains("pgrep") {
                return Self.isDefaultPattern(args) ? Self.result("4242\n", 0) : Self.result("", 1)
            }
            return Self.result("", 0)
        }
        let svc = HermesFileService(context: Self.context(home: Self.workHome), transport: transport)
        let outcome = svc.stopHermes()
        #expect(!outcome.succeeded)
        // Premise: the refusal DID reach the fallback, which probed for the
        // profile's own gateway only.
        #expect(transport.calls.contains { $0.exe.contains("pgrep") && Self.isWorkPattern($0.args) })
        #expect(!transport.calls.contains { $0.exe.contains("pgrep") && Self.isDefaultPattern($0.args) })
        #expect(!transport.calls.contains { $0.exe.contains("kill") }, "SIGTERM went to the multiplexer")
    }

    // MARK: - `gateway.pid` fallback

    static let workPidFile = #"{"pid": 888, "kind": "hermes-gateway", "argv": ["python", "-m", "hermes_cli.main", "gateway", "run"], "start_time": 1, "hermes_home": "/home/u/.hermes/profiles/work"}"#

    /// A gateway started with `HERMES_HOME` in its environment has no `-p`
    /// on its command line; the profile's own `gateway.pid` finds it once
    /// `ps` confirms the process is that gateway.
    @Test func anEnvOnlyGatewayIsFoundThroughItsPidFile() {
        let transport = Transport(files: [Self.workHome + "/gateway.pid": Self.workPidFile]) { exe, args in
            if exe.contains("pgrep") { return Self.result("", 1) }
            if exe.hasSuffix("/ps") {
                #expect(args == ["-p", "888", "-o", "command="])
                return Self.result("/home/u/.hermes/venv/bin/python -m hermes_cli.main gateway run --replace\n", 0)
            }
            return Self.result("", 1)
        }
        let svc = HermesFileService(context: Self.context(home: Self.workHome), transport: transport)
        guard case .success(let pid) = svc.hermesPIDResult() else { Issue.record("probe failed"); return }
        #expect(pid == 888)
    }

    /// A stale file: the PID is dead, or now belongs to something else.
    @Test func aStalePidFileIsRefused() {
        for ps in [Self.result("", 1), Self.result("/usr/bin/vim notes.txt\n", 0),
                   Self.result("/home/u/.local/bin/hermes -p ops gateway run\n", 0)] {
            let transport = Transport(files: [Self.workHome + "/gateway.pid": Self.workPidFile]) { exe, _ in
                exe.hasSuffix("/ps") ? ps : Self.result("", 1)
            }
            let svc = HermesFileService(context: Self.context(home: Self.workHome), transport: transport)
            guard case .success(let pid) = svc.hermesPIDResult() else { Issue.record("probe failed"); return }
            #expect(pid == nil)
            #expect(transport.calls.contains { $0.exe.hasSuffix("/ps") }, "the fallback never ran")
        }
    }

    /// Hermes's PID-reuse guard: on a `/proc` host the record's `start_time`
    /// must equal the live process's stat field 22.
    @Test func aReusedPidIsRefusedByStartTime() {
        func stat(_ start: Int) -> String {
            "888 (python) S " + (4...21).map(String.init).joined(separator: " ") + " \(start) 23\n"
        }
        for (live, expected) in [(1, Int32?(888)), (2, nil)] {
            let transport = Transport(files: [Self.workHome + "/gateway.pid": Self.workPidFile,
                                              "/proc/888/stat": stat(live)]) { exe, _ in
                exe.hasSuffix("/ps") ? Self.result("python -m hermes_cli.main gateway run\n", 0) : Self.result("", 1)
            }
            let svc = HermesFileService(context: Self.context(home: Self.workHome), transport: transport)
            guard case .success(let pid) = svc.hermesPIDResult() else { Issue.record("probe failed"); return }
            #expect(pid == expected, "start_time \(live) vs recorded 1")
        }
    }

    /// The default profile never takes the pid-file fallback.
    @Test func theDefaultProfileDoesNotReadGatewayPid() {
        let transport = Transport(files: [Self.root + "/gateway.pid": #"{"pid": 777}"#]) { exe, _ in
            exe.hasSuffix("/ps") ? Self.result("python -m hermes_cli.main gateway run\n", 0) : Self.result("", 1)
        }
        let svc = HermesFileService(context: Self.context(home: Self.root), transport: transport)
        guard case .success(let pid) = svc.hermesPIDResult() else { Issue.record("probe failed"); return }
        #expect(pid == nil)
        #expect(!transport.calls.contains { $0.exe.hasSuffix("/ps") })
    }

    /// The pid-file answer is the profile's OWN gateway, so the stop fallback
    /// may signal it.
    @Test func theStopFallbackSignalsAPidFileGateway() {
        let transport = Transport(files: [Self.workHome + "/gateway.pid": Self.workPidFile]) { exe, args in
            if exe.hasSuffix("hermes") {
                return Self.result("✗ Refusing to stop the gateway from inside the gateway process.", 1)
            }
            if exe.contains("pgrep") { return Self.result("", 1) }
            if exe.hasSuffix("/ps") { return Self.result("python -m hermes_cli.main gateway run\n", 0) }
            return Self.result("", 0)
        }
        let svc = HermesFileService(context: Self.context(home: Self.workHome), transport: transport)
        #expect(svc.stopHermes().succeeded)
        let kill = transport.calls.first { $0.exe.contains("kill") }
        #expect(kill?.args == ["-TERM", "888"])
    }

    // MARK: - Webhooks "Set Port & Secret in Terminal"

    @Test func theGatewaySetupCommandTargetsARemoteWindowsHostAndProfile() {
        let ctx = ServerContext(
            id: UUID(), displayName: "Box",
            kind: .ssh(SSHConfig(host: "box.local", user: "deploy", port: 2222,
                                 remoteHome: "~/.hermes/profiles/work",
                                 hermesBinaryHint: "/home/deploy/.local/bin/hermes")))
        let argv = GatewaySetupTerminalCommand.argv(for: ctx)
        #expect(Array(argv.prefix(4)) == ["/usr/bin/ssh", "-t", "-p", "2222"])
        #expect(argv.contains("deploy@box.local"))
        #expect(argv.contains { $0.hasPrefix("HERMES_HOME=") && $0.contains("profiles/work") })
        #expect(Array(argv.suffix(3)) == ["/home/deploy/.local/bin/hermes", "gateway", "setup"])
        // Quoted for the LOCAL shell so `$PATH`/`$HOME` expand remotely.
        #expect(GatewaySetupTerminalCommand.shellLine(for: ctx).contains(#"'PATH="$PATH:"#))
    }

    @Test func theGatewaySetupCommandPinsALocalRootWindow() {
        let home = NSTemporaryDirectory() + "scarf-r07-root-\(UUID().uuidString)"
        let argv = GatewaySetupTerminalCommand.argv(for: .local(home: URL(fileURLWithPath: home)))
        #expect(Array(argv.suffix(4)) == ["-p", "default", "gateway", "setup"])
        #expect(!argv.contains("/usr/bin/ssh"))
        #expect(GatewaySetupTerminalCommand.singleQuote("it's") == #"'it'\''s'"#)
    }

    /// S07-F2: the served profile's platforms are the root record's
    /// `work:` entries, re-keyed — and the default profile's own telegram
    /// entry is not among them.
    @Test func aServedProfileReadsItsPlatformsFromTheRootRecord() throws {
        let transport = Transport(files: [Self.root + "/gateway_state.json": Self.servedRoot]) { _, _ in
            Self.result("", 1)
        }
        let svc = HermesFileService(context: Self.context(home: Self.workHome), transport: transport)
        let state = try #require(svc.loadGatewayState())
        #expect(state.isRunning)
        #expect(Set(state.platforms.map { Array($0.keys) } ?? []) == ["telegram", "discord"])
        #expect(state.platforms?["discord"]?.errorText == "Improper token has been passed.")

        guard case .success(let viaResult?) = svc.loadGatewayStateResult() else {
            Issue.record("result variant lost the projection"); return
        }
        #expect(viaResult.platforms?["telegram"]?.isConnected == true)
    }

    /// The default profile reads its own (root) file, prefixed keys and all,
    /// exactly as before.
    @Test func theDefaultProfileKeepsItsOwnFile() throws {
        let transport = Transport(files: [Self.root + "/gateway_state.json": Self.servedRoot]) { _, _ in
            Self.result("", 1)
        }
        let svc = HermesFileService(context: Self.context(home: Self.root), transport: transport)
        let state = try #require(svc.loadGatewayState())
        #expect(state.platforms?["work:discord"] != nil)
        #expect(state.platforms?["telegram"]?.isConnected == true)
    }
}
