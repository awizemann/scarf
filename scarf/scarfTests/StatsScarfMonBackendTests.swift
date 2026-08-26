import Foundation
import Testing
import ScarfCore
import os
@testable import scarf

/// Phase 6 (ScarfMon → Stats bridge). Most of these assert on the pure
/// threshold + rate-limit decision (`StatsScarfMonBackend.decide`); the
/// end-to-end suite at the bottom installs a `CapturingUsageTracker` through
/// the `Analytics` tracker seam and asserts on what `record(_:)` — the real
/// `ScarfMonBackend` entry point — actually emitted, which was impossible
/// while `Analytics.record` funnelled into a `StatsClient` that is `nil`
/// under XCTest.
@Suite("StatsScarfMonBackend decision logic")
struct StatsScarfMonBackendTests {
    private func sample(
        category: ScarfMon.Category,
        durationNanos: UInt64,
        kind: ScarfMon.Sample.Kind = .interval
    ) -> ScarfMon.Sample {
        ScarfMon.Sample(
            category: category,
            name: "test",
            kind: kind,
            timestamp: Date(),
            durationNanos: durationNanos,
            count: 1,
            bytes: nil
        )
    }

    @Test("a measure over its category's budget emits exactly one perf_measure")
    func overBudgetEmitsOnce() {
        let lock = OSAllocatedUnfairLock<[ScarfMon.Category: Int]>(initialState: [:])
        // chatRender budget is 100ms; 150ms is over.
        let slow = sample(category: .chatRender, durationNanos: 150_000_000)

        let first = StatsScarfMonBackend.decide(slow, cap: 30, lock: lock)
        #expect(first != nil)
        #expect(first?.props["category"]?.usageEventToken == "chatRender")

        // A second, independent over-budget sample in the SAME category
        // increments the same rate-limit counter but is still its own,
        // separately-allowed emission — "exactly one" is about one event
        // per over-budget sample, not a dedupe across samples.
        let second = StatsScarfMonBackend.decide(slow, cap: 30, lock: lock)
        #expect(second != nil)
    }

    @Test("a fast measure under budget emits nothing")
    func underBudgetEmitsNone() {
        let lock = OSAllocatedUnfairLock<[ScarfMon.Category: Int]>(initialState: [:])
        // chatRender budget is 100ms; 10ms is well under.
        let fast = sample(category: .chatRender, durationNanos: 10_000_000)
        #expect(StatsScarfMonBackend.decide(fast, cap: 30, lock: lock) == nil)
    }

    @Test("a measure exactly at budget emits nothing (threshold is strictly over)")
    func atBudgetEmitsNone() {
        let lock = OSAllocatedUnfairLock<[ScarfMon.Category: Int]>(initialState: [:])
        let atBudget = sample(category: .chatRender, durationNanos: 100_000_000)
        #expect(StatsScarfMonBackend.decide(atBudget, cap: 30, lock: lock) == nil)
    }

    @Test("a non-interval event sample never emits, even if it carries a large duration field")
    func eventKindNeverEmits() {
        let lock = OSAllocatedUnfairLock<[ScarfMon.Category: Int]>(initialState: [:])
        let event = sample(category: .transport, durationNanos: 999_000_000_000, kind: .event)
        #expect(StatsScarfMonBackend.decide(event, cap: 30, lock: lock) == nil)
    }

    @Test("the rate cap stops emission after the configured number of events per category")
    func rateCapStopsEmission() {
        let lock = OSAllocatedUnfairLock<[ScarfMon.Category: Int]>(initialState: [:])
        let slow = sample(category: .sqlite, durationNanos: 500_000_000) // over sqlite's 250ms budget
        let cap = 3

        var emitted = 0
        for _ in 0..<(cap + 5) {
            if StatsScarfMonBackend.decide(slow, cap: cap, lock: lock) != nil {
                emitted += 1
            }
        }
        #expect(emitted == cap)

        // Further calls stay capped — the counter doesn't wrap or reset.
        #expect(StatsScarfMonBackend.decide(slow, cap: cap, lock: lock) == nil)
    }

    @Test("categories rate-limit independently")
    func categoriesAreIndependent() {
        let lock = OSAllocatedUnfairLock<[ScarfMon.Category: Int]>(initialState: [:])
        let cap = 1
        let sqliteSlow = sample(category: .sqlite, durationNanos: 500_000_000)
        let transportSlow = sample(category: .transport, durationNanos: 6_000_000_000)

        #expect(StatsScarfMonBackend.decide(sqliteSlow, cap: cap, lock: lock) != nil)
        #expect(StatsScarfMonBackend.decide(sqliteSlow, cap: cap, lock: lock) == nil)
        // transport's counter is untouched by sqlite's cap being spent.
        #expect(StatsScarfMonBackend.decide(transportSlow, cap: cap, lock: lock) != nil)
    }

    @Test("emitted props never carry the measure name — only category and bucket")
    func propsNeverCarryMeasureName() {
        let lock = OSAllocatedUnfairLock<[ScarfMon.Category: Int]>(initialState: [:])
        let slow = sample(category: .render, durationNanos: 400_000_000)
        let event = StatsScarfMonBackend.decide(slow, cap: 30, lock: lock)
        #expect(event?.name == "perf_measure")
        #expect(event?.props.keys.sorted() == ["category", "duration_bucket"])
    }
}

/// The emission path itself, not just the decision behind it.
///
/// `.serialized`, and nested inside `AnalyticsConnectionEventsTests` for the
/// same reason `AnalyticsChatEventsTests` and
/// `AnalyticsFeatureUsageEventsTests` are: `Analytics.install` writes a
/// *process-wide* seam, and `.serialized` only serializes a suite and its
/// subgroups — never siblings. As a file-scope suite this raced
/// `AnalyticsFeatureUsageEventsTests`, which installs into the same seam and
/// restores it in a `defer`. One serialized parent for every seam-installing
/// app-target suite is what makes the seam safe.
extension AnalyticsConnectionEventsTests {

@Suite("StatsScarfMonBackend emission", .serialized)
struct StatsScarfMonBackendEmissionTests {
    private func sample(
        category: ScarfMon.Category,
        durationNanos: UInt64,
        kind: ScarfMon.Sample.Kind = .interval
    ) -> ScarfMon.Sample {
        ScarfMon.Sample(
            category: category,
            name: "secret-measure-name",
            kind: kind,
            timestamp: Date(),
            durationNanos: durationNanos,
            count: 1,
            bytes: nil
        )
    }

    @Test("an over-budget sample emits perf_measure; an under-budget one emits nothing")
    func emitsOnlyOverBudget() {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let backend = StatsScarfMonBackend()
        backend.record(sample(category: .chatRender, durationNanos: 10_000_000))   // under 100ms
        #expect(tracker.captured.isEmpty)

        backend.record(sample(category: .chatRender, durationNanos: 2_500_000_000)) // over
        #expect(tracker.names == ["perf_measure"])
        // The `StaticString` measure name must never reach a prop.
        #expect(tracker.props(of: "perf_measure") == [
            "category": "chatRender",
            "duration_bucket": "1_5s",
        ])
    }

    @Test("the per-category cap bounds what actually reaches the tracker")
    func capBoundsEmission() {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }

        let backend = StatsScarfMonBackend()
        let slow = sample(category: .sqlite, durationNanos: 500_000_000)
        for _ in 0..<(StatsScarfMonBackend.perCategoryCap + 10) { backend.record(slow) }
        #expect(tracker.captured.count == StatsScarfMonBackend.perCategoryCap)

        // A different category has its own untouched budget.
        backend.record(sample(category: .transport, durationNanos: 6_000_000_000))
        #expect(tracker.captured.count == StatsScarfMonBackend.perCategoryCap + 1)
    }
}

}
