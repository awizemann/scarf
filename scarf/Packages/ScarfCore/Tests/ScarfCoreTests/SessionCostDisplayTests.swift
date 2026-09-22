import Foundation
import Testing
@testable import ScarfCore

/// The one shared cost rule. Hermes persists an UNKNOWN cost as the
/// placeholder `0.0` (see `SessionCostDisplay`'s citations), so the number
/// alone cannot tell "free" from "don't know" — `cost_status` can, and these
/// tests pin that Scarf reads it, that a positive amount always wins, and
/// (charter C1) that a host with no `cost_status` at all still hands the
/// views exactly the two values they rendered from before.
@Suite("SessionCostDisplay — the one cost rule")
struct SessionCostDisplayTests {

    /// One row of the status × amount matrix.
    struct Row: CustomStringConvertible, Sendable {
        let actual: Double?
        let estimated: Double?
        let status: String?
        let expected: SessionCostDisplay
        let why: String

        var description: String { why }
    }

    /// Exercised with `hasCostStatusColumn: false` — a host with no
    /// `cost_status` column — so every `status: nil` row here is the
    /// genuinely-old-host case. `nullStatusMatrix` covers the same values on
    /// a host that HAS the column.
    static let matrix: [Row] = [
        // --- The defect. An unknown cost must never render as a figure. ---
        .init(actual: nil, estimated: 0.0, status: "unknown",
              expected: .unknown,
              why: "cost_status=unknown with the placeholder zero is UNKNOWN, not free"),
        .init(actual: 0.0, estimated: 0.25, status: "unknown",
              expected: .unknown,
              why: "actual wins the preference order; a zero actual + unknown is still unknown"),
        .init(actual: nil, estimated: -1.0, status: "unknown",
              expected: .unknown,
              why: "a non-positive amount cannot rescue an unknown status"),
        .init(actual: nil, estimated: 0.0, status: "UNKNOWN",
              expected: .unknown,
              why: "status matching tolerates case"),

        // --- A genuine zero. ---
        .init(actual: nil, estimated: 0.0, status: "included",
              expected: .includedFree,
              why: "cost_status=included is a real $0.00 on a subscription route"),

        // --- A positive amount always shows, whatever the status says. ---
        .init(actual: nil, estimated: 0.25, status: "estimated",
              expected: .amount(0.25, isActual: false),
              why: "an estimate renders its amount and keeps the est. marker"),
        .init(actual: 0.5, estimated: 0.25, status: "actual",
              expected: .amount(0.5, isActual: true),
              why: "actual_cost_usd outranks estimated_cost_usd"),
        .init(actual: 0.5, estimated: 0.25, status: "unknown",
              expected: .amount(0.5, isActual: true),
              why: "a positive figure is real information and outranks the status word"),
        .init(actual: nil, estimated: 0.25, status: "unknown",
              expected: .amount(0.25, isActual: false),
              why: "Hermes only ever stores the placeholder ZERO for unknown"),
        .init(actual: nil, estimated: 0.25, status: nil,
              expected: .amount(0.25, isActual: false),
              why: "a pre-v0.7 host with a real cost still renders that cost"),

        // --- Everything else degrades to the pre-existing rendering. ---
        .init(actual: nil, estimated: nil, status: nil,
              expected: .legacy(amount: nil, isActual: false),
              why: "no cost columns at all: the surfaces that hid the cost keep hiding it"),
        .init(actual: nil, estimated: 0.0, status: nil,
              expected: .legacy(amount: 0.0, isActual: false),
              why: "pre-v0.7 host, zero cost: unchanged from the previous Scarf release (C1)"),
        .init(actual: nil, estimated: 0.0, status: "estimated",
              expected: .legacy(amount: 0.0, isActual: false),
              why: "an estimate of zero is not the unknown placeholder; render as before"),
        .init(actual: 0.0, estimated: nil, status: "actual",
              expected: .legacy(amount: 0.0, isActual: true),
              why: "a provider-reported zero keeps the actual marker"),
        .init(actual: nil, estimated: 0.0, status: "quantum-vibes",
              expected: .legacy(amount: 0.0, isActual: false),
              why: "a cost_status a future Hermes invents degrades safely, never to a new claim"),
    ]

    @Test("the status × amount matrix", arguments: matrix)
    func matrixHolds(row: Row) {
        let display = SessionCostDisplay(
            actualCostUSD: row.actual,
            estimatedCostUSD: row.estimated,
            costStatus: row.status
        )
        #expect(display == row.expected, "\(row.why)")
    }

    // MARK: - A NULL cost_status on a host that HAS the column

    /// The second, more common shape of the same defect. Hermes writes
    /// `cost_status` only from `update_token_counts`
    /// (`hermes_state_usage.py:275`, `cost_status = COALESCE(?, cost_status)`
    /// at `:37`), so a session that never completed a priced turn keeps the
    /// column NULL on a fully CURRENT host — 9 of 43 on the live v0.21.3 host,
    /// including a 133-message Telegram session. Those must say "unknown",
    /// not `$0.00`.
    ///
    /// The discriminator is the COLUMN's existence (`hasCostStatusColumn`,
    /// Scarf's probed `hasV07Schema`), never the value, because the value is
    /// nil either way.
    static let nullStatusMatrix: [Row] = [
        .init(actual: nil, estimated: nil, status: nil,
              expected: .unknown,
              why: "v0.7+ host, never priced: both cost columns NULL is UNKNOWN, not $0.00"),
        .init(actual: nil, estimated: 0.0, status: nil,
              expected: .unknown,
              why: "v0.7+ host, NULL status with the placeholder zero is UNKNOWN"),
        .init(actual: 0.0, estimated: nil, status: nil,
              expected: .unknown,
              why: "a zero actual with no status on a v0.7+ host is still unknown"),
        .init(actual: nil, estimated: -1.0, status: nil,
              expected: .unknown,
              why: "a non-positive amount cannot make a NULL status a figure"),
        // A positive amount still outranks the silence, exactly as it does
        // for an explicit "unknown".
        .init(actual: nil, estimated: 0.25, status: nil,
              expected: .amount(0.25, isActual: false),
              why: "a real cost with no status still renders that cost"),
        .init(actual: 1.5, estimated: 0.25, status: nil,
              expected: .amount(1.5, isActual: true),
              why: "actual outranks estimated and the missing status alike"),
        // An unrecognised status is NOT the NULL case — it still degrades.
        .init(actual: nil, estimated: 0.0, status: "quantum-vibes",
              expected: .legacy(amount: 0.0, isActual: false),
              why: "only NULL means 'never priced'; a future status still degrades to legacy"),
    ]

    @Test("a NULL cost_status on a host that HAS the column is unknown, not a zero",
          arguments: nullStatusMatrix)
    func nullStatusOnAModernHostIsUnknown(row: Row) {
        let display = SessionCostDisplay(
            actualCostUSD: row.actual,
            estimatedCostUSD: row.estimated,
            costStatus: row.status,
            hasCostStatusColumn: true
        )
        #expect(display == row.expected, "\(row.why)")
    }

    /// The whole fix in one assertion: the SAME row decodes differently
    /// depending only on whether the host has the column. If
    /// `hasCostStatusColumn` stops being consulted, one of these two fails.
    @Test("the column's presence is the only thing that separates legacy from unknown")
    func theColumnIsTheDiscriminator() {
        let columnAbsent = SessionCostDisplay(
            actualCostUSD: nil, estimatedCostUSD: nil, costStatus: nil,
            hasCostStatusColumn: false
        )
        let columnPresent = SessionCostDisplay(
            actualCostUSD: nil, estimatedCostUSD: nil, costStatus: nil,
            hasCostStatusColumn: true
        )
        #expect(columnAbsent == .legacy(amount: nil, isActual: false))
        #expect(columnPresent == .unknown)
        #expect(columnAbsent != columnPresent)
        #expect(!columnAbsent.isUnknown)
        #expect(columnPresent.isUnknown)
    }

    /// `HermesSession` must carry the flag through to the rule — a session
    /// built by the decoder on a v0.7+ host reports unknown, one built
    /// without the flag keeps the legacy reading. Also pins that `withTitle`
    /// does not drop it on the way through.
    @Test("HermesSession carries the column's presence into costDisplay")
    func sessionCarriesTheFlag() {
        let modern = Self.session(actual: nil, estimated: nil, status: nil, hasColumn: true)
        let old = Self.session(actual: nil, estimated: nil, status: nil, hasColumn: false)
        #expect(modern.costDisplay == .unknown)
        #expect(old.costDisplay == .legacy(amount: nil, isActual: false))
        #expect(modern.withTitle("renamed").costDisplay == .unknown,
                "withTitle must not drop hasCostStatusColumn")
        #expect(modern.hasCostStatusColumn)
        #expect(!old.hasCostStatusColumn)
    }

    /// The whole point: `unknown` must be distinguishable from a real zero,
    /// even though Hermes stores the identical number for both. If this
    /// passes while `unknown` falls through to the legacy/zero rendering,
    /// the rule is broken.
    @Test("an unknown zero and an included zero are the same number but different presentations")
    func unknownIsNotTheSameAsFree() {
        let unknown = SessionCostDisplay(actualCostUSD: nil, estimatedCostUSD: 0.0, costStatus: "unknown")
        let included = SessionCostDisplay(actualCostUSD: nil, estimatedCostUSD: 0.0, costStatus: "included")
        #expect(unknown != included)
        #expect(unknown == .unknown)
        #expect(included == .includedFree)
        #expect(unknown.isUnknown)
        #expect(!included.isUnknown)
    }

    /// Charter C1 proof. On a host with no `cost_status` COLUMN (below the
    /// v0.7 schema, `hasCostStatusColumn == false`) the rule must hand each
    /// surface the SAME two values it used to read directly
    /// (`displayCostUSD` and `costIsActual`), so its rendering is unchanged
    /// byte for byte. Anything that routed such a session into `.unknown` —
    /// the easy way to "fix" the defect — fails here.
    ///
    /// Note what this does NOT say: it is about the column being absent, not
    /// about the value being nil. A NULL value on a host that HAS the column
    /// is a current host that never priced the session, and
    /// `nullStatusOnAModernHostIsUnknown` pins it to `.unknown`. Conflating
    /// the two is exactly the bug this suite previously enshrined.
    @Test(
        "an absent cost_status column never changes what an older host renders",
        arguments: [nil, 0.0, 0.004, 1.5] as [Double?]
    )
    func nilStatusIsByteIdenticalToBefore(estimated: Double?) {
        for actual in [nil, 0.0, 2.25] as [Double?] {
            let session = Self.session(actual: actual, estimated: estimated, status: nil)
            // What the surfaces read BEFORE this rule existed.
            let legacyAmount = session.displayCostUSD
            let legacyIsActual = session.costIsActual

            switch session.costDisplay {
            case .amount(let value, let isActual):
                #expect(value == legacyAmount)
                #expect(isActual == legacyIsActual)
                #expect(value > 0, "only a positive figure may take the .amount path")
            case .legacy(let value, let isActual):
                #expect(value == legacyAmount)
                #expect(isActual == legacyIsActual)
                #expect((value ?? 0) <= 0, ".legacy must never carry a positive amount")
            case .unknown, .includedFree:
                Issue.record("a nil cost_status must never reach a new presentation (C1)")
            }
        }
    }

    /// `HermesSession.costDisplay` is the accessor every surface calls; it
    /// must be the same rule, not a second copy of it.
    @Test("HermesSession.costDisplay forwards the session's three cost columns")
    func sessionAccessorMatchesTheRule() {
        for row in Self.matrix {
            let session = Self.session(actual: row.actual, estimated: row.estimated, status: row.status)
            #expect(session.costDisplay == row.expected, "\(row.why)")
        }
    }

    // MARK: - Corrupt amounts

    /// `NaN > 0` is false and so is `-5 > 0`, so a corrupt figure slipped
    /// past the positive-amount arm and rode into `.legacy(amount:)` — which
    /// SessionInfoBar and SessionDetailView DO render, printing "NaN" or a
    /// negative currency label. A value Hermes can never legitimately store
    /// is not a cost: it must read as "no positive amount", which on a host
    /// with the column means the em dash.
    @Test(
        "a NaN or negative amount is not a cost",
        arguments: [Double.nan, -5, -0.0001, -.infinity, .infinity]
    )
    func corruptAmountsAreNotRendered(bad: Double) {
        // Column present, status NULL: the common "never priced" host.
        #expect(
            SessionCostDisplay(
                actualCostUSD: bad, estimatedCostUSD: nil,
                costStatus: nil, hasCostStatusColumn: true
            ) == .unknown
        )
        // …and with an explicit status, the status still decides.
        #expect(
            SessionCostDisplay(
                actualCostUSD: nil, estimatedCostUSD: bad,
                costStatus: "included", hasCostStatusColumn: true
            ) == .includedFree
        )
        // On a host with no column the legacy tuple must carry NOTHING
        // rather than the corrupt number, so no surface prints it.
        #expect(
            SessionCostDisplay(
                actualCostUSD: bad, estimatedCostUSD: nil, costStatus: nil
            ) == .legacy(amount: nil, isActual: false)
        )
    }

    /// A corrupt ACTUAL must not shadow a good ESTIMATE — the row still has
    /// a real figure to show, and it is an estimate, so the " est." marker
    /// has to come with it.
    @Test("a corrupt actual falls through to a usable estimate")
    func corruptActualFallsThroughToTheEstimate() {
        #expect(
            SessionCostDisplay(
                actualCostUSD: .nan, estimatedCostUSD: 1.25,
                costStatus: "estimated", hasCostStatusColumn: true
            ) == .amount(1.25, isActual: false)
        )
    }

    // MARK: - Fixture

    /// `hasColumn` defaults to false — a host with no `cost_status` column —
    /// so the C1 test and the shared matrix exercise the legacy reading.
    static func session(
        actual: Double?,
        estimated: Double?,
        status: String?,
        hasColumn: Bool = false
    ) -> HermesSession {
        HermesSession(
            id: "s", source: "acp", userId: nil, model: "fable:free", title: nil,
            parentSessionId: nil, startedAt: nil, endedAt: nil, endReason: nil,
            messageCount: 0, toolCallCount: 0, inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, estimatedCostUSD: estimated,
            reasoningTokens: 0, actualCostUSD: actual, costStatus: status,
            billingProvider: nil, hasCostStatusColumn: hasColumn
        )
    }
}
