#if canImport(Citadel)

import Testing
import Foundation
import Dispatch
import ScarfCore
@testable import ScarfIOS

// LIVE integration test — drives the REAL Citadel transport through
// `CitadelTransportPool` against a real sshd, reproducing the gh#112 chat-init
// sequence (read + two `hermes config set` writes). Proves the pooled path
// completes without the "Transport refused" connect-throw, and that a
// concurrent burst reuses ONE connection instead of churning fresh handshakes.
//
// Skipped unless SCARF_LIVE_SSH_HOST is set, so normal `swift test` / CI never
// touch the network. Run it behind an ephemeral localhost sshd + a throwaway
// HERMES_HOME (see scripts/verify-ios-transport-pool.sh). Required env:
//   SCARF_LIVE_SSH_HOST, SCARF_LIVE_SSH_PORT, SCARF_LIVE_SSH_USER,
//   SCARF_LIVE_AUTHORIZED_KEYS (file the sshd reads), SCARF_LIVE_HERMES_HOME
//   (throwaway dir — writes go here, never the real ~/.hermes).

private struct LiveEnv {
    let host: String
    let port: Int
    let user: String
    let authorizedKeys: String
    let hermesHome: String

    static func load() -> LiveEnv? {
        let e = ProcessInfo.processInfo.environment
        guard let host = e["SCARF_LIVE_SSH_HOST"],
              let user = e["SCARF_LIVE_SSH_USER"],
              let ak = e["SCARF_LIVE_AUTHORIZED_KEYS"],
              let home = e["SCARF_LIVE_HERMES_HOME"] else { return nil }
        let port = Int(e["SCARF_LIVE_SSH_PORT"] ?? "22") ?? 22
        return LiveEnv(host: host, port: port, user: user, authorizedKeys: ak, hermesHome: home)
    }
}

/// Generate a fresh Ed25519 key (the app's exact key path), append its public
/// key to the sshd's `authorized_keys`, and return a bundle + matching config.
private func liveAuthorize(_ env: LiveEnv) throws -> (SSHKeyBundle, SSHConfig) {
    let bundle = try Ed25519KeyGenerator.generate(comment: "scarf-verify")
    let url = URL(fileURLWithPath: env.authorizedKeys)
    let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try (existing + bundle.publicKeyOpenSSH + "\n").write(to: url, atomically: true, encoding: .utf8)
    return (bundle, SSHConfig(host: env.host, user: env.user, port: env.port))
}

private func liveTransport(_ id: ServerID, _ config: SSHConfig, _ bundle: SSHKeyBundle) -> CitadelServerTransport {
    CitadelServerTransport(contextID: id, config: config, displayName: "live", keyProvider: { bundle })
}

/// A `hermes config set` pinned to a throwaway HERMES_HOME so the real
/// ~/.hermes is never touched (the transport only injects HERMES_HOME for
/// profile paths, so we set it ourselves).
private func liveConfigSet(_ key: String, _ value: String, home: String) -> String {
    "HERMES_HOME=\(home) PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" hermes config set '\(key)' '\(value)'"
}

private func liveHermes(_ args: String, home: String? = nil) -> String {
    let h = home.map { "HERMES_HOME=\($0) " } ?? ""
    return "\(h)PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" hermes \(args)"
}

private final class FailCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@Suite(.serialized, .enabled(if: LiveEnv.load() != nil))
struct CitadelTransportPoolLiveTests {

    /// The gh#112 failing flow, end to end, through the pool: version probe →
    /// `config set model.provider` → `config set model.default` → read back.
    /// Must complete with no thrown connect ("Transport refused") and the
    /// write must land in the throwaway HERMES_HOME.
    @Test func pooledChatInitSequenceSucceeds() async throws {
        let env = try #require(LiveEnv.load())
        let (bundle, config) = try liveAuthorize(env)
        let pool = CitadelTransportPool()
        let id = ServerID()
        func tx() -> any ServerTransport {
            pool.transport(for: id, config: config) { liveTransport(id, config, bundle) }
        }

        let version = try tx().runProcess(
            executable: "/bin/sh", args: ["-c", liveHermes("--version")], stdin: nil, timeout: 20)
        #expect(version.exitCode == 0)
        #expect(version.stdoutString.contains("Hermes Agent"))

        // The exact command the chat banner reported as "Transport refused".
        let provider = try tx().runProcess(
            executable: "/bin/sh",
            args: ["-c", liveConfigSet("model.provider", "custom:scarftest", home: env.hermesHome)],
            stdin: nil, timeout: 20)
        #expect(provider.exitCode == 0)

        let model = try tx().runProcess(
            executable: "/bin/sh",
            args: ["-c", liveConfigSet("model.default", "scarf-test-model", home: env.hermesHome)],
            stdin: nil, timeout: 20)
        #expect(model.exitCode == 0)

        // Read the written config.yaml back over SFTP through the SAME pooled
        // connection — this is the read path the bug silently swallowed to
        // "empty", and it proves the write landed in the throwaway home.
        let raw = try tx().readFile(env.hermesHome + "/config.yaml")
        #expect(String(decoding: raw, as: UTF8.self).contains("custom:scarftest"))

        // One warm connection served the entire sequence.
        #expect(pool.pooledCount == 1)
        await pool.evictAll()
    }

    /// Concurrent burst: N fresh (un-pooled) transports each open their own
    /// handshake and race the sshd's MaxStartups limit (some throw = the
    /// gh#112 churn); the same N ops through ONE pooled transport never churn.
    @Test func poolingAvoidsChurnUnderConcurrentBurst() async throws {
        let env = try #require(LiveEnv.load())
        let (bundle, config) = try liveAuthorize(env)
        let n = 24

        // BEFORE — un-pooled: a fresh transport (own connection) per op.
        let unpooled = FailCounter()
        DispatchQueue.concurrentPerform(iterations: n) { _ in
            let t = liveTransport(ServerID(), config, bundle)
            do {
                _ = try t.runProcess(executable: "/bin/sh", args: ["-c", "true"], stdin: nil, timeout: 20)
            } catch {
                unpooled.bump()   // connect threw = churn failure
            }
        }

        // AFTER — pooled: all ops share one connection.
        let pool = CitadelTransportPool()
        let id = ServerID()
        let pooled = FailCounter()
        DispatchQueue.concurrentPerform(iterations: n) { _ in
            let t = pool.transport(for: id, config: config) { liveTransport(id, config, bundle) }
            do {
                _ = try t.runProcess(executable: "/bin/sh", args: ["-c", "true"], stdin: nil, timeout: 20)
            } catch {
                pooled.bump()
            }
        }

        // Informational (MaxStartups-dependent), then the hard guarantee.
        print("[live] churn — un-pooled failures: \(unpooled.value)/\(n), pooled failures: \(pooled.value)/\(n)")
        #expect(pooled.value == 0)
        #expect(pool.pooledCount == 1)
        await pool.evictAll()
    }

    /// A command that has already exited by the time its output stream ends
    /// (every fast one) must come back as a result, not as
    /// "NIOCore.ChannelError error 6" — Citadel's `withExec` closes a channel
    /// the remote already closed, and NIOSSH fails that with `alreadyClosed`.
    /// Both the zero and the non-zero exit are asserted, because the same
    /// close also REPLACED `CommandFailed` for a non-zero exit.
    @Test func fastExecCompletesInsteadOfThrowingAlreadyClosed() async throws {
        let env = try #require(LiveEnv.load())
        let (bundle, config) = try liveAuthorize(env)
        let t = liveTransport(ServerID(), config, bundle)

        let ok = try t.runProcess(executable: "/bin/sh", args: ["-c", "echo hi"], stdin: nil, timeout: 20)
        #expect(ok.exitCode == 0)
        #expect(ok.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")

        let failed = try t.runProcess(executable: "/bin/sh", args: ["-c", "echo nope >&2; exit 3"], stdin: nil, timeout: 20)
        #expect(failed.exitCode == 3)
        #expect(failed.stderrString.contains("nope"))

        // The dashboard's own shape: a heredoc script through streamScript.
        let script = try await t.streamScript("set -e\necho version\necho '[{\"n\":1}]'", timeout: 20)
        #expect(script.exitCode == 0)
        #expect(script.stdoutString.contains("version"))
    }
}

#endif // canImport(Citadel)
