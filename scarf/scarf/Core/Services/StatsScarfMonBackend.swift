import Foundation
import ScarfCore
import os

/// Bridges `ScarfMon` performance samples into analytics as `perf_measure`
/// events — thresholded so only genuinely slow work is reported.
///
/// **Only emits over-budget measures.** Every category has a budget
/// (`Self.budgetNanos`); a sample below its category's budget is dropped
/// silently. This keeps the event volume tiny (perf problems, not perf
/// telemetry) and keeps `ScarfMon.measure`'s hot path cheap for the common
/// "well within budget" case — the comparison itself is a single integer
/// compare, no allocation.
///
/// **Rate-limited per category.** Even a persistently slow category (e.g. a
/// degraded remote host making every `transport` call slow) stops emitting
/// after ``perCategoryCap`` events for the life of the process, so a bad
/// session can't flood the analytics backend.
///
/// **Privacy.** `ScarfMon.Sample.name` is a `StaticString` captured at each
/// instrumented call site and is never read here — only `category` (a
/// closed `String` enum) and the coarse `duration_bucket` reach
/// `Analytics.record`. See
/// `documents/analytics/swift-stats-adoption-event-taxonomy.md` §Diagnostics.
///
/// Lives in the macOS app target (not `ScarfCore`) because it calls
/// `Analytics.record`, and `ScarfCore` must never import `Stats`.
final class StatsScarfMonBackend: ScarfMonBackend {
    /// Emissions per category are capped at this many for the process
    /// lifetime, bounding worst-case event volume from one degraded
    /// category to 8 categories × 30 = 240 events per launch.
    static let perCategoryCap = 30

    /// Per-category over-budget thresholds, in nanoseconds. A sample at or
    /// under its category's budget is not "slow" and is dropped.
    private static let budgetNanos: [ScarfMon.Category: UInt64] = [
        .chatRender: 100_000_000,   // 100ms — a single chat re-render tick
        .chatStream: 250_000_000,   // 250ms — one streamed-token processing step
        .sessionLoad: 2_000_000_000, // 2s — full session/history load
        .transport: 5_000_000_000,  // 5s — one SSH/local transport round trip
        .sqlite: 250_000_000,       // 250ms — one query
        .diskIO: 500_000_000,       // 500ms — one read/write
        .render: 100_000_000,       // 100ms — one UI render pass
        .other: 1_000_000_000       // 1s — catch-all
    ]

    private let lock = OSAllocatedUnfairLock<[ScarfMon.Category: Int]>(initialState: [:])

    func record(_ sample: ScarfMon.Sample) {
        guard let event = Self.decide(sample, cap: Self.perCategoryCap, lock: lock) else { return }
        Analytics.record(event)
    }

    /// Pure threshold + rate-limit decision, split out of `record(_:)` so
    /// it's testable without a live `Analytics`/`Stats` sink (which no-ops
    /// under XCTest — see `AnalyticsFeatureUsageEventsTests`). Returns the
    /// exact `UsageEvent` `record(_:)` would send, or `nil` if the sample should
    /// be dropped (under budget, not a timed interval, or the category's
    /// cap for this process is already spent).
    ///
    /// `nonmutating` on the counts happens through the passed-in lock
    /// rather than instance state so tests can point two calls at the same
    /// counter without standing up a full backend instance.
    static func decide(
        _ sample: ScarfMon.Sample,
        cap: Int,
        lock: OSAllocatedUnfairLock<[ScarfMon.Category: Int]>
    ) -> UsageEvent? {
        // Events (non-interval samples) carry no duration to threshold
        // against; only timed `measure`/`measureAsync` intervals apply.
        guard sample.kind == .interval else { return nil }
        guard let budget = budgetNanos[sample.category], sample.durationNanos > budget else { return nil }

        let allowed: Bool = lock.withLock { counts in
            let count = counts[sample.category, default: 0]
            guard count < cap else { return false }
            counts[sample.category] = count + 1
            return true
        }
        guard allowed else { return nil }

        return .perfMeasure(
            category: sample.category,
            durationBucket: .init(seconds: TimeInterval(sample.durationNanos) / 1_000_000_000)
        )
    }
}

/// App-target wrapper around `ScarfMonBoot.configure(mode:)` that keeps the
/// Stats backend composed alongside whatever `ScarfCore` installs.
///
/// `ScarfMonBoot.configure` replaces the entire backend set (it's shared
/// with iOS, which has no Stats backend to preserve), so both call sites in
/// this target — launch and the Settings → Diagnostics mode picker — must
/// go through here instead of calling `ScarfMonBoot.configure`/`setMode`
/// directly, or a mode change would silently drop `perf_measure` reporting.
enum AppScarfMonBoot {
    /// Install the backend set for `mode`, then append the Stats backend —
    /// except in `.off`, where `ScarfMon.isActive` is false and no sample
    /// would ever reach it anyway, so there's nothing to compose.
    @discardableResult
    static func configure(mode: ScarfMonBoot.Mode) -> ScarfMonRingBuffer? {
        let ring = ScarfMonBoot.configure(mode: mode)
        guard mode != .off else { return ring }
        ScarfMon.install(ScarfMon.currentBackends + [StatsScarfMonBackend()])
        return ring
    }

    /// Persist a new mode and reinstall the composed backend set. Mirrors
    /// `ScarfMonBoot.setMode`.
    static func setMode(_ mode: ScarfMonBoot.Mode, _ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: ScarfMonBoot.userDefaultsKey)
        configure(mode: mode)
    }
}
