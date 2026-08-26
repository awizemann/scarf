import Foundation
import ScarfCore
import Stats
import StatsCloudflare
import os

private nonisolated let logger = Logger(subsystem: "com.scarf", category: "Analytics")

/// App-wide analytics facade in front of an injectable ``UsageTracking``.
///
/// This type is the *entry point*; ``StatsUsageTracker`` (in
/// `UsageTracking.swift`) is the production *implementation* that owns the
/// single `StatsClient`. Call sites keep calling `Analytics.record(...)`;
/// tests call ``install(_:)`` to swap the tracker underneath.
///
/// Everything here is `nonisolated` and fire-and-forget: `record(_ event:)` —
/// which takes a ``UsageEvent``, the closed set that *is* the taxonomy — is
/// the one entry point the rest of the app uses, and it never suspends, never
/// touches disk on the caller's thread and never throws. If the client cannot
/// be constructed — a malformed endpoint, or a missing/unexpanded write key in
/// the bundle's Info.plist — the facade degrades to a no-op: analytics must
/// never be able to fail a launch.
///
/// Props discipline (see documents/analytics/swift-stats-adoption-event-taxonomy.md):
/// snake_case event names, flat props, **no** free text, file paths, URLs,
/// hostnames or identifiers. Durations and counts go in as coarse bucket
/// strings. Nothing in this file reads user content, and callers must not pass
/// any.
///
/// `nonisolated` in full: the app target defaults new declarations to
/// `@MainActor`, and analytics must be callable from any isolation without a
/// hop — an inherited `@MainActor` on the tracker would make `record()` from a
/// background context a hard error under the Swift 6 language mode.
nonisolated enum Analytics {
    /// Stable for the lifetime of the install-id scheme — changing it
    /// re-buckets every existing install into a new anonymous identity.
    private static let installIdSalt = "scarf-macos-2026"

    /// Info.plist key carrying the swift-stats write key.
    static let writeKeyInfoPlistKey = "SwiftStatsWriteKey"

    /// Project-scoped, append-only **write** key, read at runtime from the
    /// app bundle's Info.plist.
    ///
    /// Posture: the key *ships* in the built Info.plist, and that is fine —
    /// it is append-only, scoped to this one project and can read nothing
    /// (schema §2.4), so the worst an abuser can do is inject junk events
    /// into our own metrics. What is **not** fine is committing it: this repo
    /// is public, and a key in source control is a leak the moment it lands.
    /// So the key never appears in source. It reaches the binary through
    /// `scarf/Configs/SwiftStatsLocal.xcconfig` — an uncommitted, gitignored
    /// file that defines `SWIFT_STATS_WRITE_KEY`, which the committed
    /// `SwiftStats.xcconfig` optionally includes and the Info.plist expands
    /// into `SwiftStatsWriteKey`. A checkout without that local file builds
    /// fine and simply runs with analytics off. Rotation and revocation both
    /// happen in the ScarfMon dashboard; anything that ever gains read scope
    /// must not travel this path at all.
    static let writeKey: String? = validWriteKey(
        Bundle.main.object(forInfoDictionaryKey: writeKeyInfoPlistKey) as? String
    )

    /// Pure validator for the raw Info.plist value, `internal` so tests can
    /// hit it directly without a bundle.
    ///
    /// Rejects `nil`, empty and whitespace-only strings, and anything still
    /// containing `$(` — an unexpanded build setting, which is exactly what
    /// a checkout with no `SwiftStatsLocal.xcconfig` would otherwise hand us.
    /// Returns the trimmed key, or `nil` when analytics must stay off.
    static func validWriteKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    static let endpointString = "https://api.swiftstats.co"

    /// Debug builds and the decoupled dev copy installed by
    /// `scripts/build-detached.sh` (a Release build at
    /// `/Applications/scarf-dev.app`) are pre-release traffic and must not
    /// pollute production metrics. Only the bundle's own last path component is
    /// inspected, and only to produce a `Bool` — no path ever reaches a prop.
    static var isPreRelease: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.bundleURL.lastPathComponent == "scarf-dev.app"
        #endif
    }

    /// The one place the app's stats configuration is defined. Exposed
    /// `internal` (not `private`) purely so tests can build the *same*
    /// configuration around an `InMemorySink` — the shipping call site is
    /// ``StatsUsageTracker/makeSharedClient()`` and nothing else may call this.
    ///
    /// Note what is *not* here: `screenMetrics` and `colorScheme` are left at
    /// their defaults rather than read from `NSScreen`/`NSApp`, which would
    /// mean touching AppKit on the main thread during client construction.
    ///
    /// Revisited for Phase 2: `StatsConfiguration.screenMetrics`/`colorScheme`
    /// are plain `var`s on a value type consumed once by `StatsClient.init`
    /// (`Packages` checkout: `Stats/StatsConfiguration.swift`,
    /// `Stats/StatsClient.swift`) — the actor keeps no public setter to patch
    /// either field in after construction, and the shared client is built
    /// lazily and can legitimately be built first from a background thread (the
    /// very first `record()` call, before `applicationDidBecomeActive()` ever
    /// runs). Capturing `NSScreen.main`/effective appearance ahead of that
    /// would mean either hopping to the main actor from a `nonisolated`
    /// lazy initializer (a deadlock risk if that first call is already on
    /// the main thread) or racing a background-thread AppKit read (undefined
    /// behavior). Neither is worth it for two optional context fields, so
    /// defaults stay — this is an accepted, documented gap, not an oversight.
    static func makeConfiguration(
        sink: any StatsSink,
        isPreRelease: Bool,
        storageDirectory: URL? = nil,
        clock: any StatsClock = SystemStatsClock()
    ) -> StatsConfiguration {
        StatsConfiguration(
            appId: "com.scarf.app",
            projectId: "scarf",
            installIdSalt: installIdSalt,
            sink: sink,
            // Explicit, not inherited: this is the same value as
            // `StatsConsent.default`, spelled out so the posture is a
            // decision rather than a package default that could shift
            // under us. There is no per-event consent routing in the
            // package — the groups gate *layers*, not individual events:
            //
            // - `.usage` gates event emission itself. EVERY event Scarf
            //   records rides this one group, including the taxonomy's
            //   "Diagnostics" events (`perf_measure`,
            //   `bootstrap_task_failed`) — denying it emits nothing at all.
            // - `.diagnostics` gates only the per-batch context block (OS,
            //   device model, app version, locale, screen, color scheme).
            //   Denying it sends the documented unknown values there; it
            //   does not suppress any event.
            // - `.identity` is deliberately NOT granted: it would buy a
            //   stable cross-launch install id and a `userId` field, and
            //   Scarf never calls `identify()`. Without it the install id
            //   is ephemeral per session and no `userId` is ever sent.
            consent: [.usage, .diagnostics],
            autoEvents: [.appOpen, .appBackground, .sessions],
            storageDirectory: storageDirectory,
            isPreRelease: isPreRelease,
            clock: clock
        )
    }

    /// True inside a test run or a SwiftUI preview. Both launch the real app
    /// bundle, whose lifecycle observers would otherwise fire `app_open` /
    /// `app_background` at the live endpoint on every `xcodebuild test` — noise
    /// that no `isPreRelease` flag makes worth sending.
    static var isSyntheticHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    // MARK: - The installed tracker

    /// The process-wide tracker seam — the app's one obvious analytics entry
    /// point, and the thing tests swap.
    ///
    /// **Why a seam and not initializer injection.** Analytics is emitted from
    /// ~33 call sites spread across SwiftUI views, view models, registries and
    /// the launch path; threading an `any UsageTracking` through every one of
    /// those initializers would churn a large amount of unrelated SwiftUI
    /// plumbing for no behavioral gain. So `Analytics` stays the single
    /// app-wide façade — every existing `Analytics.record(...)` call site is
    /// unchanged and simply forwards here — while the *implementation* behind
    /// it is now injectable. This mirrors `ScarfAnalytics.install` in
    /// `ScarfCore`, so both halves of the system are swapped the same way.
    ///
    /// **Default is production, not "uninstalled".** Unlike `ScarfCore`'s
    /// seam, which is `nil` until a host installs one, this defaults to
    /// ``StatsUsageTracker/shared`` so an event recorded before
    /// `scarfApp.init` runs cannot be silently dropped by install ordering.
    /// `StatsUsageTracker.shared` is itself inert under XCTest and previews
    /// (`isSyntheticHost`), so a test that installs nothing still sends
    /// nothing.
    ///
    /// Reads and writes both take `trackerLock`: `install` can legitimately be
    /// called from a test while another thread records, and an unsynchronized
    /// `nonisolated(unsafe) var` holding an existential would be a real data
    /// race, not a theoretical one.
    private static let trackerLock = NSLock()
    private nonisolated(unsafe) static var _tracker: any UsageTracking = StatsUsageTracker.shared

    /// The tracker every `Analytics` recording call routes through.
    ///
    /// **`private`, deliberately.** ``UsageTracking/record(rawName:props:)`` is
    /// a protocol requirement, so anything holding an `any UsageTracking` can
    /// name an event with a raw string. Keeping the *installed* tracker
    /// unreachable is what makes ``UsageEvent`` the only way an app-target call
    /// site can spell an event: ``CoreBridge`` is nested inside `Analytics` and
    /// so may read this, and tests never need it — they install a double with
    /// ``install(_:)`` and assert on the double itself.
    private static var tracker: any UsageTracking {
        trackerLock.lock(); defer { trackerLock.unlock() }
        return _tracker
    }

    /// Install a tracker. Called by tests (`CapturingUsageTracker`,
    /// `NoopUsageTracker`); the app never needs to call it because the default
    /// is already the production tracker. Pass `nil` to restore that default —
    /// what a test's `defer` should do.
    static func install(_ tracker: (any UsageTracking)?) {
        trackerLock.lock(); defer { trackerLock.unlock() }
        _tracker = tracker ?? StatsUsageTracker.shared
    }

    /// The production tracker's client, for Settings (consent toggles,
    /// enable/disable UI). Deliberately **not** routed through ``tracker``:
    /// the master switch and its persisted state belong to the real client,
    /// and a test double has no client to toggle. `nil` when analytics failed
    /// to configure.
    static var client: StatsClient? { StatsUsageTracker.shared.client }

    // MARK: - Recording

    /// The app-wide entry point. Non-suspending and fire-and-forget: the event
    /// is buffered in memory and drained onto the client actor asynchronously.
    ///
    /// ``UsageEvent`` is the *only* way an app-target call site can name an
    /// event: the raw string entry point lives on ``UsageTracking`` and is
    /// reachable only from ``CoreBridge``, so a new event has to be added to
    /// the closed enum — where the taxonomy, the prop vocabularies and the
    /// bucketing all live — rather than typed inline at a call site.
    nonisolated static func record(_ event: UsageEvent) {
        tracker.record(event)
    }

    // MARK: - Once-per-process recording

    /// Record `event` at most once per `key` per app *process*.
    ///
    /// The dedupe state lives on the installed tracker (see
    /// ``UsageTracking/recordOnce(_:key:)``), so a test that installs a fresh
    /// `CapturingUsageTracker` starts from a clean slate — which is why the
    /// old `resetRecordedOnceForTesting()` hook no longer exists.
    ///
    /// - Returns: `true` when the event was newly reported, `false` when the
    ///   key had already fired.
    @discardableResult
    nonisolated static func recordOnce(_ event: UsageEvent, key: String) -> Bool {
        tracker.recordOnce(event, key: key)
    }

    // MARK: - Shared prop helpers

    /// Coarse duration bucket — the only shape a duration may take in a prop.
    /// Defined once, in `ScarfCore`, so the events `ScarfCore` emits through
    /// the recorder seam and the events the app emits directly bucket
    /// identically. Phases 4/5 reuse this for turn and task durations.
    nonisolated static func durationBucket(_ seconds: TimeInterval) -> String {
        ScarfAnalytics.durationBucket(seconds)
    }

    /// Convenience for the common "one attempt, timed" shape.
    nonisolated static func durationBucket(since start: Date) -> String {
        durationBucket(Date().timeIntervalSince(start))
    }

    /// Coarse count bucket for tool calls in an agent turn. Same rationale
    /// and same single definition as ``durationBucket(_:)``: it lives in
    /// `ScarfCore` so the turn events the package emits through the recorder
    /// seam and anything the app buckets directly agree exactly.
    nonisolated static func toolCallCountBucket(_ count: Int) -> String {
        ScarfAnalytics.toolCallCountBucket(count)
    }

    /// Coarse count bucket for `launch_completed`'s `server_count_bucket` —
    /// how many servers (Local + every registered remote) exist at launch.
    /// Phase 5 only; unlike `durationBucket`/`toolCallCountBucket` this has
    /// no `ScarfCore` counterpart because nothing inside the package needs
    /// it. Buckets: `0`, `1`, `2_5`, `gt_5`. Negative input (impossible
    /// today) collapses into `"0"` rather than producing a surprise token.
    nonisolated static func serverCountBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case 1: return "1"
        case 2...5: return "2_5"
        default: return "gt_5"
        }
    }

    // MARK: - ScarfCore bridge

    /// Forwards `ScarfCore`'s analytics seam into this facade.
    ///
    /// `ScarfCore` is shared verbatim with the iOS app and links no analytics
    /// SDK; it only ever describes an event through
    /// `ScarfAnalyticsRecording`. This is the macOS implementation of that
    /// protocol, and the only place the two halves meet. iOS installs nothing,
    /// so every `ScarfAnalytics.record` there stays a nil check.
    ///
    /// **Why the seam stays stringly-typed** (the one exception to
    /// ``UsageEvent``'s closed contract). `ScarfCore` is compiled without any
    /// knowledge of the app target — the dependency runs app → package, never
    /// back — so it physically cannot name a `UsageEvent`, and giving the
    /// package its own parallel closed enum would fork the taxonomy across two
    /// declarations that can silently drift (the package would own
    /// `reconnect_succeeded`, the app `reconnect_attempted` for the wake
    /// sweep — the same event names on both sides of the seam). The package's
    /// surface is a *fixed, small* set — `connect_attempted`,
    /// `connection_degraded`, `reconnect_attempted/succeeded`,
    /// `circuit_breaker_opened/closed`, `agent_turn_completed/failed`,
    /// `session_resume_fallback`, `hermes_version_detected`,
    /// `hermes_probe_failed` — all emitted from a handful of call sites inside
    /// `ScarfCore` itself, none of them reachable from app code, and its
    /// `[String: String]` prop type already forbids anything but tokens. So the
    /// closure that matters — "no app-target call site can invent an event" —
    /// is achieved by keeping the installed ``tracker`` private above — the
    /// only handle through which the string `record` could be reached; the
    /// seam itself is left as-is rather than duplicated.
    private struct CoreBridge: ScarfAnalyticsRecording {
        func record(_ name: String, _ props: [String: String]) {
            // Through the installed tracker, not straight to the production
            // client: that way a test that installs a capture sees the events
            // `ScarfCore` emits as well as the app's own.
            Analytics.tracker.record(rawName: name, props: props)
        }
    }

    /// Called once from the app's launch path. Idempotent — installing the
    /// same stateless forwarder twice is harmless.
    nonisolated static func installCoreBridge() {
        ScarfAnalytics.install(CoreBridge())
    }


    // MARK: - Lifecycle

    /// Fire-and-forget passthrough for `NSApplication.didBecomeActive`.
    /// Lifecycle belongs to the real client (it drives session bookkeeping and
    /// the auto-events), so it bypasses the injectable tracker.
    nonisolated static func applicationDidBecomeActive() {
        StatsUsageTracker.shared.applicationDidBecomeActive()
    }

    /// Fire-and-forget passthrough for `NSApplication.didResignActive`.
    ///
    /// AppKit has no true "did enter background" — a macOS app that loses focus
    /// keeps running — so resigning active is the closest analogue, and is what
    /// the package's session-gap logic expects: it starts the inactivity timer
    /// rather than ending anything, and `didBecomeActive` resumes the same
    /// session if the user comes back inside the 30-minute macOS gap.
    nonisolated static func applicationDidEnterBackground() {
        StatsUsageTracker.shared.applicationDidEnterBackground()
    }

    // MARK: - first_run / launch_completed warm flag

    /// The pure decision logic behind `first_run`/`launch_completed`'s
    /// `warm` prop, pulled out of `scarfApp.init` so it's testable against
    /// a throwaway `UserDefaults` suite instead of either instantiating
    /// `ScarfApp` (which spins up real transports, registries, and
    /// background bootstrap tasks) or touching the app's real
    /// `UserDefaults.standard` from a test run.
    enum FirstRunMarker {
        /// Not `scarf.v27.snapshotCacheCleaned` or any other existing
        /// flag — this needs to mean specifically "has this install ever
        /// completed a launch", which nothing else already tracks.
        static let key = "com.scarf.analytics.hasLaunchedBefore"

        /// Reads the marker (`warm` = it was already set, i.e. this is
        /// *not* the first-ever launch), then sets it. Call exactly once
        /// per launch — a second call in the same process would report
        /// `warm == true` even on a genuine first run.
        nonisolated static func consumeAndMarkLaunched(defaults: UserDefaults) -> Bool {
            let warm = defaults.bool(forKey: key)
            defaults.set(true, forKey: key)
            return warm
        }
    }

    // MARK: - Opt-out

    /// Master switch. `false` stops collection and clears the queue.
    static func setEnabled(_ newValue: Bool) async {
        await StatsUsageTracker.shared.setEnabled(newValue)
    }

    /// `false` when analytics is switched off *or* unavailable.
    static var isEnabled: Bool {
        get async { await StatsUsageTracker.shared.isEnabled }
    }
}
