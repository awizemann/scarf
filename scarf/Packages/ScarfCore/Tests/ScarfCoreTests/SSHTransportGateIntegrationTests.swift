import Testing
import Foundation
@testable import ScarfCore

/// End-to-end check that `SSHTransport` actually feeds the gh#138 circuit
/// breaker: real `/usr/bin/ssh` spawns against a port nothing listens on
/// (connection refused → exit 255), and after three failures the next call
/// must fail fast with `.circuitOpen` — without spawning ssh at all.
#if os(macOS)
@Suite struct SSHTransportGateIntegrationTests {

    @Test func repeatedConnectionFailuresOpenGateAndFailFast() throws {
        // Port 1 on loopback: nothing listens there, dial is refused in
        // milliseconds. Unique host:port key so parallel tests and the
        // app-wide shared gate never collide with a real server.
        let config = SSHConfig(host: "127.0.0.1", user: "nobody", port: 1)
        let transport = SSHTransport(contextID: ServerID(), config: config, displayName: "gate-test")
        let key = SSHConnectionGate.key(host: "127.0.0.1", port: 1)
        SSHConnectionGate.shared.reset(key)
        defer { SSHConnectionGate.shared.reset(key) }

        // Three real attempts, each hitting connection-refused (exit 255).
        for _ in 0..<3 {
            #expect(throws: (any Error).self) {
                _ = try transport.readFile("/nonexistent")
            }
        }
        #expect(SSHConnectionGate.shared.isOpen(key))

        // Fourth call: rejected by the breaker before any process spawn.
        let start = Date()
        do {
            _ = try transport.readFile("/nonexistent")
            Issue.record("expected circuitOpen, got success")
        } catch let error as TransportError {
            guard case .circuitOpen(let host, _) = error else {
                Issue.record("expected circuitOpen, got \(error)")
                return
            }
            #expect(host == "127.0.0.1")
        }
        // Fail-fast means no ssh spawn — generously bounded at 2s (vs the
        // 10s ConnectTimeout a real dial would risk) so parallel-suite CPU
        // load can't flake this.
        #expect(Date().timeIntervalSince(start) < 2.0)
    }
}
#endif
