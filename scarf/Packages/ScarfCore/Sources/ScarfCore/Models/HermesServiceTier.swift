import Foundation

/// `agent.service_tier` — the persisted fast-mode preference, mirrored from
/// Hermes's own parser `_parse_service_tier_config` (hermes-agent
/// `cli.py:274-284` @ v2026.9.7 / v0.21.1):
///
/// ```python
/// value = str(raw or "").strip().lower()
/// if not value or value in {"normal", "default", "standard", "off", "none"}: return None
/// if value in {"fast", "priority", "on"}: return "priority"
/// if value in {"auto", "cold"}: return value
/// logger.warning("Unknown service_tier '%s', ignoring", raw); return None
/// ```
///
/// The two BOUNDED modes are v0.21.1 additions (`agent/fast_mode.py:16`
/// `BOUNDED_MODES = frozenset({"auto", "cold"})`): `auto` opens a fast
/// window of `agent.fast_auto_seconds` (default 60) at every user turn,
/// `cold` opens one only on a session's very first turn. At v2026.8.31
/// (v0.21.0) the same parser knows only the off/priority pair and *warns
/// then ignores* everything else — so Scarf must not offer `auto`/`cold`
/// to a pre-v0.21.1 host (`HermesCapabilities.hasServiceTierBoundedModes`).
///
/// Scarf writes the alias it has always written for "always fast" (`fast`,
/// not the canonical `priority`) and the one it has always written for off
/// (`normal`, not the `""` in `config_defaults.py`). Both are exact
/// synonyms in the parser above on **every** supported host, and keeping
/// them means this picker round-trips byte-identically with the Bool
/// toggle it replaces — no config churn on upgrade.
public enum HermesServiceTier: String, CaseIterable, Sendable {
    /// Normal tier — `""` / `normal` / `default` / `standard` / `off` / `none`.
    case off
    /// Static fast tier — `fast` / `priority` / `on`.
    case always
    /// Bounded window at every user turn (v0.21.1+).
    case auto
    /// Bounded window on a session's first turn only (v0.21.1+).
    case cold

    /// Values Hermes maps onto `None` (normal tier).
    static let offAliases: Set<String> = ["", "normal", "default", "standard", "off", "none"]
    /// Values Hermes maps onto `"priority"` (static fast tier).
    static let alwaysAliases: Set<String> = ["fast", "priority", "on"]

    /// Read a persisted `agent.service_tier` scalar the way Hermes reads it.
    ///
    /// Anything Hermes would warn-and-ignore lands on ``off``, which is what
    /// the host actually does with it — so the picker never claims a value
    /// is live when the agent has discarded it.
    public static func normalize(_ raw: String) -> HermesServiceTier {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if alwaysAliases.contains(value) { return .always }
        if value == "auto" { return .auto }
        if value == "cold" { return .cold }
        return .off
    }

    /// The scalar Scarf writes for this selection. See the type's note on
    /// why `off`/`always` write the aliases rather than the canonical forms.
    public var configValue: String {
        switch self {
        case .off:    "normal"
        case .always: "fast"
        case .auto:   "auto"
        case .cold:   "cold"
        }
    }

    /// Whether this mode consumes `agent.fast_auto_seconds`.
    public var isBounded: Bool { self == .auto || self == .cold }

    /// Which control the Settings row renders (C1).
    ///
    /// A host with the bounded modes gets the four-way picker. A pre-target
    /// host — and an UNDETECTED one — renders the Bool toggle it rendered
    /// before this cycle: swapping in a picker there changes what an
    /// unchanged host looks like, and offers nothing, since the two values
    /// the toggle wrote are the only two such a host's parser accepts.
    ///
    /// The one exception is `current` already being a BOUNDED mode. That
    /// happens on an undetected host (a failed `hermes --version` probe
    /// reads as `.empty`, so every floor is false) whose config genuinely
    /// says `auto`/`cold`, and on a host someone downgraded. The toggle is
    /// LOSSY there: it renders `auto` as "off" and rewrites the key to
    /// `normal` on the first tap, destroying a setting Scarf never had
    /// grounds to believe was invalid. Routing that one state to the picker
    /// keeps the value visible and selectable — and it is the only thing
    /// that makes ``options(capabilities:current:)``'s widening branch
    /// reachable at all. No config Scarf itself could have written on a
    /// pre-target host reaches this branch, so C1 holds for every host that
    /// rendered a toggle before.
    public static func editorStyle(
        capabilities: HermesCapabilities,
        current: HermesServiceTier = .off
    ) -> EditorStyle {
        if capabilities.hasServiceTierBoundedModes { return .picker }
        return current.isBounded ? .picker : .toggle
    }

    public enum EditorStyle: Sendable, Equatable {
        /// The pre-v0.21.1 Bool "Fast Mode" row.
        case toggle
        /// The v0.21.1 four-way picker (+ the fast-window stepper).
        case picker
    }

    /// Options to offer for the given host generation.
    ///
    /// Pre-v0.21.1 hosts get the two-way off/always pair, which round-trips
    /// exactly the values the Bool "Fast Mode" toggle used to write. The
    /// currently persisted mode is always included even when the host can't
    /// use it: a hand-edited `auto` on an old host must stay VISIBLE (and
    /// stay put) rather than render as a blank picker that silently
    /// overwrites it on the first interaction.
    public static func options(
        capabilities: HermesCapabilities,
        current: HermesServiceTier
    ) -> [HermesServiceTier] {
        let base: [HermesServiceTier] = capabilities.hasServiceTierBoundedModes
            ? allCases
            : [.off, .always]
        return base.contains(current) ? base : base + [current]
    }
}
