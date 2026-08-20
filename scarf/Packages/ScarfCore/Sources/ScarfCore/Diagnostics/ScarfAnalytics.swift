import Foundation

/// The one seam through which `ScarfCore` reports product-analytics events.
///
/// **Why a protocol instead of calling the analytics client.** `ScarfCore` is
/// shared verbatim by the macOS and iOS apps and must stay free of any
/// analytics SDK: the package links no `Stats` product, and adding one would
/// force the dependency (and its platform floor) onto every consumer. So the
/// package only ever *describes* an event; whoever hosts it decides what that
/// means. The macOS app installs a forwarder into `Analytics.record` at
/// launch. iOS installs nothing, so every call below is a nil check —
/// behavior there is bit-for-bit unchanged.
///
/// **Privacy.** `props` is `[String: String]` on purpose: bounded-cardinality
/// enum-ish tokens only. Never a hostname, username, path, error message, or
/// any other user text — the same rule the app-side facade documents. Durations
/// go through ``ScarfAnalytics/durationBucket(_:)`` rather than as numbers.
public protocol ScarfAnalyticsRecording: Sendable {
    /// Fire-and-forget. Implementations must not suspend, throw, or block the
    /// caller — `ScarfCore` calls this from hot-ish paths (transport state
    /// transitions) and from `@MainActor` view models.
    func record(_ name: String, _ props: [String: String])
}

/// Process-wide, optional recorder plus the shared bucketing helpers.
public enum ScarfAnalytics {
    private static let lock = NSLock()
    // Guarded by `lock` on every read and write; the property itself is never
    // touched directly from outside this type.
    nonisolated(unsafe) private static var _recorder: (any ScarfAnalyticsRecording)?

    /// Install (or, with `nil`, remove) the host app's forwarder. Called once
    /// from the macOS app's launch path; tests install a capture and clear it
    /// again in a `defer`.
    public static func install(_ recorder: (any ScarfAnalyticsRecording)?) {
        lock.lock(); defer { lock.unlock() }
        _recorder = recorder
    }

    /// The installed recorder, or `nil` when the host wired none (iOS, tests,
    /// and any target that never calls ``install(_:)``).
    public static var recorder: (any ScarfAnalyticsRecording)? {
        lock.lock(); defer { lock.unlock() }
        return _recorder
    }

    /// Record an event if — and only if — a host installed a recorder.
    /// A no-op otherwise, which is the default everywhere.
    public static func record(_ name: String, _ props: [String: String] = [:]) {
        recorder?.record(name, props)
    }

    /// Coarse duration bucket. The *only* shape a duration is allowed to take
    /// in a prop: exact millisecond timings are both high-cardinality and, on
    /// a connection path, weakly fingerprinting. Shared by `ScarfCore` and the
    /// app-side facade so both sides bucket identically.
    ///
    /// Edges are inclusive-below / exclusive-above: 1.0 → `"1_5s"`,
    /// 5.0 → `"5_15s"`, 60.0 → `"gt_60s"`. Negative input (a clock that
    /// stepped backwards) falls into the smallest bucket rather than
    /// producing a surprise value.
    public static func durationBucket(_ seconds: TimeInterval) -> String {
        // Every comparison against NaN is false, so NaN lands in the smallest
        // bucket and +∞ in the largest — no stray token either way.
        guard seconds >= 1 else { return "lt_1s" }
        if seconds < 5 { return "1_5s" }
        if seconds < 15 { return "5_15s" }
        if seconds < 60 { return "15_60s" }
        return "gt_60s"
    }
}
