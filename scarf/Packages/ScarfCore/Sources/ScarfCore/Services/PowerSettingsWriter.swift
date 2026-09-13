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
    /// **The quoted-vs-bare gap, accepted** (round-6 decision 4). Hermes's
    /// own set is `{"none", "false", "disabled"}` at every tag from
    /// `v2026.7.7` (`hermes_constants.py:816`) through `v2026.9.7` (`:885`),
    /// and `off` is in neither it nor `VALID_REASONING_EFFORTS`. So BARE
    /// `reasoning_effort: off` is disabled — PyYAML resolves it to `False`
    /// and `str(False).strip().lower()` is `"false"` — while QUOTED
    /// `reasoning_effort: "off"` stays the string `off`, matches neither
    /// set, and `parse_reasoning_effort` returns `None`, i.e. the host
    /// silently uses its default effort. Scarf's reader unquotes, so both
    /// spellings look identical to it and no notice can distinguish them.
    /// Not fixed: the quoted form can only come from a hand-edited config,
    /// the picker offers `none`, and the next save through this writer
    /// canonicalises it away.
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
    /// An empty `selected` (the "Hermes default" sentinel, which the two
    /// top-level pickers prepend themselves) widens nothing.
    public static func levels(capabilities: HermesCapabilities, selected: String) -> [String] {
        let base = levels(capabilities: capabilities)
        // Two questions, two comparisons. The ROW is a `Picker` tag, and the
        // Picker's tags and its selection are the RAW stored string
        // (`AgentTab.swift:50-58`, `AuxiliaryTab.swift:280-289`,
        // `SettingsComponents.swift:212-218`) — so membership here must be
        // asked RAW too, or `Max` finds no tag and the control renders BLANK,
        // which is the exact failure this overload exists to prevent. The
        // NOTICE is a question about the HOST, so it compares normalised
        // (`unsupportedLevelNotice`) and `Max` draws no warning. P45 asked
        // both questions of the normalised form and blanked the picker.
        //
        // Emptiness is asked of the NORMALISED string: a whitespace-only
        // value is Hermes's own absent-key case (`str(effort).strip()` is
        // empty, `hermes_constants.py:884` @ `v2026.9.7`), so it is the
        // "Hermes default" sentinel — no extra row, and no notice either.
        guard !normalizedLevel(selected).isEmpty, !base.contains(selected) else { return base }
        return [selected] + base
    }

    /// The string a `Picker` must be given as its SELECTION for a stored
    /// `reasoning_effort`, so that it always matches one of the tags
    /// ``levels(capabilities:selected:)`` produced.
    ///
    /// P46b: ``levels(capabilities:selected:)`` treats a whitespace-only
    /// value as the "Hermes default" sentinel and widens nothing — correct,
    /// because `str(effort).strip()` is empty to Hermes
    /// (`hermes_constants.py:884` @ `v2026.9.7`). But the sentinel ROW the
    /// two top-level pickers prepend is tagged with the EMPTY string, and
    /// the binding handed the picker the RAW `"  "`, which matches no tag —
    /// so the control rendered blank, which is the exact failure decision 13
    /// exists to prevent, one layer below where P46 fixed it.
    ///
    /// Everything else passes through RAW: a widened row's tag is the raw
    /// stored string (`Max`, `" high "`), and a pick the user makes still
    /// writes whatever the tag says.
    ///
    /// One function rather than three `isEmpty` tests at the call sites —
    /// `AgentTab`'s top-level picker, `AgentTab`'s per-model override rows
    /// and `AuxiliaryTab`'s per-task picker — because three copies of this
    /// question is how the raw/normalised split went wrong in the first
    /// place.
    public static func pickerSelection(for raw: String) -> String {
        normalizedLevel(raw).isEmpty ? "" : raw
    }

    /// The `agent.reasoning_overrides` rows that result from adding
    /// `pattern` at `effort` to `existing`, applying round-5 decision 16's
    /// EXACT replace-on-add.
    ///
    /// Extracted in P51b because it was not extracted in P51: the rule lived
    /// inline in `AgentTab.addNew` and the test that was supposed to cover it
    /// had a private RE-IMPLEMENTATION beside a comment calling itself "the
    /// function the view now uses". A re-implementation cannot fail when the
    /// view drifts, so decision 16's only real signal was a
    /// `caseInsensitiveCompare` grep — a pin on one spelling of the bug
    /// rather than on the rule.
    ///
    /// The rule: a key already present with the SAME spelling is replaced
    /// (so adding a pattern twice does not duplicate the row); a key that
    /// differs only in CASE is a different override and survives. Hermes's
    /// lookup is a plain dict membership test — `variant in overrides` in
    /// `resolve_per_model_reasoning_effort` (`hermes_constants.py:929-941` @
    /// `v2026.9.7`) over the variants `_canonical_model_variants` derives
    /// (`:892-926`), which recover dots↔dashes and add/strip provider
    /// prefixes but NEVER change case. `Claude-Opus` and `claude-opus` are
    /// two live entries, and the case-insensitive filter that used to stand
    /// in the view deleted one of them from the FILE, because
    /// ``PowerSettingsWriter/setReasoningOverrides(in:pairs:capabilities:)`` rewrites the whole
    /// block from what the editor holds.
    public static func overridesAfterAdding(
        pattern: String,
        effort: String,
        to existing: [(key: String, value: String)]
    ) -> [(key: String, value: String)] {
        var pairs = existing.filter { $0.key != pattern }
        pairs.append((key: pattern, value: effort))
        return pairs
    }

    /// What Hermes itself does to the stored value before it compares:
    /// `effort = str(effort).strip().lower()` — `hermes_constants.py:884` @
    /// `v2026.9.7`, and the same line at `:807` @ `v2026.7.1`, i.e. on both
    /// sides of the `max`/`ultra` floors this file gates on.
    ///
    /// So `Max` and `" high "` are ACCEPTED values, and comparing the raw
    /// string against the vocabulary made ``unsupportedLevelNotice`` claim
    /// `" high "` was ignored.
    ///
    /// Which question gets the normalised form is the whole subtlety, and
    /// P45 got it wrong one way and P46 corrected it:
    ///
    /// - The **notice** and the disable-alias check are questions about the
    ///   HOST, so they compare NORMALISED — `Max` draws no warning.
    /// - The **row** is a `Picker` tag, and a tag has to equal what is on
    ///   disk, so ``levels(capabilities:selected:)`` compares RAW. `Max`
    ///   therefore sits beside the canonical `max` as a second, cased row.
    ///   That duplicate is BY DESIGN, not the drift P45 read it as: the
    ///   alternative is a control with no tag for its own value, which
    ///   renders blank.
    /// - **Emptiness** is asked of the normalised form on both sides, since
    ///   a whitespace-only value is Hermes's absent-key case — see
    ///   ``pickerSelection(for:)``, which is how a binding says so.
    /// P46b: `.whitespacesAndNewlines`, not `.whitespaces`. Python's
    /// `str.strip()` with no argument strips every whitespace character,
    /// newlines and tabs included; `CharacterSet.whitespaces` is spaces and
    /// tabs only, so a value carrying a newline (a hand-edited block scalar,
    /// a paste) read as non-empty here and as the ABSENT key to Hermes.
    public static func normalizedLevel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    /// default (medium)` and returns `None` (`hermes_constants.py:957-980`,
    /// the warning at `:978-979`); `agent_runtime_helpers.py:2145-2147`
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
    /// it is NOT what the empty "Hermes default" row means — that row is the
    /// ABSENT key, which the same walk shows also resolves to Hermes's
    /// `medium`, so P45 relabelled it "Hermes default".
    ///
    /// `nil` when the level IS in the host's vocabulary, when the value
    /// DISABLES reasoning on this host (see ``disablingSpellings``), and for
    /// the empty sentinel.
    public static func unsupportedLevelNotice(
        for selected: String,
        capabilities: HermesCapabilities
    ) -> String? {
        let normalized = normalizedLevel(selected)
        guard !normalized.isEmpty,
              !levels(capabilities: capabilities).contains(normalized),
              !disablingSpellings(capabilities: capabilities).contains(normalized)
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
        // test — and with the WIDE `.whitespaces`, which stays wide
        // (P51b finding 7, disagreed with). This is a writer-side cleanup of
        // a field the USER typed, not a parser trim: decision 14 narrowed
        // `HermesYAML`'s reader to space+tab because PyYAML keeps a `Zs`
        // character as scalar CONTENT. Here that same fidelity would be the
        // bug — Hermes compares an override key EXACTLY (`variant in
        // overrides`, `hermes_constants.py:929-941` @ `v2026.9.7`, over
        // `_canonical_model_variants` at `:892-926`, which never strips), so
        // a pattern pasted with a trailing U+00A0 and left untrimmed is
        // written quoted and matches no model for the life of the entry.
        // "Exact" in decision 16 is about CASE, not about whitespace. It used to be trimmed for the `isEmpty` filter and written
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
