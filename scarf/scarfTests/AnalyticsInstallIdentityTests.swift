import Foundation
import ScarfCore
import Stats
import StatsTesting
import Testing
@testable import scarf

/// The install id must survive a relaunch (decision 2026-09-14, `Analytics.consent`).
///
/// Driven by swift-stats' own `RelaunchProbe`: two launches of a client built
/// from Scarf's REAL configuration (`Analytics.makeConfiguration`), under a
/// unique app id and temporary storage the probe creates and removes — the
/// developer's real `com.scarf.app` suite is never touched. Serialized because
/// the probe builds real `StatsClient`s, like `AnalyticsFacadeTests`.
@Suite(.serialized)
struct AnalyticsInstallIdentityTests {
    private func shippingConfiguration() -> StatsConfiguration {
        Analytics.makeConfiguration(sink: InMemorySink(), isPreRelease: true)
    }

    @Test("the shipping configuration keeps one install id across a relaunch")
    func shippingConfigurationKeepsTheInstallId() async throws {
        let probe = try #require(await RelaunchProbe.installIDsAcrossRelaunch(
            configuration: shippingConfiguration()
        ))
        #expect(probe.isInstallIdStable,
                "the install id did not persist across launches: \(probe.installIdBeforeRelaunch) vs \(probe.installIdAfterRelaunch)")
        let id = probe.installIdBeforeRelaunch
        #expect(id.count == 64 && id.allSatisfy(\.isHexDigit),
                "the install id on the wire is not a SHA-256 hex digest — is the raw UUID leaking? \(id)")
    }

    /// The control: the same configuration without `.identity` mints a fresh
    /// id per session, so the equal pair above cannot be the probe comparing
    /// a constant.
    @Test("without `.identity` the install id is per session")
    func withoutIdentityTheInstallIdIsPerSession() async throws {
        var configuration = shippingConfiguration()
        configuration.consent = [.usage, .diagnostics]
        let probe = try #require(await RelaunchProbe.installIDsAcrossRelaunch(configuration: configuration))
        #expect(!probe.isInstallIdStable, "control failed: the two ungranted sessions shared an install id")
    }
}

/// Nested in the one serialized tree that every `Analytics.install` suite
/// shares (see `CapturingUsageTracker`): `recordIfPresentGates` swaps the
/// process-wide tracker.
extension AnalyticsConnectionEventsTests {

/// `Analytics.Presence` — the gate that keeps unattended work (scheduled
/// update checks, background-poll perf samples, wake reconnects) from opening
/// an analytics session on an idle Mac.
@Suite("Analytics presence gate", .serialized)
struct AnalyticsPresenceTests {
    /// A presence whose clock the test moves by hand.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { _now } }
        func advance(_ by: Duration) { lock.withLock { _now += by } }
    }

    private func makePresence() -> (Analytics.Presence, Clock) {
        let clock = Clock()
        return (Analytics.Presence(window: .seconds(30 * 60), now: { clock.now }), clock)
    }

    @Test("nobody is present before the app has ever been active")
    func absentAtLaunch() {
        let (presence, _) = makePresence()
        #expect(!presence.isPresent)
    }

    @Test("frontmost is present no matter how long it has been")
    func activeIsPresent() {
        let (presence, clock) = makePresence()
        presence.becameActive()
        clock.advance(.seconds(24 * 3600))
        #expect(presence.isPresent)
    }

    @Test("present within the gap after resigning, absent after it")
    func resignStartsTheGap() {
        let (presence, clock) = makePresence()
        presence.becameActive()
        presence.resignedActive()
        clock.advance(.seconds(29 * 60))
        #expect(presence.isPresent)
        clock.advance(.seconds(2 * 60))
        #expect(!presence.isPresent)
    }

    @Test("a menu-bar interaction counts as present without activating the app")
    func menuBarTouch() {
        let (presence, clock) = makePresence()
        presence.touched()
        #expect(presence.isPresent)
        clock.advance(.seconds(31 * 60))
        #expect(!presence.isPresent)
    }

    @Test("recordIfPresent drops events while nobody is present and records them otherwise")
    func recordIfPresentGates() {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let (presence, _) = makePresence()
        Analytics.recordIfPresent(.updateCheckCompleted(result: .upToDate), presence: presence)
        #expect(tracker.captured.isEmpty)

        presence.becameActive()
        Analytics.recordIfPresent(.updateCheckCompleted(result: .upToDate), presence: presence)
        #expect(tracker.names == ["update_check_completed"])
    }

    /// Scarf left frontmost overnight: the screens sleep but the app never
    /// resigns active. Frontmost alone must not count as present.
    @Test("frontmost with the screens asleep stops counting after the gap")
    func frontmostButAway() {
        let (presence, clock) = makePresence()
        presence.becameActive()
        presence.wentAway(.screensAsleep)
        clock.advance(.seconds(29 * 60))
        #expect(presence.isPresent)
        clock.advance(.seconds(8 * 3600))
        #expect(!presence.isPresent)

        presence.cameBack(.screensAsleep)
        #expect(presence.isPresent, "screens back on with Scarf still frontmost")
    }

    /// The screens wake under the lock screen before the person unlocks:
    /// each reason clears on its own signal.
    @Test("every away reason must clear before frontmost counts again")
    func reasonsClearIndependently() {
        let (presence, clock) = makePresence()
        presence.becameActive()
        presence.wentAway(.screenLocked)
        presence.wentAway(.screensAsleep)
        clock.advance(.seconds(31 * 60))
        presence.cameBack(.screensAsleep)
        #expect(!presence.isPresent, "still locked")
        presence.cameBack(.screenLocked)
        #expect(presence.isPresent)
    }

    // MARK: - Epochs (section_viewed dedupe)

    @Test("the first arrival is epoch 0; a return after the gap starts a new one")
    func epochAdvancesOnlyAfterAnAbsence() {
        let (presence, clock) = makePresence()
        presence.becameActive()
        #expect(presence.epoch == 0)

        // Cmd-Tab away and back inside the gap: same session, same epoch.
        presence.resignedActive()
        clock.advance(.seconds(5 * 60))
        presence.becameActive()
        #expect(presence.epoch == 0)

        // Away past the gap, then back: a new session.
        presence.resignedActive()
        clock.advance(.seconds(31 * 60))
        presence.becameActive()
        #expect(presence.epoch == 1)

        // Screens asleep overnight while frontmost, then awake.
        presence.wentAway(.screensAsleep)
        clock.advance(.seconds(8 * 3600))
        presence.cameBack(.screensAsleep)
        #expect(presence.epoch == 2)
    }

    // MARK: - Hold / defer

    @Test("recordWhenPresent holds while away and replays on return, in order")
    func recordWhenPresentDefers() {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let (presence, _) = makePresence()
        let deferred = Analytics.DeferredEvents(capacity: 8)
        Analytics.recordWhenPresent(.reconnectAttempted(trigger: .wake), presence: presence, deferred: deferred)
        Analytics.recordWhenPresent(.reconnectSucceeded(trigger: .wake, durationBucket: .init(seconds: 2)),
                                    presence: presence, deferred: deferred)
        #expect(tracker.captured.isEmpty)
        #expect(deferred.count == 2)

        presence.becameActive()
        deferred.drain()
        #expect(tracker.names == ["reconnect_attempted", "reconnect_succeeded"])
        #expect(deferred.count == 0)

        // Present: straight through.
        Analytics.recordWhenPresent(.reconnectAttempted(trigger: .wake), presence: presence, deferred: deferred)
        #expect(tracker.names.count == 3)
    }

    @Test("the deferred queue is bounded and keeps the earliest events")
    func deferredQueueIsBounded() {
        let deferred = Analytics.DeferredEvents(capacity: 2)
        var ran: [Int] = []
        for i in 0..<5 { deferred.hold { ran.append(i) } }
        #expect(deferred.count == 2)
        deferred.drain()
        #expect(ran == [0, 1])
    }

    /// The ScarfCore bridge's two policies: poller noise is dropped while
    /// away; an agent turn that finishes while away is kept for the return.
    @Test("the core bridge drops poller events and defers agent turns while away")
    func coreBridgePolicies() {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let (presence, _) = makePresence()
        let deferred = Analytics.DeferredEvents(capacity: 8)
        let bridge = Analytics.coreBridge(presence: presence, deferred: deferred)

        bridge.record("connection_degraded", ["cause": "home_missing"])
        bridge.record("circuit_breaker_opened", ["backoff_bucket": "lt_1s"])
        bridge.record("agent_turn_completed", ["duration_bucket": "gt_60s"])
        bridge.record("reconnect_attempted", ["trigger": "manual"])   // ungated
        #expect(tracker.names == ["reconnect_attempted"])
        #expect(deferred.count == 1)

        presence.becameActive()
        deferred.drain()
        #expect(tracker.names == ["reconnect_attempted", "agent_turn_completed"])

        bridge.record("connection_degraded", ["cause": "home_missing"])
        #expect(tracker.names.last == "connection_degraded")
    }

    /// Launch-path events wait for the first presence, so a launch nobody sees
    /// opens no session. Real client, in-memory sink, the tests' own app id.
    @Test("the production tracker holds every event until first released")
    func launchHold() async throws {
        let sink = InMemorySink()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-launch-hold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = StatsClient(configuration: Analytics.makeConfiguration(
            sink: sink, isPreRelease: true, appId: AnalyticsTestIDs.appId,
            storageDirectory: directory, clock: ManualClock()))
        let tracker = StatsUsageTracker(client: client)
        await tracker.setEnabled(true)

        tracker.record(.firstRun(platform: .macos))
        tracker.record(rawName: "hermes_probe_failed", props: ["fallback": "empty"])
        #expect(tracker.heldEventCount == 2)
        await client.flush()
        #expect(await sink.sentEventNames.isEmpty)

        tracker.releaseLaunchHold()
        #expect(tracker.heldEventCount == 0)
        tracker.record(.notificationToggled(enabled: true))   // passes straight through now
        await client.flush()
        await client.shutdown()
        let names = await sink.sentEventNames
        #expect(names.filter { !$0.hasPrefix("session_") }
                == ["first_run", "hermes_probe_failed", "notification_toggled"])
    }

    /// Resigning while already away must not restart the gap — that would
    /// stamp a "last seen" on a moment nobody was there.
    @Test("resigning active while away does not count as being seen")
    func resignWhileAway() {
        let (presence, clock) = makePresence()
        presence.becameActive()
        presence.wentAway(.screensAsleep)
        clock.advance(.seconds(31 * 60))
        presence.resignedActive()
        #expect(!presence.isPresent)
    }
}

}
