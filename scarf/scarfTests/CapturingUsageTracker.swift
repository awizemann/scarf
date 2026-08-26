import Foundation
import Stats
@testable import scarf

/// A ``UsageTracking`` that keeps every event it is handed, so an app-target
/// test can assert on what the app *emitted* rather than only on the pure
/// decision logic behind an emission.
///
/// Before the tracker seam existed this was impossible: `Analytics.record`
/// funnelled into a `StatsClient` that is deliberately `nil` under XCTest
/// (`isSyntheticHost`), so tests could only re-derive an event and check its
/// shape, never observe that a real code path actually sent it.
///
/// Thread-safe (`record` is `nonisolated` and can arrive from any thread), and
/// its `recordOnce` dedupe is per instance: **a fresh tracker per test is a
/// clean dedupe slate**, which is what replaced the old
/// `Analytics.resetRecordedOnceForTesting()` hook.
///
/// Because `Analytics.install` writes a process-wide seam, any suite that
/// installs one must be `.serialized` (and restore with
/// `defer { Analytics.install(nil) }`) — the same discipline
/// `ScarfAnalyticsSeamTests` uses for `ScarfAnalytics.install`.
final class CapturingUsageTracker: UsageTracking, @unchecked Sendable {
    /// One captured emission: either a typed ``UsageEvent`` or a raw
    /// `ScarfCore`-seam event, normalized to name + string props.
    struct Captured: Sendable, Equatable {
        var name: String
        var props: [String: String]
        /// `true` when it came through `ScarfCore`'s stringly-typed seam.
        var isRaw: Bool
    }

    private let lock = NSLock()
    private var _captured: [Captured] = []
    private let once = UsageOnceKeys()

    var captured: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    /// Names in emission order — the usual assertion target.
    var names: [String] { captured.map(\.name) }

    /// Props of the first capture named `name`, if any.
    func props(of name: String) -> [String: String]? {
        captured.first { $0.name == name }?.props
    }

    func record(_ event: UsageEvent) {
        append(Captured(name: event.name, props: Self.tokens(event.props), isRaw: false))
    }

    func record(rawName name: String, props: [String: String]) {
        append(Captured(name: name, props: props, isRaw: true))
    }

    @discardableResult
    func recordOnce(_ event: UsageEvent, key: String) -> Bool {
        guard once.claim(key) else { return false }
        record(event)
        return true
    }

    private func append(_ item: Captured) {
        lock.lock(); defer { lock.unlock() }
        _captured.append(item)
    }

    /// `StatsValue` has no test-friendly accessor, so props are flattened
    /// through the same token spelling the wire uses.
    private static func tokens(_ props: [String: StatsValue]) -> [String: String] {
        props.mapValues(\.usageEventToken)
    }
}
