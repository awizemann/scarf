import Foundation

/// Hermes v0.20 reasoning-effort vocabulary — verbatim mirror of
/// `VALID_REASONING_EFFORTS` in hermes_constants.py:942 plus the "none"
/// disable alias `parse_reasoning_effort` accepts (hermes_constants.py:967).
/// `max` and `ultra` are the v0.20 additions (#62650).
public enum HermesReasoningEffort {
    /// Levels valid on every supported host (pre-v0.20 vocabulary).
    public static let baseLevels = ["none", "minimal", "low", "medium", "high", "xhigh"]
    /// v0.20 additions.
    public static let v020Levels = ["max", "ultra"]

    /// Disable aliases `parse_reasoning_effort` treats identically to
    /// "none" (hermes_constants.py:967): a hand-edited `disabled` / `false`
    /// / `off` row is Hermes-valid and must pass validation verbatim — the
    /// UI never offers these, but it must not reject (or rewrite) them.
    public static let disableAliases = ["disabled", "false", "off"]

    /// Effort options to offer for the given host generation.
    public static func levels(capabilities: HermesCapabilities) -> [String] {
        capabilities.isV020OrLater ? baseLevels + v020Levels : baseLevels
    }

    /// Whether Hermes's `parse_reasoning_effort` would accept this value.
    public static func isValid(_ effort: String) -> Bool {
        let normalized = effort.trimmingCharacters(in: .whitespaces).lowercased()
        return (baseLevels + v020Levels + disableAliases).contains(normalized)
    }
}

/// Direct-YAML writers for the v0.20 power settings that `hermes config set`
/// cannot express: the `agent.reasoning_overrides` dict and the
/// `model_catalog.excluded_providers` list (`config set` stringifies
/// arrays/dicts — same gotcha that created `GatewayConfigWriter`). Pure
/// functions delegate to `GatewayConfigWriter`'s surgical block editing:
/// bytes outside the target block are preserved (comments and unknown keys
/// included) and an empty dict/list removes the key entirely.
///
/// Both writers are capability-gated: on a pre-v0.20 host they REFUSE
/// (return nil) rather than write keys the host would ignore — the UI is
/// hidden there too, so this is defense in depth.
public enum PowerSettingsWriter {

    /// Replace the `agent.reasoning_overrides:` block. Pairs are
    /// (model-pattern, effort). Returns nil when the host is pre-v0.20 or
    /// any effort value is invalid; returns updated YAML otherwise. An
    /// empty pair list deletes the key (Hermes default `{}`).
    public static func setReasoningOverrides(
        in yaml: String,
        pairs: [(key: String, value: String)],
        capabilities: HermesCapabilities
    ) -> String? {
        guard capabilities.isV020OrLater else { return nil }
        let cleaned = pairs
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (key: $0.key, value: Self.canonicalDisableSpelling($0.value)) }
        guard cleaned.allSatisfy({ HermesReasoningEffort.isValid($0.value) }) else { return nil }
        // A refusal (a config.yaml shape the line editor can't rewrite
        // without clobbering it) reports as the same nil the pre-v0.20 and
        // invalid-effort guards use — the caller writes nothing.
        return GatewayConfigWriter.setMapChecked(
            in: yaml,
            section: "agent",
            key: "reasoning_overrides",
            pairs: cleaned
        ).appliedText(orUnchanged: yaml)
    }

    /// `off` is a disable alias ONLY by way of YAML's bool coercion: bare
    /// `off` loads as Python `False` and `parse_reasoning_effort` does
    /// `str(False).lower()` → `"false"` → disabled
    /// (`hermes_constants.py:876-889` at `v2026.9.7`). Since P19 the writer
    /// QUOTES implicitly-typed scalars, which keeps `off` a string — and the
    /// string `"off"` is in neither of that function's sets, so it would
    /// silently mean "use the default effort" instead of "disabled".
    /// Canonicalise it to `none`, which is the spelling the function accepts
    /// literally and the one the picker offers. `false` and `disabled` are
    /// already accepted as strings, so they are written as typed.
    private static func canonicalDisableSpelling(_ effort: String) -> String {
        effort.trimmingCharacters(in: .whitespaces).lowercased() == "off"
            ? "none"
            : effort
    }

    /// Replace the `model_catalog.excluded_providers:` list. Returns nil on
    /// pre-v0.20 hosts. An empty list deletes the key.
    public static func setExcludedProviders(
        in yaml: String,
        providers: [String],
        capabilities: HermesCapabilities
    ) -> String? {
        guard capabilities.isV020OrLater else { return nil }
        // Hermes lowercases at consumption (model_switch.py:2007); keep the
        // user's spelling but trim.
        let cleaned = providers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Refusal → nil, same as the capability guard above.
        return GatewayConfigWriter.setListChecked(
            in: yaml,
            platform: "model_catalog",
            key: "excluded_providers",
            items: cleaned
        ).appliedText(orUnchanged: yaml)
    }
}
