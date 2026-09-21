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

    /// Charter C1 proof. On a host with no `cost_status` column the rule must
    /// hand each surface the SAME two values it used to read directly
    /// (`displayCostUSD` and `costIsActual`), so its rendering is unchanged
    /// byte for byte. Anything that routed a nil-status session into
    /// `.unknown` — the easy way to "fix" the defect — fails here.
    @Test(
        "a nil cost_status never changes what an older host renders",
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

    // MARK: - Fixture

    static func session(actual: Double?, estimated: Double?, status: String?) -> HermesSession {
        HermesSession(
            id: "s", source: "acp", userId: nil, model: "fable:free", title: nil,
            parentSessionId: nil, startedAt: nil, endedAt: nil, endReason: nil,
            messageCount: 0, toolCallCount: 0, inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, estimatedCostUSD: estimated,
            reasoningTokens: 0, actualCostUSD: actual, costStatus: status,
            billingProvider: nil
        )
    }
}
