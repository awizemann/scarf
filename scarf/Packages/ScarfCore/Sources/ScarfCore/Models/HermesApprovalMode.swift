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
/// coerces and wrong for this one key it type-switches on, so the bool arm is
/// gated on `YAMLScalar.resolvesToBool` — PyYAML's own resolver, which excludes
/// `0` / `1` without a hand-carved special case. `~` / `null` are not bools
/// either, and they reach `manual` the same way.
///
/// **And QUOTING is the other half of that same type gate** (P41). PyYAML types
/// the scalar before Hermes sees it, so a quoted `"no"` / `"false"` is a `str`,
/// not a `bool`: it misses `_VALID_MODES` (`:195`), warns, and lands on
/// `manual` — while the bare spellings land on `off`. ``normalize`` therefore
/// takes the scalar with its QUOTES INTACT. Handing it an already-unquoted one
/// (which `HermesConfig.approvalMode` is, via `HermesYAML.normalizedScalar`)
/// rendered "Never ask" on a host that asks before every guarded command — the
/// unsafe direction. `HermesConfig.approvalModeRawScalar` carries the raw form
/// for exactly this reader.
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
        // `raw` is the scalar as it stands in config.yaml — QUOTES INTACT.
        // The full table, re-derived from the tagged reader. BARE:
        // `yes`/`true`/`on` load as bool True → manual; `no`/`false`/`off`
        // as bool False → off; `0`/`1` as ints, which match neither
        // `isinstance` arm → manual. QUOTED: all eight are `str`, and only
        // `"off"` is in `_VALID_MODES` (`tools/approval_context.py:195`),
        // so `"off"` → off and the other seven warn and land on `manual`
        // (`:198-214` @ `v2026.9.7`).
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isQuoted = trimmed.first == "\"" || trimmed.first == "'"
        // What Hermes's STRING arm effectively sees: quotes off, and a
        // whitespace-preceded trailing comment dropped (PyYAML strips the
        // comment long before Hermes gets the value).
        // P41b: the trim has to come AFTER the quotes come off. Hermes's
        // string arm is `mode.strip().lower()`
        // (`tools/approval_context.py:207` @ `v2026.9.7`), and PyYAML hands
        // it the scalar's CONTENT — so `mode: " off"` is the Python string
        // `" off"`, strips to `off`, and IS in `_VALID_MODES`. Trimming the
        // raw scalar first only ever removed whitespace OUTSIDE the quotes,
        // so ` off` never matched and the picker rendered "Ask every time"
        // for a host that asks for nothing — the unsafe direction again.
        // A bare scalar is already trimmed, so this is a no-op on that arm.
        let value = HermesYAML.normalizedScalar(trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // A real mode name wins, so `off` reads as the mode and not via the
        // bool route (the two agree, but the intent is clearer). This is
        // also the quoted `"off"` case, which is the one quoted spelling
        // that is NOT `manual`.
        if let mode = HermesApprovalMode(rawValue: value) { return mode }
        // Otherwise: anything PyYAML would have loaded as a BOOL, resolved the
        // way Hermes resolves it — `"off" if mode is False else "manual"`
        // (`tools/approval_context.py:205-206`). Two gates, both on the RAW
        // scalar and both before the word match, exactly as
        // `HermesFileService.boolishOptional` does it for `_parse_boolish`:
        // a QUOTED scalar is a `str` and never reaches this arm, and
        // `YAMLScalar.resolvesToBool` is PyYAML's bool resolver exactly, so
        // `0` / `1` are excluded by the resolver rather than by a
        // hand-carved special case.
        if !isQuoted, YAMLScalar.resolvesToBool(value),
           let boolish = HermesYAML.boolishValue(value) {
            return boolish ? .manual : .off
        }
        return .manual
    }

    /// Picker options, in Hermes's own `_VALID_MODES` order.
    public static let options: [String] = ["manual", "smart", "off"]
}
