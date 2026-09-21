#if canImport(SQLite3)

import Foundation
import Testing
@testable import ScarfCore

/// `InsightsViewModel.unknownCostSessionCount` is what makes the Insights
/// "Total Cost" card admit it is partial — the card shows the em dash when
/// nothing is known and a "partial" tooltip whenever this is greater than
/// zero. It shipped with no test at all, so nothing pinned that it counts the
/// sessions Hermes never priced.
///
/// These drive `computeAggregates()` over a hand-built `sessions` array. The
/// aggregation is pure, so no state.db is opened; the view model is built
/// against a temp Hermes home so nothing touches the developer's real one.
/// Deliberately NOT `@MainActor` and it never shells out — see the ScarfCore
/// note on tests that hog the main thread or a pool thread.
@Suite("InsightsViewModel — cost aggregates")
struct InsightsAggregatesTests {

    // MARK: - Fixtures

    static func viewModel() -> InsightsViewModel {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-insights-tests-\(UUID().uuidString)", isDirectory: true)
        return InsightsViewModel(context: .local(home: home))
    }

    static func session(
        id: String,
        actual: Double? = nil,
        estimated: Double? = nil,
        status: String?,
        hasColumn: Bool
    ) -> HermesSession {
        HermesSession(
            id: id, source: "acp", userId: nil, model: "fable:free", title: nil,
            parentSessionId: nil, startedAt: nil, endedAt: nil, endReason: nil,
            messageCount: 0, toolCallCount: 0, inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, estimatedCostUSD: estimated,
            reasoningTokens: 0, actualCostUSD: actual, costStatus: status,
            billingProvider: nil, hasCostStatusColumn: hasColumn
        )
    }

    // MARK: - Tests

    /// An explicit `"unknown"` status is counted, a priced session is not,
    /// and a subscription-included zero is a REAL zero so it is not counted
    /// either — the total that includes it is complete.
    @Test("only the sessions Hermes never priced are counted as unknown")
    func countsOnlyUnpricedSessions() {
        let vm = Self.viewModel()
        vm.sessions = [
            Self.session(id: "a", estimated: 0.0, status: "unknown", hasColumn: true),
            Self.session(id: "b", estimated: 0.25, status: "estimated", hasColumn: true),
            Self.session(id: "c", estimated: 0.0, status: "included", hasColumn: true),
            Self.session(id: "d", actual: 0.5, status: "actual", hasColumn: true),
        ]
        vm.computeAggregates()

        #expect(vm.unknownCostSessionCount == 1, "only the 'unknown' row is unpriced")
        // The sum is unchanged by the count — unknowns contribute their
        // stored placeholder zero, which is exactly why the count is needed.
        #expect(vm.totalCost == 0.75)
    }

    /// The regression this branch fixes, at the Insights layer. A session
    /// whose `cost_status` is NULL on a host that HAS the column was
    /// invisible to this count, so a host whose sessions were all in that
    /// state rendered a flat, confident `$0.00` with no partial marker.
    @Test("a NULL cost_status on a v0.7+ host counts as unknown")
    func nullStatusOnAModernHostIsCounted() {
        let vm = Self.viewModel()
        vm.sessions = [
            Self.session(id: "never-priced", status: nil, hasColumn: true),
            Self.session(id: "null-with-zero", estimated: 0.0, status: nil, hasColumn: true),
            Self.session(id: "priced", estimated: 0.25, status: "estimated", hasColumn: true),
        ]
        vm.computeAggregates()

        #expect(vm.unknownCostSessionCount == 2,
                "both NULL-status rows are sessions Hermes never priced")
        #expect(vm.totalCost == 0.25)
    }

    /// Charter C1. On a host BELOW the v0.7 schema there is no `cost_status`
    /// column, every session degrades to `.legacy`, and the count must stay
    /// zero so the Total Cost card renders exactly as it did in the previous
    /// Scarf release — no em dash, no partial tooltip.
    @Test("a host with no cost_status column contributes no unknowns (C1)")
    func anOlderHostCountsNoUnknowns() {
        let vm = Self.viewModel()
        vm.sessions = [
            Self.session(id: "a", status: nil, hasColumn: false),
            Self.session(id: "b", estimated: 0.0, status: nil, hasColumn: false),
            Self.session(id: "c", estimated: 0.25, status: nil, hasColumn: false),
        ]
        vm.computeAggregates()

        #expect(vm.unknownCostSessionCount == 0)
        #expect(vm.totalCost == 0.25)
    }

    /// The card's "nothing is known at all" state: every session unknown, so
    /// the sum is zero AND the count is positive — the pair `InsightsView`
    /// reads to show the em dash instead of a fabricated `$0.00`.
    @Test("an all-unknown period yields a zero sum with a positive unknown count")
    func allUnknownDrivesTheEmDashState() {
        let vm = Self.viewModel()
        vm.sessions = [
            Self.session(id: "a", estimated: 0.0, status: "unknown", hasColumn: true),
            Self.session(id: "b", status: nil, hasColumn: true),
        ]
        vm.computeAggregates()

        #expect(vm.totalCost == 0)
        #expect(vm.unknownCostSessionCount == 2)
    }

    @Test("no sessions means no unknowns")
    func emptyPeriodIsNotPartial() {
        let vm = Self.viewModel()
        vm.sessions = []
        vm.computeAggregates()

        #expect(vm.unknownCostSessionCount == 0)
        #expect(vm.totalCost == 0)
    }
}

#endif
