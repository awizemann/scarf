import Foundation
import ScarfCore
import Stats
import StatsCloudflare
import os

private nonisolated let trackerLogger = Logger(subsystem: "com.scarf", category: "Analytics")

/// The injectable sink for product-analytics events.
///
/// Everything here is `nonisolated`, non-suspending and fire-and-forget: an
/// implementation must never block, throw or hop the caller's isolation, and
/// must be safe to call from any thread (hence `Sendable`). Analytics must
/// never be able to fail — or even slow — a launch.
///
/// ``UsageEvent`` is the only way an app-target call site can name an event;
/// ``record(rawName:props:)`` exists solely for `ScarfCore`'s string-based
/// `ScarfAnalyticsRecording` seam, which is compiled without any knowledge of
/// this target and so physically cannot name a `UsageEvent` (see
/// `Analytics.CoreBridge`). Routing that seam through the *same* tracker means
/// a test can capture package-emitted events too.
nonisolated protocol UsageTracking: Sendable {
    /// Record one typed event.
    func record(_ event: UsageEvent)

    /// Record `event` at most once per `key`, for the life of this tracker
    /// instance.
    ///
    /// The dedupe is deliberately tracker-wide rather than per-object: the
    /// callers that need it (notably `section_viewed`) live on objects that
    /// are rebuilt whenever the user opens a second window or switches
    /// server/profile, so an instance-scoped `Set` would re-report the same
    /// fact several times per session. In the shipping app one tracker lives
    /// for the whole process, so "per tracker" *is* "per process"; in tests a
    /// fresh ``CapturingUsageTracker`` per test gives clean dedupe state —
    /// which is why the old `Analytics.resetRecordedOnceForTesting()` hook is
    /// gone.
    ///
    /// - Returns: `true` when the event was newly reported, `false` when the
    ///   key had already fired.
    @discardableResult
    func recordOnce(_ event: UsageEvent, key: String) -> Bool

    /// The raw, stringly-typed entry point. **Only** `ScarfCore`'s seam may
    /// use it; app-target call sites go through ``record(_:)``.
    ///
    /// - Parameters:
    ///   - name: snake_case, `^[a-z][a-z0-9_]*$`, from the taxonomy.
    ///   - props: flat, bounded-cardinality tokens only. Never user text,
    ///     paths, URLs, hostnames or identifiers.
    func record(rawName name: String, props: [String: String])
}

/// Thread-safe `recordOnce` key set, shared by every tracker implementation so
/// the dedupe semantics can't drift between production and test doubles.
///
/// A plain lock rather than an actor: `record` is `nonisolated` and callers
/// must not have to hop (or `await`) to report an event.
nonisolated final class UsageOnceKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    /// - Returns: `true` the first time `key` is seen, `false` afterwards.
    func claim(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys.insert(key).inserted
    }

    var claimed: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return keys
    }
}

/// The production tracker: owns the app's single `StatsClient` and everything
/// that configures it.
///
/// If the client cannot be constructed — a synthetic host (XCTest / SwiftUI
/// previews), a missing or unexpanded write key, a malformed endpoint — every
/// method degrades to a no-op *except* the `recordOnce` dedupe, which still
/// runs so the return value keeps its meaning.
nonisolated final class StatsUsageTracker: UsageTracking {
    /// The app's one production tracker. A `static let` so the underlying
    /// `StatsClient` is still built exactly once (`swift_once`), lazily, on
    /// whichever thread records first.
    static let shared = StatsUsageTracker()

    private let once = UsageOnceKeys()

    /// `nil` means "analytics is off for this process".
    ///
    /// `StatsClient.init` allocates two actors and does no I/O — the queue
    /// file is opened on the `EventStore` actor on demand — so building this
    /// lazily from the launch path is safe.
    let client: StatsClient?

    init(client: StatsClient? = StatsUsageTracker.makeSharedClient()) {
        self.client = client
    }

    /// Builds the shipping client, or `nil` on any degrade path.
    static func makeSharedClient() -> StatsClient? {
        guard !Analytics.isSyntheticHost else { return nil }
        // Same degrade-to-no-op path as a malformed endpoint below. The key's
        // value is never logged — only the fact that it was unusable.
        guard let writeKey = Analytics.writeKey else {
            trackerLogger.error("Analytics disabled: no usable stats write key in the bundle")
            return nil
        }
        do {
            let sink = CloudflareSink(
                endpoint: try CloudflareEndpoint(string: Analytics.endpointString),
                writeKey: writeKey
            )
            return StatsClient(configuration: Analytics.makeConfiguration(
                sink: sink,
                isPreRelease: Analytics.isPreRelease
            ))
        } catch {
            // Deliberately not fatal, and deliberately not logging `error`'s
            // description with `.public` — degrade to a no-op instead.
            trackerLogger.error("Analytics disabled: the stats client could not be configured")
            return nil
        }
    }

    func record(_ event: UsageEvent) {
        client?.record(event.name, props: event.props)
    }

    func record(rawName name: String, props: [String: String]) {
        client?.record(name, props: props.mapValues { StatsValue.string($0) })
    }

    @discardableResult
    func recordOnce(_ event: UsageEvent, key: String) -> Bool {
        guard once.claim(key) else { return false }
        record(event)
        return true
    }

    // MARK: - Lifecycle & opt-out (Settings surface)

    /// Fire-and-forget passthrough for `NSApplication.didBecomeActive`.
    func applicationDidBecomeActive() {
        guard let client else { return }
        Task { await client.applicationDidBecomeActive() }
    }

    /// Fire-and-forget passthrough for `NSApplication.didResignActive`.
    ///
    /// AppKit has no true "did enter background" — a macOS app that loses focus
    /// keeps running — so resigning active is the closest analogue, and is what
    /// the package's session-gap logic expects: it starts the inactivity timer
    /// rather than ending anything, and `didBecomeActive` resumes the same
    /// session if the user comes back inside the 30-minute macOS gap.
    func applicationDidEnterBackground() {
        guard let client else { return }
        Task { await client.applicationDidEnterBackground() }
    }

    /// Master switch. `false` stops collection and clears the queue.
    func setEnabled(_ newValue: Bool) async {
        await client?.setEnabled(newValue)
    }

    /// `false` when analytics is switched off *or* unavailable.
    var isEnabled: Bool {
        get async { await client?.isEnabled ?? false }
    }
}

/// A tracker that reports nothing.
///
/// The default for hosts that must emit no traffic at all (previews, ad-hoc
/// harnesses) and the safe thing to install when a test wants the *absence* of
/// analytics rather than a capture.
///
/// ``recordOnce(_:key:)`` still runs the real dedupe and returns the real
/// answer (`true` the first time a key is seen, `false` after) rather than a
/// constant: callers are allowed to branch on that return value, and a tracker
/// that always answered the same way would change their behavior, not just
/// silence their telemetry.
nonisolated final class NoopUsageTracker: UsageTracking {
    private let once = UsageOnceKeys()

    init() {}

    func record(_ event: UsageEvent) {}
    func record(rawName name: String, props: [String: String]) {}

    @discardableResult
    func recordOnce(_ event: UsageEvent, key: String) -> Bool {
        once.claim(key)
    }
}
