import Foundation

/// Hermes reasoning-effort vocabulary — verbatim mirror of
/// `VALID_REASONING_EFFORTS` (`hermes_constants.py:873` at `v2026.9.7`)
/// plus the disable aliases `parse_reasoning_effort` accepts (function at
/// `:876`, alias set `{"none", "false", "disabled"}` at `:885`).
///
/// `max` and `ultra` are NOT both v0.20 additions, as this type asserted
/// until P35. Walking `VALID_REASONING_EFFORTS` across every `v2026.*` tag:
/// v2026.6.19 and v2026.7.1 (0.18.0) carry the five-level tuple
/// `("minimal","low","medium","high","xhigh")`; **v2026.7.7 (0.18.1)**
/// appends `"max"` (`hermes_constants.py:794`), which v2026.7.7.2 (0.18.2)
/// still has alone; **v2026.7.20 (0.19.0)** appends `"ultra"`
/// (`hermes_constants.py:835-837`). Hence two floors, not one — see
/// ``HermesCapabilities/hasReasoningEffortMax`` and
/// ``HermesCapabilities/hasReasoningEffortUltra``.
public enum HermesReasoningEffort {
    /// Levels valid on every supported host (the pre-0.18.1 vocabulary).
    public static let baseLevels = ["none", "minimal", "low", "medium", "high", "xhigh"]
    /// Levels gated behind their own floors, in picker order.
    public static let maxLevel = "max"
    /// See ``maxLevel``.
    public static let ultraLevel = "ultra"

    /// Spellings validation must accept for a hand-edited row, beyond
    /// `VALID_REASONING_EFFORTS` + "none". `disabled` and `false` are in
    /// `parse_reasoning_effort`'s own alias set (`hermes_constants.py:885`);
    /// `off` is NOT — it only disables by way of YAML bool coercion, so the
    /// writer canonicalises it (see `canonicalDisableSpelling`). The UI never
    /// offers any of the three, but must not reject a row that uses them.
    ///
    /// All three are v0.18.1-and-later spellings — see
    /// ``HermesCapabilities/hasReasoningDisableAliases`` for the tag walk —
    /// so whether one of them is "reasoning off" or "an unsupported value
    /// Hermes ignores" is a capability question, which is why
    /// ``disablingSpellings(capabilities:)`` and not this list is what the
    /// affordance asks. ``isValid(_:)`` stays capability-free on purpose: it
    /// guards a hand-edited row against being REJECTED, and a value the host
    /// merely ignores is not a value Scarf should refuse to write back.
    public static let disableAliases = ["disabled", "false", "off"]

    /// Effort options to offer for the given host generation.
    public static func levels(capabilities: HermesCapabilities) -> [String] {
        var levels = baseLevels
        if capabilities.hasReasoningEffortMax { levels.append(maxLevel) }
        if capabilities.hasReasoningEffortUltra { levels.append(ultraLevel) }
        return levels
    }

    /// The host's options WIDENED to include `selected`, so a value already
    /// on disk always has a row to select (round-4 decision 13).
    ///
    /// A SwiftUI `Picker` whose selection matches no tag renders blank — so
    /// a config carrying `ultra` on a 0.18.x host showed an empty control,
    /// and the first unrelated save on that tab wrote whatever the user
    /// nudged it to. Widening is not an endorsement: the value is
    /// out-of-vocabulary for that host and ``unsupportedLevelNotice`` is
    /// what says so.
    ///
    /// The out-of-range value is PREPENDED rather than appended, matching
    /// `AgentTab`'s `effortOptions(current:)` — the shape this unifies.
    /// An empty `selected` (the "provider default" sentinel, which the two
    /// top-level pickers prepend themselves) widens nothing.
    public static func levels(capabilities: HermesCapabilities, selected: String) -> [String] {
        let base = levels(capabilities: capabilities)
        guard !selected.isEmpty, !base.contains(selected) else { return base }
        return [selected] + base
    }

    /// The affordance beside a widened picker: what Hermes on THIS host
    /// actually does with the stored value, not a bare "unsupported".
    ///
    /// Walked at the tag rather than assumed. `parse_reasoning_effort`
    /// returns `None` for anything outside `VALID_REASONING_EFFORTS` and the
    /// disable aliases, and its own docstring says the caller then uses the
    /// default — `hermes_constants.py:876-889` @ `v2026.9.7`, and the same
    /// closing `return None` across the whole window this matters in:
    /// `:797-812` @ `v2026.7.1` (the five-level tuple at `:794`),
    /// `:797-820` @ `v2026.7.7` (which adds `max` at `:794`) and
    /// `:840-864` @ `v2026.7.20` (which adds `ultra` at `:835-837`).
    /// So an unknown level is not an error and not a clamp to the nearest
    /// tier. It is also NOT "the model provider's own default", which is
    /// what this notice claimed until P44b — the consumers were walked:
    /// `resolve_reasoning_config` logs `Unknown reasoning_effort '%s', using
    /// default (medium)` and returns `None` (`hermes_constants.py:957-979`,
    /// the warning at `:975-976`); `agent_runtime_helpers.py:2145-2147`
    /// stores that `None` on `agent.reasoning_config`; and the
    /// chat-completions transport then substitutes `medium` EXPLICITLY —
    /// `_effort = (reasoning_config.get("effort", "medium") or "medium") if
    /// reasoning_config and isinstance(reasoning_config, dict) else "medium"`
    /// (`agent/transports/chat_completions.py:420-422`), with the iteration
    /// summary doing the same (`agent/chat_completion_helpers.py:2020`:
    /// `{"enabled": True, "effort": "medium"}`). Only the Anthropic adapter
    /// omits the parameter, leaving the model's own default
    /// (`agent/anthropic_adapter.py:570` — `_thinking_kwargs` runs only for a
    /// truthy dict). Hermes's OWN default is therefore the honest word, and
    /// it is NOT what the empty "Provider default" row means.
    ///
    /// `nil` when the level IS in the host's vocabulary, when the value
    /// DISABLES reasoning on this host (see ``disablingSpellings``), and for
    /// the empty sentinel.
    public static func unsupportedLevelNotice(
        for selected: String,
        capabilities: HermesCapabilities
    ) -> String? {
        guard !selected.isEmpty,
              !levels(capabilities: capabilities).contains(selected),
              !disablingSpellings(capabilities: capabilities).contains(
                  selected.trimmingCharacters(in: .whitespaces).lowercased()
              )
        else { return nil }
        return String(localized: "“\(selected)” isn’t supported on this Hermes — it ignores it and uses its own default effort (medium).")
    }

    /// Values that mean "reasoning off" to THIS host, lowercased.
    ///
    /// The picker never offers `disabled` / `false` / `off`, but config.yaml
    /// may already carry one — and on a host that accepts it, that is
    /// reasoning off exactly as asked, not an unsupported level. P44 gated
    /// the affordance on ``levels(capabilities:)`` alone, which excludes all
    /// three, so `agent.reasoning_effort: disabled` rendered a false "isn't
    /// supported" notice under a picker that had (correctly) widened to show
    /// it.
    ///
    /// `none` is in ``baseLevels`` and is accepted at every supported tag.
    /// The other three are gated on
    /// ``HermesCapabilities/hasReasoningDisableAliases`` (v0.18.1), where
    /// that flag's doc carries the tag walk. Below the floor they are
    /// genuinely unsupported and the notice is correct.
    public static func disablingSpellings(capabilities: HermesCapabilities) -> Set<String> {
        var spellings: Set<String> = ["none"]
        if capabilities.hasReasoningDisableAliases {
            spellings.formUnion(disableAliases)
        }
        return spellings
    }

    /// Whether Hermes's `parse_reasoning_effort` would accept this value.
    public static func isValid(_ effort: String) -> Bool {
        let normalized = effort.trimmingCharacters(in: .whitespaces).lowercased()
        return (baseLevels + [maxLevel, ultraLevel] + disableAliases).contains(normalized)
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
        // The key is TRIMMED for the write, not only for the emptiness
        // test. It used to be trimmed for the `isEmpty` filter and written
        // untrimmed, so a pattern pasted with a trailing space went into
        // config.yaml quoted (`YAMLScalar.quoteIfNeeded` quotes a trailing
        // space, correctly) and never matched a model name — while the row
        // rendered as if it did. `setExcludedProviders` below has trimmed
        // its items all along; this is that sibling's rule.
        let cleaned = pairs
            .map { (key: $0.key.trimmingCharacters(in: .whitespaces),
                    value: Self.canonicalDisableSpelling($0.value)) }
            .filter { !$0.key.isEmpty }
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

    /// Label of the reasoning-override field whose value would reach
    /// config.yaml carrying a control character, or `nil`.
    ///
    /// **Round-4 decision 9.** The pattern is free text
    /// (`AgentTab.swift`'s `ReasoningOverridesSection`) and was the second
    /// surface round-3 decision 6 left unguarded, alongside the MCP entry
    /// editor. It lives beside the writer rather than in the view so the
    /// rule and the emission it guards are one file apart, and so it is
    /// testable without a view host.
    ///
    /// Checked on the pattern as ``setReasoningOverrides(in:pairs:capabilities:)``
    /// WRITES it — trimmed. This is the VISIBILITY guard, not the parse
    /// guard: `YAMLScalar.quoteIfNeeded` represents a control losslessly, so
    /// a pasted ESC does not break the file — it round-trips as the literal
    /// `a\x1bb`, a pattern the user cannot see and which will never match a
    /// model name.
    public static func controlCharacterFieldLabel(pattern: String) -> String? {
        YAMLScalar.containsControlCharacter(
            pattern.trimmingCharacters(in: .whitespaces)
        ) ? "Model pattern" : nil
    }

    /// Label of the field whose value would make PyYAML refuse the whole
    /// document because it is too long to be a mapping key, or `nil`.
    ///
    /// **Round-4, P41b.** The pattern becomes a config.yaml map KEY, and
    /// PyYAML's scanner caps a simple key at 1024 unicode scalars of emitted
    /// token (``YAMLScalar/simpleKeyLimit``) — quoting does not buy headroom,
    /// it spends two characters of it. Unlike the control-character refusal
    /// this one is not about visibility: an over-long key makes `load_config`
    /// discard the ENTIRE config.yaml layer and fall back to `.env`
    /// (`gateway/config.py:775-791` @ `v2026.9.7`), so every unrelated
    /// setting in the file silently reverts.
    ///
    /// Checked on the pattern as ``setReasoningOverrides(in:pairs:capabilities:)``
    /// WRITES it — trimmed — for the same reason the sibling refusal is, and
    /// scoped to the NEW pattern only, not the existing rows a re-save
    /// rewrites (a file that already carries one cannot have loaded at all,
    /// so there is nothing to keep editable).
    public static func oversizedKeyFieldLabel(pattern: String) -> String? {
        YAMLScalar.exceedsSimpleKeyLimit(
            pattern.trimmingCharacters(in: .whitespaces)
        ) ? "Model pattern" : nil
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
        // Hermes lowercases at consumption
        // (`hermes_cli/model_switch_providers.py:1063` @ `v2026.9.7`); keep the
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
