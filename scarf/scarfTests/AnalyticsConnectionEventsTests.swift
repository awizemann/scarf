import Foundation
import Testing
import Stats
import StatsTesting
import ScarfCore
@testable import scarf

/// Phase 3 (connection & transport) instrumentation: the app-side half of the
/// `ScarfCore` recorder seam, the shared duration buckets, and the `error_kind`
/// classification the Add Server probe reports.
///
/// Serialized for the same reason `AnalyticsFacadeTests` is — these build real
/// `StatsClient`s around `Analytics.makeConfiguration`, which share one
/// app-id-keyed `UserDefaults` enabled flag — plus one of its own:
/// `ScarfAnalytics.recorder` is process-wide, so an installed recorder must
/// never overlap another test's.
@Suite("Analytics connection events", .serialized)
struct AnalyticsConnectionEventsTests {

    /// Forwards `ScarfCore`'s seam into a specific client — the same shape as
    /// the app's private `Analytics.CoreBridge`, but pointed at a test client
    /// instead of the (deliberately nil-under-XCTest) shared one.
    private struct TestBridge: ScarfAnalyticsRecording {
        let client: StatsClient
        func record(_ name: String, _ props: [String: String]) {
            client.record(name, props: props.mapValues { StatsValue.string($0) })
        }
    }

    private func makeHarness() async -> (StatsClient, InMemorySink, URL) {
        let sink = InMemorySink()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-analytics-conn-\(UUID().uuidString)", isDirectory: true)
        let client = StatsClient(configuration: Analytics.makeConfiguration(
            sink: sink,
            isPreRelease: true,
            storageDirectory: directory,
            clock: ManualClock()
        ))
        await client.setEnabled(true)
        return (client, sink, directory)
    }

    // MARK: - The seam

    @Test("an event emitted inside ScarfCore lands in the app's sink")
    func coreSeamReachesTheSink() async throws {
        let (client, sink, directory) = await makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }

        ScarfAnalytics.install(TestBridge(client: client))
        defer { ScarfAnalytics.install(nil) }

        // Drive a *real* ScarfCore emission site rather than calling the seam
        // directly: this is the whole point of the phase — a type inside a
        // package that links no analytics SDK produces an app-side event.
        let gate = SSHConnectionGate(failureThreshold: 2, baseDelay: 30, maxDelay: 300)
        let key = SSHConnectionGate.key(host: "example.test", port: 2222)
        gate.recordFailure(key)
        gate.recordFailure(key)   // opens
        gate.recordSuccess(key)   // closes

        await client.flush()
        await client.shutdown()

        let names = await sink.sentEventNames
        #expect(names.contains("circuit_breaker_opened"))
        #expect(names.contains("circuit_breaker_closed"))

        let opened = try #require(await sink.sentEvents.first { $0.name == "circuit_breaker_opened" })
        #expect(opened.props["failure_count"] == .string("2"))
        #expect(opened.props["backoff_bucket"] == .string("15_60s"))
        // The host and port keyed the gate but must not be anywhere in the
        // event: props carry the fact, never the identity.
        for value in opened.props.values {
            if case .string(let s) = value {
                #expect(!s.contains("example.test"))
                #expect(!s.contains("2222"))
            }
        }
    }

    @Test("with no bridge installed, ScarfCore emissions reach nothing")
    func coreSeamIsInertWithoutBridge() async throws {
        let (client, sink, directory) = await makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }

        ScarfAnalytics.install(nil)
        let gate = SSHConnectionGate(failureThreshold: 1, baseDelay: 30, maxDelay: 300)
        gate.recordFailure("h:22")
        gate.recordSuccess("h:22")

        await client.flush()
        await client.shutdown()
        #expect(await sink.sentEventNames.isEmpty)
    }

    // MARK: - Buckets

    @Test("the facade's duration bucket is the package's, not a second copy")
    func durationBucketIsShared() {
        for seconds in [-1.0, 0.5, 1.0, 4.9, 5.0, 14.9, 15.0, 59.9, 60.0, 600.0] {
            #expect(Analytics.durationBucket(seconds) == ScarfAnalytics.durationBucket(seconds))
        }
        #expect(Analytics.durationBucket(0.99) == "lt_1s")
        #expect(Analytics.durationBucket(1.0) == "1_5s")
        #expect(Analytics.durationBucket(5.0) == "5_15s")
        #expect(Analytics.durationBucket(15.0) == "15_60s")
        #expect(Analytics.durationBucket(60.0) == "gt_60s")
        // The `since:` overload measures from a past date; a start "now"
        // must not fall out of the smallest bucket.
        #expect(Analytics.durationBucket(since: Date()) == "lt_1s")
        #expect(Analytics.durationBucket(since: Date(timeIntervalSinceNow: -120)) == "gt_60s")
    }

    // MARK: - wake sweep classification

    private func names(_ outcomes: [WakeReconnectMetrics.HostOutcome]) -> [String] {
        WakeReconnectMetrics.events(for: outcomes, recoverySeconds: 1).map(\.name)
    }

    /// The regression this replaces: `.alive` (master healthy — nothing
    /// reconnected) used to be counted as the success and `.recovered` (the
    /// actual reconnect) was ignored, inverting the metric.
    @Test("a wake where every master was healthy emits nothing")
    func healthyWakeIsSilent() {
        #expect(names([]).isEmpty)
        #expect(names([.healthy, .healthy]).isEmpty)
        #expect(names([.noMaster, .noMaster]).isEmpty)
        #expect(names([.noMaster, .healthy]).isEmpty)
    }

    @Test("a torn-down dead master is one attempted + one succeeded")
    func recoveredWakeReportsSuccess() {
        #expect(names([.recovered]) == ["reconnect_attempted", "reconnect_succeeded"])
        // One pair per wake, never per host.
        #expect(names([.healthy, .recovered, .recovered, .noMaster])
            == ["reconnect_attempted", "reconnect_succeeded"])
    }

    @Test("a teardown that left the master in place is attempted without succeeded")
    func failedRecoveryReportsNoSuccess() {
        #expect(names([.recoveryFailed]) == ["reconnect_attempted"])
        #expect(names([.healthy, .recoveryFailed]) == ["reconnect_attempted"])
        // Mixed fleet: one host recovering is enough to call the wake a success.
        #expect(names([.recoveryFailed, .recovered])
            == ["reconnect_attempted", "reconnect_succeeded"])
    }

    @Test("duration_bucket rides only the success and comes from the recovery work")
    func durationBucketScopedToRecovery() {
        let events = WakeReconnectMetrics.events(for: [.healthy, .recovered], recoverySeconds: 2)
        #expect(events.first?.props == ["trigger": "wake"])
        #expect(events.last?.props == [
            "trigger": "wake",
            "duration_bucket": Analytics.durationBucket(2),
        ])
    }

    // MARK: - error_kind, as the Add Server probe reports it

    @Test("the probe's error_kind covers the taxonomy's buckets")
    func probeErrorKinds() {
        func kind(exit: Int32, stderr: String) -> String {
            TestConnectionProbe.analyticsErrorKind(host: "example.test", exitCode: exit, stderr: stderr)
        }
        #expect(kind(exit: 255, stderr: "Permission denied (publickey).") == "auth_failed")
        #expect(kind(exit: 255, stderr: "Host key verification failed.") == "host_key_mismatch")
        #expect(kind(exit: 255, stderr: "ssh: connect to host x port 22: Connection refused") == "host_unreachable")
        #expect(kind(exit: 3, stderr: "remote tool exploded") == "command_failed")
        // Our own synthesized exit codes: the 20s deadline and a Process
        // that never launched.
        #expect(kind(exit: -1, stderr: "Timed out after 20s.\n\nssh trace so far:\n…") == "timeout")
        #expect(kind(exit: -1, stderr: "Failed to launch /usr/bin/ssh: nope") == "other")
        // An unrecognized 255 never ran a remote command, so `command_failed`
        // would be a lie.
        #expect(kind(exit: 255, stderr: "ssh exited weirdly") == "other")
    }

    @Test("no probe stderr or hostname can survive into error_kind")
    func probeErrorKindLeaksNothing() {
        let noisy = "Permission denied for user hunter2 at secret.internal:/Users/someone/.ssh/id_ed25519"
        let kind = TestConnectionProbe.analyticsErrorKind(host: "secret.internal", exitCode: 255, stderr: noisy)
        #expect(kind == "auth_failed")
        for fragment in ["secret.internal", "hunter2", "/Users", "id_ed25519"] {
            #expect(!kind.contains(fragment))
        }
    }
}
