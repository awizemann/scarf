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
/// The bool arm is not decoration, and it is not just `false`. Hermes branches
/// on `isinstance(mode, bool)` → `"off" if mode is False else "manual"`
/// (`:200,205-206`), and PyYAML's YAML 1.1 bool resolver matches the whole
/// word set on both sides: `false`/`False`/`FALSE`, `no`/`No`/`NO`,
/// `off`/`Off`/`OFF` all load as Python `False`, and `true`/`yes`/`on` (with
/// the same case variants) as `True`. So upstream `approvals.mode: no` is the
/// `off` mode, not `manual` — and the single-spelling version of this arm read
/// it as `manual`, rendering "Manual (ask before every guarded command)" on a
/// host that never asks.
///
/// Scarf's parse is string-based (`HermesYAML` never coerces), so every one of
/// those spellings arrives here as text and ``normalize`` has to resolve the
/// bool itself. It uses the one boolish helper (`HermesYAML.boolishValue`)
/// rather than a hand-rolled word list — with ONE documented subtraction.
///
/// **`0` and `1` are NOT bools here.** Round-tripped through the real PyYAML,
/// `mode: 0` loads as the *int* `0` and `mode: 1` as the int `1`, so neither
/// `isinstance(mode, bool)` nor `isinstance(mode, str)` matches and Hermes
/// falls straight through to `return "manual"` (`:214`). `boolishValue`'s set
/// is Scarf's own liberal boolish set, which is right for the keys Hermes
/// coerces and wrong for this one key it type-switches on, so the numeric
/// spellings are excluded below. `~` / `null` are not bools either, and they
/// reach `manual` the same way.
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
        // A real mode name wins, so `off` reads as the mode and not via the
        // bool route (the two agree, but the intent is clearer).
        if let mode = HermesApprovalMode(rawValue: value) { return mode }
        // Otherwise: anything PyYAML would have loaded as a BOOL, resolved the
        // way Hermes resolves it — `"off" if mode is False else "manual"`
        // (`tools/approval_context.py:205-206`). `0` / `1` load as ints, not
        // bools, so Hermes gives them `manual`; see the type note above.
        if value != "0", value != "1", let boolish = HermesYAML.boolishValue(value) {
            return boolish ? .manual : .off
        }
        return .manual
    }

    /// Picker options, in Hermes's own `_VALID_MODES` order.
    public static let options: [String] = ["manual", "smart", "off"]
}
