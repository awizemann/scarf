import Foundation
import Testing
import ScarfCore
import os
@testable import scarf

/// Phase 6 (ScarfMon → Stats bridge). `Analytics.record` no-ops under
/// XCTest (`isSyntheticHost`), so — same discipline as
/// `AnalyticsFeatureUsageEventsTests` — these assert on the pure
/// threshold + rate-limit decision (`StatsScarfMonBackend.decide`) rather
/// than on delivered events.
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
        #expect(first?["category"] == "chatRender")

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
        let props = StatsScarfMonBackend.decide(slow, cap: 30, lock: lock)
        #expect(props?.keys.sorted() == ["category", "duration_bucket"])
    }
}
