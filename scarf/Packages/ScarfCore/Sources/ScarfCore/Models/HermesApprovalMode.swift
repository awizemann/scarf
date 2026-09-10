import Foundation

/// `approvals.mode` — the persisted terminal-approval policy, mirrored from
/// Hermes's own reader `_normalize_approval_mode` (hermes-agent
/// `tools/approval_context.py:197-214` @ v2026.9.7 / v0.21.1):
///
/// ```python
/// _VALID_MODES = ("manual", "smart", "off")
///
/// def _normalize_approval_mode(mode) -> str:
///     if isinstance(mode, bool):
///         return "off" if mode is False else "manual"
///     if isinstance(mode, str):
///         normalized = mode.strip().lower()
///         if normalized in _VALID_MODES:
///             return normalized
///         if normalized:
///             logger.warning("Unknown approvals.mode %r — defaulting to 'manual'. ...")
///     return "manual"
/// ```
///
/// **`auto` was never a member.** Scarf's Approval Mode picker offered
/// `auto` alongside `manual`/`smart`/`off`; walking the reader across every
/// tag from v2026.3.17 (v0.3.0, `tools/approval.py`) through v2026.9.7
/// (where the module split to `tools/approval_context.py` and the tuple was
/// hoisted to a `_VALID_MODES` constant) shows the member set has never
/// contained it — from v2026.7.1 (v0.18.0) the docstring even names `'auto'`
/// as *the* example of a value that is "rejected with a warning". Picking it
/// wrote a scalar Hermes logs and discards, leaving the user on `manual`
/// while the picker claimed otherwise. It is gone from the options.
///
/// The bool arm is not decoration: YAML 1.1 parses a bare `off` as `False`,
/// so `mode: off` reaches Hermes as a boolean and still means the `off`
/// mode. Scarf's parse is string-based (`HermesYAML` never coerces), so the
/// bare word arrives as the text `"off"` and lands on ``off`` directly —
/// but `mode: false` (which Hermes also reads as `off`) is handled here too.
public enum HermesApprovalMode: String, CaseIterable, Sendable {
    /// Ask before every guarded command.
    case manual
    /// Guardian model decides, per `approvals.smart_policy`.
    case smart
    /// Never ask.
    case off

    /// Read a persisted `approvals.mode` scalar the way Hermes reads it.
    ///
    /// Anything Hermes would warn-and-ignore — including the `auto` Scarf
    /// itself used to write — lands on ``manual``, which is the mode the
    /// host actually enforces for it. That is what keeps the picker from
    /// rendering blank (a selection outside its own option list) on a
    /// config carrying a stale `auto`, and from claiming a value is live
    /// when the agent has discarded it.
    public static func normalize(_ raw: String) -> HermesApprovalMode {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "false" { return .off }          // YAML 1.1 `mode: off`
        return HermesApprovalMode(rawValue: value) ?? .manual
    }

    /// Picker options, in Hermes's own `_VALID_MODES` order.
    public static let options: [String] = ["manual", "smart", "off"]
}
