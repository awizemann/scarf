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
/// cost_status)` at `:37`, executed by `update_token_counts` at `:274`), and
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

    /// Hermes did not know the cost (`cost_status == "unknown"`) and stored
    /// the placeholder zero. Must NEVER render as a currency amount.
    case unknown

    /// No usable status: `cost_status` is nil (a pre-v0.7 Hermes host, where
    /// the column sits outside the probed `hasV07Schema` tail of the SELECT
    /// and decodes to nil) or is a string this Scarf does not recognise —
    /// and there is no positive amount to show.
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
    public init(actualCostUSD: Double?, estimatedCostUSD: Double?, costStatus: String?) {
        let amount = actualCostUSD ?? estimatedCostUSD
        let isActual = actualCostUSD != nil

        // A positive figure is always shown, whatever the status says.
        // Hermes only ever stores the placeholder ZERO for an unknown cost
        // (`amount_usd=None` → `COALESCE(?, 0)`), never a positive one, so a
        // positive amount is real information and outranks the status word.
        if let amount, amount > 0 {
            self = .amount(amount, isActual: isActual)
            return
        }

        switch costStatus?.lowercased() {
        case Self.unknownStatus: self = .unknown
        case Self.includedStatus: self = .includedFree
        default: self = .legacy(amount: amount, isActual: isActual)
        }
    }

    /// True when this session contributes no known figure to a sum, so an
    /// aggregate that includes it cannot honestly read as a complete total.
    public var isUnknown: Bool { self == .unknown }
}
