import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P17 — remediation of the cross-phase fresh-eyes review, app-target half.
@Suite("P17 cross-phase remediation (app)")
struct HermesP17AppRemediationTests {

    // MARK: - Finding 1 — `ssl_verify` is bool-OR-path, and the bool half is boolish

    /// `tools/mcp_tool_transport.py:410` (v2026.9.7) passes
    /// `config.get("ssl_verify", True)` straight into httpx's `verify=`.
    /// config.yaml is loaded by PyYAML, so a bare `no` / `off` is already
    /// `False` and `0` is a falsy int by then: all three mean verification
    /// OFF on the host.
    ///
    /// Reading only the literal `"false"` rendered them as "Verify TLS peer"
    /// ON with the word sitting in the CA-path field — and the next save ran
    /// that word through `yamlScalar`, quoting it into a CA bundle literally
    /// named `no`. That is exactly the silent downgrade the writer's
    /// bare-bool rule was added to prevent, arriving through the reader.
    @Test(arguments: ["false", "no", "off", "0", "NO", "Off", "False"])
    func boolishFalsyVerifyValuesTurnTheToggleOff(stored: String) {
        let vm = MCPServerEditorViewModel(server: Self.server(sslVerify: stored))
        #expect(vm.sslVerifyPeer == false, "`ssl_verify: \(stored)` disables verification on the host")
        #expect(vm.sslCAPathDraft == "", "a boolish scalar is not a CA-bundle path")
        // Round-trips to the bare bool the writer is allowed to emit.
        #expect(vm.resolvedSSLVerify == "false")
    }

    /// The truthy half: verification on, and again NOT a CA path.
    @Test(arguments: ["true", "yes", "on", "1", "TRUE", "On"])
    func boolishTruthyVerifyValuesLeaveTheCAPathEmpty(stored: String) {
        let vm = MCPServerEditorViewModel(server: Self.server(sslVerify: stored))
        #expect(vm.sslVerifyPeer == true)
        #expect(vm.sslCAPathDraft == "")
        // Verify-on with no path drops the key — Hermes's own default.
        #expect(vm.resolvedSSLVerify == nil)
    }

    /// Everything that is not boolish is still a CA-bundle path, unchanged.
    /// PyYAML does NOT resolve bare `y` / `n` as bools, so they are paths
    /// here too — same as Hermes sees them.
    @Test(arguments: ["/etc/ssl/corp.pem", "~/certs/ca.pem", "y", "n"])
    func nonBoolishVerifyValuesStayCAPaths(stored: String) {
        let vm = MCPServerEditorViewModel(server: Self.server(sslVerify: stored))
        #expect(vm.sslVerifyPeer == true)
        #expect(vm.sslCAPathDraft == stored)
        #expect(vm.resolvedSSLVerify == stored)
    }

    /// Absent stays absent: Hermes's default is verification on.
    @Test func absentVerifyKeepsTheDefault() {
        let vm = MCPServerEditorViewModel(server: Self.server(sslVerify: nil))
        #expect(vm.sslVerifyPeer == true)
        #expect(vm.sslCAPathDraft == "")
        #expect(vm.resolvedSSLVerify == nil)
    }

    private static func server(sslVerify: String?) -> HermesMCPServer {
        HermesMCPServer(
            name: "docs", transport: .http, command: nil, args: [],
            url: "https://mcp.example.com", auth: nil, env: [:], headers: [:],
            timeout: nil, connectTimeout: nil, enabled: true,
            toolsInclude: [], toolsExclude: [], resourcesEnabled: true,
            promptsEnabled: true, hasOAuthToken: false, sslVerify: sslVerify
        )
    }

    // MARK: - Finding 2 — a superseded gateway load is really cancelled

    /// `load()` cancel-prior only works if the task holding the probes is the
    /// one being cancelled. The previous shape was `Task { … await
    /// Task.detached { … }.value }`: cancelling the OUTER task does not
    /// propagate into a detached child, so both `Task.isCancelled` checks
    /// between the probes were dead code and every superseded load ran all
    /// three CLI invocations against a possibly-remote host anyway.
    ///
    /// The proof is behavioural, not structural: a load whose FIRST probe is
    /// still running when a forced reload supersedes it must never reach its
    /// second probe. With the guards dead this test sees two `pairing`
    /// probes; with cancellation real it sees one.
    @Test @MainActor func supersededGatewayLoadStopsBetweenItsProbes() async {
        let log = ProbeLog()
        let vm = MessagingGatewayViewModel(
            context: Self.scratchContext(),
            capabilities: .empty,
            cliRunner: log.runner()
        )

        // Load A starts and parks inside its `gateway status` probe.
        vm.load(force: true)
        await Self.until(timeout: 10) { log.count(of: "gateway") == 1 }

        // Load B supersedes it. A is cancelled mid-probe; when its probe
        // returns, the `Task.isCancelled` guard must stop it before
        // `pairing list`.
        vm.load(force: true)
        log.release()

        await Self.until(timeout: 10) { vm.isLoading == false }
        // Let any stray continuation land before counting.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(log.count(of: "gateway") == 2, "both loads run their first probe")
        #expect(
            log.count(of: "pairing") == 1,
            """
            the superseded load reached its second probe — cancellation is not \
            real (saw \(log.count(of: "pairing")) pairing probes)
            """
        )
    }

    /// The commit still hops back to the main actor, and the probes still run
    /// off it (charter C10) — detaching the whole body must not have moved
    /// the spawn onto the main actor.
    @Test @MainActor func gatewayProbesStillRunOffTheMainActor() async {
        let log = ProbeLog()
        log.release()   // no gating: just run through
        let vm = MessagingGatewayViewModel(
            context: Self.scratchContext(),
            capabilities: .empty,
            cliRunner: log.runner()
        )
        vm.load(force: true)
        #expect(vm.isLoading == true)
        await Self.until(timeout: 10) { vm.isLoading == false }
        #expect(log.ranOnMainThread == false)
    }

    /// A fake `hermes` whose FIRST invocation blocks until `release()`.
    /// Deterministic: the superseding load is issued while the first probe is
    /// provably still in flight, so the test does not depend on timing.
    final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _ranOnMainThread = false
        private let gate = DispatchSemaphore(value: 0)
        private var released = false

        func count(of verb: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return _calls.filter { $0.first == verb }.count
        }
        var ranOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return _ranOnMainThread }

        func release() {
            lock.lock()
            let already = released
            released = true
            lock.unlock()
            if !already { gate.signal() }
        }

        func runner() -> HermesCLIRunner {
            { [self] args, _ in
                lock.lock()
                _ranOnMainThread = _ranOnMainThread || Thread.isMainThread
                _calls.append(args)
                let isFirst = _calls.count == 1
                lock.unlock()
                if isFirst {
                    // Park the first probe until the test has issued the
                    // superseding load. `.now() + 10` is a deadlock guard,
                    // never the expected path.
                    _ = gate.wait(timeout: .now() + 10)
                    gate.signal()   // let every later caller through
                }
                return ("", 0)
            }
        }
    }

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p17-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
