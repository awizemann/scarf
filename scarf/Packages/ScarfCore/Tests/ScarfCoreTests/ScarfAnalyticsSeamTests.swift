import Testing
import Foundation
@testable import ScarfCore

/// The `ScarfCore` half of the analytics seam: the package emits events but
/// links no analytics SDK, so with no recorder installed every call is a
/// no-op — which is exactly the state iOS ships in.
///
/// Serialized: `ScarfAnalytics.recorder` is process-wide, so two of these
/// running concurrently would capture each other's events. Every test that
/// installs one clears it again in a `defer`.
@Suite("ScarfAnalytics seam", .serialized)
struct ScarfAnalyticsSeamTests {

    /// Captures what `ScarfCore` emits. `@unchecked Sendable` around a lock
    /// because the seam is deliberately callable from any isolation.
    private final class Capture: ScarfAnalyticsRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(String, [String: String])] = []
        var events: [(name: String, props: [String: String])] {
            lock.lock(); defer { lock.unlock() }
            return _events.map { (name: $0.0, props: $0.1) }
        }
        func record(_ name: String, _ props: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            _events.append((name, props))
        }
    }

    // MARK: - Default no-op

    @Test("with no recorder installed the seam is inert")
    func defaultIsNoOp() {
        ScarfAnalytics.install(nil)
        #expect(ScarfAnalytics.recorder == nil)
        // Must not trap, and must not require a host to have wired anything.
        ScarfAnalytics.record("connect_attempted", ["transport": "ssh"])

        // The same holds for the real emission sites: a gate driven all the
        // way open on an iOS-shaped process (no recorder) behaves exactly as
        // it did before analytics existed.
        let gate = SSHConnectionGate(failureThreshold: 2, baseDelay: 30, maxDelay: 300)
        gate.recordFailure("h:22")
        gate.recordFailure("h:22")
        #expect(gate.isOpen("h:22"))
        gate.recordSuccess("h:22")
        #expect(!gate.isOpen("h:22"))
    }

    // MARK: - Forwarding

    @Test("an installed recorder receives what ScarfCore emits")
    func forwardsToInstalledRecorder() {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }

        ScarfAnalytics.record("connection_degraded", ["cause": "home_missing"])

        #expect(capture.events.count == 1)
        #expect(capture.events.first?.name == "connection_degraded")
        #expect(capture.events.first?.props["cause"] == "home_missing")
    }

    // MARK: - Circuit breaker transitions

    @Test("the breaker announces only the open and close edges")
    func breakerEmitsEdgesOnly() {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let gate = SSHConnectionGate(failureThreshold: 3, baseDelay: 30, maxDelay: 300)
        let key = SSHConnectionGate.key(host: "example.com", port: nil)

        // Below the threshold: nothing is announced.
        gate.recordFailure(key, now: t0)
        gate.recordFailure(key, now: t0)
        #expect(capture.events.isEmpty)

        // Third failure trips it.
        gate.recordFailure(key, now: t0)
        #expect(capture.events.map(\.name) == ["circuit_breaker_opened"])
        #expect(capture.events[0].props["failure_count"] == "3")
        #expect(capture.events[0].props["backoff_bucket"] == "15_60s")  // baseDelay 30s
    }

    @Test("a failed probe while already open does not re-announce")
    func breakerDoesNotSpamWhileOpen() {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let gate = SSHConnectionGate(failureThreshold: 2, baseDelay: 30, maxDelay: 300)
        let key = "example.com:22"

        gate.recordFailure(key, now: t0)
        gate.recordFailure(key, now: t0)                       // opens
        for i in 1...10 {
            gate.recordFailure(key, now: t0.addingTimeInterval(Double(i) * 60))
        }
        #expect(capture.events.filter { $0.name == "circuit_breaker_opened" }.count == 1)
    }

    @Test("success closes the breaker once, and only when it was open")
    func breakerClosesOnce() {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }

        let gate = SSHConnectionGate(failureThreshold: 2, baseDelay: 30, maxDelay: 300)
        let key = "example.com:22"

        // A healthy host's steady stream of successes announces nothing —
        // this is the polling-spam guard.
        for _ in 0..<50 { gate.recordSuccess(key) }
        #expect(capture.events.isEmpty)

        gate.recordFailure(key)
        gate.recordFailure(key)
        gate.recordSuccess(key)
        gate.recordSuccess(key)
        #expect(capture.events.filter { $0.name == "circuit_breaker_closed" }.count == 1)
    }

    @Test("an explicit reset is not reported as a recovery")
    func resetIsSilent() {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }

        let gate = SSHConnectionGate(failureThreshold: 2, baseDelay: 30, maxDelay: 300)
        gate.recordFailure("h:22")
        gate.recordFailure("h:22")
        gate.reset("h:22")
        #expect(capture.events.filter { $0.name == "circuit_breaker_closed" }.isEmpty)
    }

    // MARK: - Buckets and cause tokens

    @Test("duration buckets are closed at their edges", arguments: [
        (-5.0, "lt_1s"), (0.0, "lt_1s"), (0.999, "lt_1s"),
        (1.0, "1_5s"), (4.999, "1_5s"),
        (5.0, "5_15s"), (14.999, "5_15s"),
        (15.0, "15_60s"), (59.999, "15_60s"),
        (60.0, "gt_60s"), (3600.0, "gt_60s"),
    ])
    func durationBuckets(seconds: TimeInterval, expected: String) {
        #expect(ScarfAnalytics.durationBucket(seconds) == expected)
    }

    @Test("a non-finite duration degrades instead of producing a stray token")
    func durationBucketHandlesNonFinite() {
        #expect(ScarfAnalytics.durationBucket(.nan) == "lt_1s")
        #expect(ScarfAnalytics.durationBucket(.infinity) == "gt_60s")
    }

    @Test("degraded causes map to bounded tokens and drop the profile name")
    func degradedCauseTokens() {
        #expect(ConnectionStatusViewModel.analyticsCause(.configMissing) == "config_missing")
        #expect(ConnectionStatusViewModel.analyticsCause(.homeMissing) == "home_missing")
        #expect(ConnectionStatusViewModel.analyticsCause(.configUnreadable) == "config_unreadable")
        #expect(ConnectionStatusViewModel.analyticsCause(.unknown) == "unknown")
        // The profile name is user-chosen text and must not survive.
        let token = ConnectionStatusViewModel.analyticsCause(.profileActive(name: "acme-prod"))
        #expect(token == "profile_active")
        #expect(!token.contains("acme"))
    }

    // MARK: - error_kind

    @Test("every TransportError case has a bounded, payload-free error_kind")
    func errorKinds() {
        let cases: [(TransportError, String)] = [
            (.hostUnreachable(host: "secret.internal", stderr: "no route to host"), "host_unreachable"),
            (.authenticationFailed(host: "secret.internal", stderr: "Permission denied"), "auth_failed"),
            (.hostKeyMismatch(host: "secret.internal", stderr: "REMOTE HOST IDENTIFICATION HAS CHANGED"), "host_key_mismatch"),
            (.commandFailed(exitCode: 3, stderr: "boom"), "command_failed"),
            (.fileIO(path: "/Users/someone/secret", underlying: "EPERM"), "file_io"),
            (.timeout(seconds: 20, partialStdout: Data()), "timeout"),
            (.circuitOpen(host: "secret.internal", retryAt: Date()), "circuit_open"),
            (.other(message: "unclassified"), "other"),
        ]
        for (error, expected) in cases {
            let kind = error.analyticsErrorKind
            #expect(kind == expected)
            // No associated value ever leaks into the token.
            #expect(!kind.contains("secret"))
            #expect(!kind.contains("/Users"))
        }
    }

    @Test("classifySSHFailure feeds the same buckets the taxonomy names")
    func classifierFeedsErrorKinds() {
        func kind(_ stderr: String, exit: Int32 = 255) -> String {
            TransportError.classifySSHFailure(host: "h", exitCode: exit, stderr: stderr).analyticsErrorKind
        }
        #expect(kind("Permission denied (publickey).") == "auth_failed")
        #expect(kind("Host key verification failed.") == "host_key_mismatch")
        #expect(kind("ssh: connect to host h port 22: Connection refused") == "host_unreachable")
        #expect(kind("ssh: Could not resolve hostname h") == "host_unreachable")
        #expect(kind("some remote tool exploded", exit: 3) == "command_failed")
    }
}
