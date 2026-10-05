#if canImport(Citadel) && os(macOS)

import Testing
import Foundation
import ScarfCore
@testable import ScarfIOS

// LIVE integration test — drives host-key pinning through REAL Citadel
// connections against a real sshd: the pooled transport, the ACP chat
// channel and onboarding's Test Connection. First connect pins; the sshd then
// restarts with a different host key and every funnel must refuse with
// `HostKeyMismatchError`; after a re-trust the transport connects again.
//
// Skipped unless SCARF_LIVE_HK_PORT is set. Run it via
// scripts/verify-ios-host-key-pinning.sh (ephemeral localhost sshd, no sudo).
// Env: SCARF_LIVE_HK_PORT, SCARF_LIVE_HK_USER, SCARF_LIVE_HK_AUTHORIZED_KEYS,
// SCARF_LIVE_HK_FP_A / _FP_B (ssh-keygen -lf fingerprints of the two host
// keys), SCARF_LIVE_HK_SWAP (shell command that restarts sshd on key B).

private struct HostKeyLiveEnv {
    let port: Int
    let user: String
    let authorizedKeys: String
    let fingerprintA: String
    let fingerprintB: String
    let swapCommand: String

    static func load() -> HostKeyLiveEnv? {
        let e = ProcessInfo.processInfo.environment
        guard let port = e["SCARF_LIVE_HK_PORT"].flatMap(Int.init),
              let user = e["SCARF_LIVE_HK_USER"],
              let ak = e["SCARF_LIVE_HK_AUTHORIZED_KEYS"],
              let a = e["SCARF_LIVE_HK_FP_A"],
              let b = e["SCARF_LIVE_HK_FP_B"],
              let swap = e["SCARF_LIVE_HK_SWAP"] else { return nil }
        return HostKeyLiveEnv(port: port, user: user, authorizedKeys: ak,
                              fingerprintA: a, fingerprintB: b, swapCommand: swap)
    }
}

@Suite(.serialized, .enabled(if: HostKeyLiveEnv.load() != nil))
struct HostKeyPinningLiveTests {

    @Test func pinsOnFirstConnectThenRefusesASwappedHostKey() async throws {
        let env = try #require(HostKeyLiveEnv.load())
        // In-memory pins: isolated from the app's, and no UserDefaults
        // suite plist left behind.
        let store = HostKeyPinStore(backing: InMemoryHostKeyPinBacking())

        // Authorize a fresh device key, the app's own way.
        let bundle = try Ed25519KeyGenerator.generate(comment: "scarf-hostkey-verify")
        let akURL = URL(fileURLWithPath: env.authorizedKeys)
        let existing = (try? String(contentsOf: akURL, encoding: .utf8)) ?? ""
        try (existing + bundle.publicKeyOpenSSH + "\n").write(to: akURL, atomically: true, encoding: .utf8)

        let config = SSHConfig(host: "127.0.0.1", user: env.user, port: env.port)
        let endpoint = HostKeyEndpoint(host: "127.0.0.1", port: env.port)
        func transport() -> CitadelServerTransport {
            CitadelServerTransport(contextID: ServerID(), config: config, displayName: "live",
                                   hostKeyStore: store, keyProvider: { bundle })
        }

        // 1. First connect: silent, and the key is pinned.
        #expect(store.record(for: endpoint) == nil)
        let first = try transport().runProcess(executable: "/bin/echo", args: ["pinned"], stdin: nil, timeout: 20)
        #expect(first.exitCode == 0)
        let pinned = try #require(store.record(for: endpoint))
        #expect(pinned.pinned.fingerprint == env.fingerprintA)
        print("[live] first connect pinned \(pinned.pinned.fingerprint)")

        // 2. Same key again: accepted.
        #expect(try transport().runProcess(executable: "/bin/echo", args: ["again"], stdin: nil, timeout: 20).exitCode == 0)

        // 3. sshd comes back with a different host key.
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", env.swapCommand]
        try swap.run()
        swap.waitUntilExit()
        #expect(swap.terminationStatus == 0)

        let expected = HostKeyMismatchError(
            endpoint: endpoint, expectedFingerprint: env.fingerprintA, presentedFingerprint: env.fingerprintB)

        // Transport funnel.
        do {
            _ = try transport().runProcess(executable: "/bin/echo", args: ["mitm"], stdin: nil, timeout: 20)
            Issue.record("transport connected to a host with a changed key")
        } catch {
            #expect(error as? HostKeyMismatchError == expected, "transport threw \(error)")
            print("[live] transport refused: \(error.localizedDescription)")
        }

        // ACP chat funnel.
        let ctx = ServerContext(id: ServerID(), displayName: "live", kind: .ssh(config))
        let acp = ACPClient.forIOSApp(context: ctx, hostKeyStore: store, keyProvider: { bundle })
        do {
            try await acp.start()
            Issue.record("ACP connected to a host with a changed key")
            await acp.stop()
        } catch {
            #expect(error as? HostKeyMismatchError == expected, "ACP threw \(error)")
            print("[live] ACP refused: \(error.localizedDescription)")
        }

        // Onboarding Test Connection funnel.
        let service = CitadelSSHService(hostKeyStore: store)
        let iosConfig = IOSServerConfig(host: "127.0.0.1", user: env.user, port: env.port, displayName: "live")
        do {
            try await service.testConnection(config: iosConfig, key: bundle)
            Issue.record("Test Connection passed against a changed key")
        } catch let SSHConnectionTestError.hostKeyMismatch(host, detail) {
            #expect(host == "127.0.0.1:\(env.port)")
            #expect(detail.contains("different host key"))
            print("[live] Test Connection refused: \(detail)")
        }

        // The refused key is waiting for a decision; the pin is unchanged.
        let record = try #require(store.record(for: endpoint))
        #expect(record.pinned.fingerprint == env.fingerprintA)
        #expect(record.rejected?.fingerprint == env.fingerprintB)

        // 4. The user re-trusts: the new key is pinned and connects.
        #expect(store.trustRejectedKey(for: endpoint, expectedFingerprint: env.fingerprintB))
        let after = try transport().runProcess(executable: "/bin/echo", args: ["retrusted"], stdin: nil, timeout: 20)
        #expect(after.exitCode == 0)
        try await service.testConnection(config: iosConfig, key: bundle)
        #expect(store.record(for: endpoint)?.pinned.fingerprint == env.fingerprintB)
        print("[live] re-trusted \(env.fingerprintB) and reconnected")
    }
}

#endif
