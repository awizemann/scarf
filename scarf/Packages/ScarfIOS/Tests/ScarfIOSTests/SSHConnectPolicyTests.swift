#if canImport(Citadel)

import Testing
import Foundation
import NIOCore
import Citadel
@testable import ScarfIOS

/// Retry-contract coverage for `SSHConnectPolicy` — the fix for the
/// cellular/Tailscale "NIOCore.ChannelError error 0" (= `connectTimeout`;
/// Swift numbers bridged enum error codes by ABI tag, payload cases
/// first). The generic `connect` seam lets us exercise the policy
/// without a live SSH server.
@Suite struct SSHConnectPolicyTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() -> Int { lock.withLock { n += 1; return n } }
        var value: Int { lock.withLock { n } }
    }

    @Test func succeedsFirstTryWithoutRetrying() async throws {
        let calls = Counter()
        let value = try await SSHConnectPolicy.connect(retryDelayNanoseconds: 0) {
            _ = calls.bump()
            return 42
        }
        #expect(value == 42)
        #expect(calls.value == 1)
    }

    @Test func retriesLoginTimeoutThenSucceeds() async throws {
        let calls = Counter()
        let value = try await SSHConnectPolicy.connect(retryDelayNanoseconds: 0) { () -> Int in
            if calls.bump() < 3 {
                throw ChannelError.connectTimeout(.seconds(10))
            }
            return 7
        }
        #expect(value == 7)
        #expect(calls.value == 3)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let calls = Counter()
        await #expect(throws: ChannelError.self) {
            _ = try await SSHConnectPolicy.connect(retryDelayNanoseconds: 0) { () -> Int in
                _ = calls.bump()
                throw ChannelError.connectTimeout(.seconds(10))
            }
        }
        #expect(calls.value == SSHConnectPolicy.maxAttempts)
    }

    @Test func nonTimeoutErrorsPropagateImmediately() async throws {
        // A rejected key must NOT be retried — repeating a failing auth
        // burns time and can trip sshd's per-source penalties.
        let calls = Counter()
        await #expect(throws: SSHClientError.self) {
            _ = try await SSHConnectPolicy.connect(retryDelayNanoseconds: 0) { () -> Int in
                _ = calls.bump()
                throw SSHClientError.allAuthenticationOptionsFailed
            }
        }
        #expect(calls.value == 1)
    }

    @Test func timeoutClassifier() {
        #expect(SSHConnectPolicy.isTimeout(ChannelError.connectTimeout(.seconds(10))))
        #expect(!SSHConnectPolicy.isTimeout(ChannelError.connectPending))
        #expect(!SSHConnectPolicy.isTimeout(SSHClientError.allAuthenticationOptionsFailed))
    }

    @Test func describesTimeoutAndAuthFailuresReadably() {
        let timeoutText = SSHConnectPolicy.describeConnectFailure(
            ChannelError.connectTimeout(.seconds(10)), host: "mini.tail1234.ts.net"
        )
        #expect(timeoutText.contains("timed out"))
        #expect(timeoutText.contains("mini.tail1234.ts.net"))

        let authText = SSHConnectPolicy.describeConnectFailure(
            SSHClientError.allAuthenticationOptionsFailed, host: "mini.local"
        )
        #expect(authText.contains("rejected"))
        #expect(authText.contains("authorized_keys"))
    }
}

#endif // canImport(Citadel)
