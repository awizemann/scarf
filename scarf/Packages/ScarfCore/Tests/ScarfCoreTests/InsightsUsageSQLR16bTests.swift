#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// R16b — Insights' usage sums are aggregated in SQL, uncapped.
///
/// The usage population used to be fetched row by row and capped at
/// `QueryDefaults.periodSessionLimit` (2000), so "All Time" spend on a busy
/// host silently stopped at the newest 2000 session rows (sooner with
/// delegates, which are session rows too). `hermes insights` has no cap
/// (`InsightsEngine._GET_SESSIONS_ALL`, agent/insights.py:92-96 @
/// v2026.9.24). These run against Hermes's own v0.21.5 DDL.
@Suite struct InsightsUsageSQLR16bTests {

    private func makeHome(seed: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r16b-insights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = home.appendingPathComponent("state.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let sql = HermesV0215StateDDL.schemaSQL + HermesV0215StateDDL.ftsSQL + seed
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture failed: \(msg)")
        }
        return home
    }

    /// 2,100 session rows — past the old 2000-row cap. Every one is summed.
    @Test func usageSumsAreNotCappedAtThePeriodSessionLimit() async throws {
        let total = QueryDefaults.periodSessionLimit + 100
        let seed = """
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(total))
            INSERT INTO sessions (id, source, model, started_at, message_count, tool_call_count,
                input_tokens, output_tokens, estimated_cost_usd, cost_status)
            SELECT 's' || i, CASE WHEN i % 2 = 0 THEN 'cli' ELSE 'acp' END, 'm', 1699000000 + i,
                   2, 1, 10, 1, 0.01, 'estimated' FROM n;
            """
        let home = try makeHome(seed: seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let usage = await service.fetchUsageAggregatesInPeriod(since: Date(timeIntervalSince1970: 0))
        await service.close()

        #expect(usage.reduce(0) { $0 + $1.sessions } == total)
        #expect(usage.reduce(0) { $0 + $1.messages } == total * 2)
        #expect(usage.reduce(0) { $0 + $1.inputTokens } == total * 10)
        #expect(abs(usage.reduce(0.0) { $0 + $1.costUSD } - Double(total) * 0.01) < 1e-6)
        // Grouped, not per row: one row per (model, source, cost state).
        #expect(usage.count == 2)

        // And the view model's totals follow the uncapped sums.
        let vm = InsightsViewModel(context: .local(home: home))
        vm.usageAggregates = usage
        vm.computeAggregates()
        #expect(vm.usageSessionCount == total)
        #expect(vm.totalInputTokens == total * 10)
    }

    /// The SQL grouping applies the same cost rule `SessionCostDisplay`
    /// applies to one session: for every mix of actual / estimated / status
    /// the unknown count and the cost sum equal the per-session answers.
    @Test func sqlCostRuleMatchesThePerSessionRule() async throws {
        struct Case { let id: String; let actual: Double?; let estimated: Double?; let status: String? }
        let cases: [Case] = [
            .init(id: "unknown-zero", actual: nil, estimated: 0.0, status: "unknown"),
            .init(id: "estimated", actual: nil, estimated: 0.25, status: "estimated"),
            .init(id: "included", actual: nil, estimated: 0.0, status: "included"),
            .init(id: "actual", actual: 0.5, estimated: nil, status: "actual"),
            .init(id: "null-status", actual: nil, estimated: nil, status: nil),
            .init(id: "null-status-zero", actual: nil, estimated: 0.0, status: nil),
            // A usable zero actual wins over a positive estimate.
            .init(id: "actual-zero", actual: 0.0, estimated: 0.3, status: "unknown"),
            // An unusable (negative) actual falls through to the estimate.
            .init(id: "negative-actual", actual: -1.0, estimated: 0.2, status: "unknown"),
            .init(id: "unknown-positive", actual: nil, estimated: 0.1, status: "unknown"),
        ]
        func lit(_ v: Double?) -> String { v.map { "\($0)" } ?? "NULL" }
        func lit(_ v: String?) -> String { v.map { "'\($0)'" } ?? "NULL" }
        let values = cases.map {
            "('\($0.id)', 'acp', 'm', 1699000000, \(lit($0.actual)), \(lit($0.estimated)), \(lit($0.status)))"
        }.joined(separator: ",\n")
        let seed = """
            INSERT INTO sessions (id, source, model, started_at, actual_cost_usd, estimated_cost_usd, cost_status)
            VALUES \(values);
            """
        let home = try makeHome(seed: seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let usage = await service.fetchUsageAggregatesInPeriod(since: Date(timeIntervalSince1970: 0))
        await service.close()

        let expectedUnknown = cases.filter {
            SessionCostDisplay(actualCostUSD: $0.actual, estimatedCostUSD: $0.estimated,
                               costStatus: $0.status, hasCostStatusColumn: true).isUnknown
        }.count
        let expectedCost = cases.reduce(0.0) { $0 + ($1.actual ?? $1.estimated ?? 0) }
        #expect(expectedUnknown == 4)
        #expect(usage.reduce(0) { $0 + $1.unknownCostSessions } == expectedUnknown)
        #expect(abs(usage.reduce(0.0) { $0 + $1.costUSD } - expectedCost) < 1e-9)
    }
}

#endif
