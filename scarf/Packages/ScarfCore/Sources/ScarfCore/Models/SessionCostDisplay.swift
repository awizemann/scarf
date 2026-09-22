import Foundation

/// How a session's cost must be presented, derived ONCE from the three
/// columns Hermes writes — `actual_cost_usd`, `estimated_cost_usd` and
/// `cost_status`. Every cost surface in Scarf goes through this type rather
/// than re-deriving the rule from the raw numbers.
///
/// **The value set.** Hermes declares it exhaustively as
/// `CostStatus = Literal["actual", "estimated", "included", "unknown"]`
/// (`agent/usage_pricing.py:48` @ tag `v2026.9.21`). Three are produced in
/// that file — `"unknown"` (`:550`, `CostResult(amount_usd=None, …, label="n/a")`),
/// `"included"` (`:565`, a true zero on a `subscription_included` route) and
/// `"estimated"` (`:596`); `"actual"` is declared for a provider-reported
/// cost and carried through unchanged. Anything else — a value a future
/// Hermes invents — degrades to ``legacy``, i.e. to exactly what Scarf
/// rendered before this type existed.
///
/// **The defect this fixes.** An unknown cost has `amount_usd=None`, and
/// BOTH persist paths collapse that `None` to `0.0`: the `UPDATE sessions`
/// statement built at `hermes_state_usage.py:29`
/// (`estimated_cost_usd = COALESCE(?, 0)`, with `cost_status = COALESCE(?,
/// cost_status)` at `:37`, executed by `update_token_counts` at `:275`), and
/// the `session_model_usage` upsert at `:367`
/// (`float(estimated_cost_usd or 0.0)`). The stored number is therefore
/// byte-identical for "Hermes does not know" and "it was genuinely free";
/// `cost_status` is the ONLY discriminator, and Scarf must not read a
/// placeholder zero as a claim that the session cost nothing.
public enum SessionCostDisplay: Equatable, Sendable {
    /// A real, positive figure to render. `isActual` is false for an
    /// estimate and drives the existing " est." marker on the surfaces that
    /// have one.
    case amount(Double, isActual: Bool)

    /// Hermes priced this session at exactly zero because the billing route
    /// is subscription-included (`cost_status == "included"`,
    /// `usage_pricing.py:565`). A genuine $0.00 — and, unlike an estimate,
    /// not an approximation, so surfaces drop the " est." marker.
    case includedFree

    /// Hermes did not know the cost, and stored the placeholder zero (or
    /// nothing at all). Must NEVER render as a currency amount.
    ///
    /// Two shapes reach this, and both are genuine "Hermes never priced
    /// this":
    /// * `cost_status == "unknown"` — Hermes priced the turn and could not
    ///   find a rate (`usage_pricing.py:550`, `amount_usd=None`).
    /// * `cost_status IS NULL` **on a host that HAS the column**. Hermes
    ///   writes `cost_status` only from `update_token_counts`
    ///   (`hermes_state_usage.py:275`, `cost_status = COALESCE(?,
    ///   cost_status)` at `:37`), so a session that never completed a
    ///   priced turn keeps the column NULL on a fully CURRENT host. This is
    ///   not rare: on the live v0.21.3 host 9 of 43 sessions (6 acp, 2
    ///   cron, 1 telegram — one of them 133 messages) were in exactly that
    ///   state, and `sessionListPredicate` does not filter them out.
    case unknown

    /// No usable status AND no way to tell what the silence means, with no
    /// positive amount to show. Two causes:
    /// * the `cost_status` COLUMN IS ABSENT — a Hermes host below the v0.7
    ///   schema, where the column sits outside the probed `hasV07Schema`
    ///   tail of the SELECT. Scarf cannot distinguish "free" from "don't
    ///   know" on such a host and must not start guessing.
    /// * `cost_status` is a string this Scarf does not recognise (a value a
    ///   future Hermes invents).
    ///
    /// A NULL value on a host that HAS the column is NOT this case — see
    /// ``unknown``.
    ///
    /// `amount` is the raw value the surface used to render before this type
    /// existed (nil when the session carried no cost at all), and `isActual`
    /// the raw marker, so every caller can reproduce its prior output
    /// byte-for-byte. That is charter C1: an older host must render exactly
    /// as it did in the previous Scarf release.
    case legacy(amount: Double?, isActual: Bool)

    /// Hermes's `cost_status` spelling for "I could not price this".
    static let unknownStatus = "unknown"
    /// Hermes's `cost_status` spelling for a subscription-included zero.
    static let includedStatus = "included"

    /// The one rule. `actualCostUSD` wins over `estimatedCostUSD`, matching
    /// the long-standing `HermesSession.displayCostUSD` preference order.
    ///
    /// - Parameter hasCostStatusColumn: whether the `sessions.cost_status`
    ///   COLUMN existed in the SELECT this row came from — Scarf's
    ///   `hasV07Schema` probe (charter C4: probed with `PRAGMA table_info`,
    ///   never inferred from a version string). It is the ONLY thing that
    ///   separates "a host too old to have the column" from "a current host
    ///   that never priced this session", because both decode `costStatus`
    ///   to nil. Defaults to `false`, the conservative reading: without
    ///   positive evidence that the column exists, a nil status degrades to
    ///   ``legacy`` and the surface renders exactly as it did before this
    ///   type existed (charter C1).
    public init(
        actualCostUSD: Double?,
        estimatedCostUSD: Double?,
        costStatus: String?,
        hasCostStatusColumn: Bool = false
    ) {
        let actual = Self.usableAmount(actualCostUSD)
        let estimated = Self.usableAmount(estimatedCostUSD)
        let amount = actual ?? estimated
        let isActual = actual != nil

        // A positive figure is always shown, whatever the status says.
        // Hermes only ever stores the placeholder ZERO for an unknown cost
        // (`amount_usd=None` → `COALESCE(?, 0)`), never a positive one, so a
        // positive amount is real information and outranks the status word.
        if let amount, amount > 0 {
            self = .amount(amount, isActual: isActual)
            return
        }

        switch costStatus?.lowercased() {
        case Self.unknownStatus:
            self = .unknown
        case Self.includedStatus:
            self = .includedFree
        case nil where hasCostStatusColumn:
            // The column EXISTS and Hermes left it NULL. That is not an old
            // host — it is a current one that never completed a priced turn
            // (`hermes_state_usage.py:275` is the only writer), so the
            // absent number means "never priced", exactly like an explicit
            // `"unknown"`. Rendering `$0.00` here asserts a fact Hermes
            // never stated. Reached only when there is no positive amount,
            // which the early return above has already taken.
            self = .unknown
        default:
            self = .legacy(amount: amount, isActual: isActual)
        }
    }

    /// A figure Scarf is willing to put on screen, or nil.
    ///
    /// Hermes can only ever store a finite, non-negative number here — an
    /// unknown cost is the placeholder `0.0`, never a NaN and never a
    /// negative. A value outside that range is corrupt (a mangled row, a
    /// `0/0` computed upstream) and carries no information, so it is
    /// treated as "no positive amount" rather than rendered: `NaN > 0` is
    /// false, so such a value used to skip the ``amount`` arm and then ride
    /// into ``legacy(amount:isActual:)`` as a figure the surfaces DO print
    /// — "NaN" or "-$5.00" in a currency label.
    private static func usableAmount(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// True when this session contributes no known figure to a sum, so an
    /// aggregate that includes it cannot honestly read as a complete total.
    public var isUnknown: Bool { self == .unknown }
}
