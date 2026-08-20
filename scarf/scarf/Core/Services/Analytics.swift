import Foundation
import ScarfCore
import Stats
import StatsCloudflare
import os

private nonisolated let logger = Logger(subsystem: "com.scarf", category: "Analytics")

/// App-wide analytics facade over a single `StatsClient` (swift-stats).
///
/// Everything here is `nonisolated` and fire-and-forget: `record(_:props:)` is
/// the one entry point the rest of the app uses, and it never suspends, never
/// touches disk on the caller's thread and never throws. If the client cannot
/// be constructed (a malformed endpoint is the only way that can happen) the
/// facade degrades to a no-op — analytics must never be able to fail a launch.
///
/// Props discipline (see documents/analytics/swift-stats-adoption-event-taxonomy.md):
/// snake_case event names, flat props, **no** free text, file paths, URLs,
/// hostnames or identifiers. Durations and counts go in as coarse bucket
/// strings. Nothing in this file reads user content, and callers must not pass
/// any.
///
/// `nonisolated` in full: the app target defaults new declarations to
/// `@MainActor`, and analytics must be callable from any isolation without a
/// hop — an inherited `@MainActor` on `sharedClient` makes `record()` from a
/// background context a hard error under the Swift 6 language mode.
nonisolated enum Analytics {
    /// Stable for the lifetime of the install-id scheme — changing it
    /// re-buckets every existing install into a new anonymous identity.
    private static let installIdSalt = "scarf-macos-2026"

    /// Project-scoped, append-only **write** key. It necessarily ships inside
    /// the binary: it can add events to this one project and can read nothing,
    /// which is the whole design of the key class (schema §2.4).
    private static let writeKey = "sk_stats_twAbMaSzUKQCa3w4EfgXRV2s6dnUZYVDGKN0mrNK0ks"

    private static let endpointString = "https://api.swiftstats.co"

    /// Debug builds and the decoupled dev copy installed by
    /// `scripts/build-detached.sh` (a Release build at
    /// `/Applications/scarf-dev.app`) are pre-release traffic and must not
    /// pollute production metrics. Only the bundle's own last path component is
    /// inspected, and only to produce a `Bool` — no path ever reaches a prop.
    private static var isPreRelease: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.bundleURL.lastPathComponent == "scarf-dev.app"
        #endif
    }

    /// The one place the app's stats configuration is defined. Exposed
    /// `internal` (not `private`) purely so tests can build the *same*
    /// configuration around an `InMemorySink` — the shipping call site is
    /// ``sharedClient`` below and nothing else may call this.
    ///
    /// Note what is *not* here: `screenMetrics` and `colorScheme` are left at
    /// their defaults rather than read from `NSScreen`/`NSApp`, which would
    /// mean touching AppKit on the main thread during client construction.
    ///
    /// Revisited for Phase 2: `StatsConfiguration.screenMetrics`/`colorScheme`
    /// are plain `var`s on a value type consumed once by `StatsClient.init`
    /// (`Packages` checkout: `Stats/StatsConfiguration.swift`,
    /// `Stats/StatsClient.swift`) — the actor keeps no public setter to patch
    /// either field in after construction, and `sharedClient` is a `static
    /// let` that can legitimately fire first from a background thread (the
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
    private static var isSyntheticHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Lazily built exactly once (static `let` = `swift_once`), on whichever
    /// thread records first. `StatsClient.init` allocates two actors and does
    /// no I/O — the queue file is opened on the `EventStore` actor on demand —
    /// so this is safe to trigger from the launch path.
    ///
    /// `nil` means "analytics is off for this process".
    private static let sharedClient: StatsClient? = {
        guard !isSyntheticHost else { return nil }
        do {
            let sink = CloudflareSink(
                endpoint: try CloudflareEndpoint(string: endpointString),
                writeKey: writeKey
            )
            return StatsClient(configuration: makeConfiguration(sink: sink, isPreRelease: isPreRelease))
        } catch {
            // Deliberately not fatal, and deliberately not logging `error`'s
            // description with `.public` — degrade to a no-op instead.
            logger.error("Analytics disabled: the stats client could not be configured")
            return nil
        }
    }()

    /// The client, for Settings (consent toggles, enable/disable UI). `nil`
    /// when analytics failed to configure.
    static var client: StatsClient? { sharedClient }

    // MARK: - Recording

    /// The app-wide entry point. Non-suspending and fire-and-forget: the event
    /// is buffered in memory and drained onto the client actor asynchronously.
    ///
    /// - Parameters:
    ///   - name: snake_case, `^[a-z][a-z0-9_]*$`, from the taxonomy.
    ///   - props: flat, bounded-cardinality values only. Never user text,
    ///     paths, URLs, hostnames or identifiers.
    nonisolated static func record(_ name: String, props: [String: StatsValue] = [:]) {
        sharedClient?.record(name, props: props)
    }

    // MARK: - Once-per-process recording

    /// Keys already reported by ``recordOnce(_:key:props:)`` in this process.
    ///
    /// Guarded by a plain lock rather than an actor or `@MainActor` because
    /// `record` itself is `nonisolated` and callers must not have to hop to
    /// report an event. `internal` (via the accessors below) so tests can
    /// assert on the dedupe without trying to intercept a `record` that is a
    /// no-op under XCTest (`isSyntheticHost`).
    private static let onceLock = NSLock()
    private nonisolated(unsafe) static var recordedOnceKeys: Set<String> = []

    /// Record `name` at most once per `key` per app *process*.
    ///
    /// Deliberately process-wide, not per-object: the callers that need this
    /// (notably `section_viewed`) live on objects that are rebuilt whenever
    /// the user opens a second window or switches server/profile, so an
    /// instance-scoped `Set` would re-report the same fact several times per
    /// session.
    ///
    /// - Returns: `true` when the event was newly reported, `false` when the
    ///   key had already fired.
    @discardableResult
    nonisolated static func recordOnce(_ name: String, key: String, props: [String: String] = [:]) -> Bool {
        onceLock.lock()
        let inserted = recordedOnceKeys.insert(key).inserted
        onceLock.unlock()
        guard inserted else { return false }
        record(name, props: props)
        return true
    }

    /// Test hook: the keys ``recordOnce(_:key:props:)`` has consumed.
    nonisolated static var recordedOnceKeysForTesting: Set<String> {
        onceLock.lock(); defer { onceLock.unlock() }
        return recordedOnceKeys
    }

    /// Test hook: forget every `recordOnce` key, so a test can exercise the
    /// dedupe from a clean slate.
    nonisolated static func resetRecordedOnceForTesting() {
        onceLock.lock(); defer { onceLock.unlock() }
        recordedOnceKeys = []
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
    private struct CoreBridge: ScarfAnalyticsRecording {
        func record(_ name: String, _ props: [String: String]) {
            Analytics.record(name, props: props.mapValues { StatsValue.string($0) })
        }
    }

    /// Called once from the app's launch path. Idempotent — installing the
    /// same stateless forwarder twice is harmless.
    nonisolated static func installCoreBridge() {
        ScarfAnalytics.install(CoreBridge())
    }

    /// String-only convenience. Almost every taxonomy prop is a
    /// bounded-cardinality token, and call sites shouldn't have to `import
    /// Stats` just to spell `.string(…)`.
    nonisolated static func record(_ name: String, props: [String: String]) {
        record(name, props: props.mapValues { StatsValue.string($0) })
    }

    // MARK: - Lifecycle

    /// Fire-and-forget passthrough for `NSApplication.didBecomeActive`.
    nonisolated static func applicationDidBecomeActive() {
        guard let client = sharedClient else { return }
        Task { await client.applicationDidBecomeActive() }
    }

    /// Fire-and-forget passthrough for `NSApplication.didResignActive`.
    ///
    /// AppKit has no true "did enter background" — a macOS app that loses focus
    /// keeps running — so resigning active is the closest analogue, and is what
    /// the package's session-gap logic expects: it starts the inactivity timer
    /// rather than ending anything, and `didBecomeActive` resumes the same
    /// session if the user comes back inside the 30-minute macOS gap.
    nonisolated static func applicationDidEnterBackground() {
        guard let client = sharedClient else { return }
        Task { await client.applicationDidEnterBackground() }
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
        await sharedClient?.setEnabled(newValue)
    }

    /// `false` when analytics is switched off *or* unavailable.
    static var isEnabled: Bool {
        get async { await sharedClient?.isEnabled ?? false }
    }
}
