import Testing
@testable import ScarfCore

/// v0.20 power-settings pass (t-f4d59e66): compression tuning keys,
/// `agent.reasoning_overrides` (dict, direct-YAML), and
/// `model_catalog.excluded_providers` (list, direct-YAML).
@Suite struct PowerSettingsV020Tests {

    private func caps(_ major: Int, _ minor: Int) -> HermesCapabilities {
        HermesCapabilities(
            versionLine: "hermes \(major).\(minor).0",
            semver: HermesCapabilities.SemVer(major: major, minor: minor, patch: 0),
            dateVersion: nil
        )
    }
    private var v020: HermesCapabilities { caps(0, 20) }
    private var v019: HermesCapabilities { caps(0, 19) }

    // MARK: - Compression tuning: parse + defaults

    @Test func compressionTuningKeysParse() {
        let cfg = HermesConfig(yaml: """
        compression:
          enabled: true
          threshold: 0.6
          threshold_tokens: 120000
          min_tail_user_messages: 3
          idle_compact_after_seconds: 1800
          progress_notices: true
        """)
        #expect(cfg.compression.thresholdTokens == 120_000)
        #expect(cfg.compression.minTailUserMessages == 3)
        #expect(cfg.compression.idleCompactAfterSeconds == 1800)
        #expect(cfg.compression.progressNotices == true)
    }

    @Test func compressionTuningAbsentKeysUseHermesDefaults() {
        let cfg = HermesConfig(yaml: "compression:\n  enabled: true\n")
        // config_defaults.py: threshold_tokens None → 0 sentinel,
        // min_tail_user_messages 1, idle_compact_after_seconds 0,
        // progress_notices False.
        #expect(cfg.compression.thresholdTokens == 0)
        #expect(cfg.compression.minTailUserMessages == 1)
        #expect(cfg.compression.idleCompactAfterSeconds == 0)
        #expect(cfg.compression.progressNotices == false)
        #expect(CompressionSettings.empty.thresholdTokens == 0)
        #expect(CompressionSettings.empty.minTailUserMessages == 1)
    }

    // MARK: - Reasoning overrides: round-trip

    @Test func reasoningOverridesWriteParseRoundTrip() {
        let base = "agent:\n  reasoning_effort: medium\n"
        let pairs = [
            (key: "claude-opus-4.5", value: "ultra"),
            (key: "gpt-5.2", value: "low"),
        ]
        let updated = PowerSettingsWriter.setReasoningOverrides(
            in: base, pairs: pairs, capabilities: v020
        )
        #expect(updated != nil)
        let cfg = HermesConfig(yaml: updated!)
        #expect(cfg.reasoningOverrides == ["claude-opus-4.5": "ultra", "gpt-5.2": "low"])
        // Sibling scalar preserved.
        #expect(cfg.reasoningEffort == "medium")
    }

    @Test func reasoningOverridesColonAndQuotePatternsRoundTrip() {
        // Ollama-style `llama3:8b` needs quoting (our parser splits on the
        // first colon otherwise) and an embedded single quote must escape.
        let pairs = [
            (key: "llama3:8b", value: "high"),
            (key: "it's-a-model", value: "max"),
        ]
        let updated = PowerSettingsWriter.setReasoningOverrides(
            in: "agent:\n  verbose: false\n", pairs: pairs, capabilities: v020
        )!
        #expect(updated.contains("'llama3:8b': high"))
        let cfg = HermesConfig(yaml: updated)
        #expect(cfg.reasoningOverrides["llama3:8b"] == "high")
        #expect(cfg.reasoningOverrides["it's-a-model"] == "max")
    }

    @Test func reasoningOverridesPreserveUnknownKeysAndComments() {
        let yaml = """
        # top comment
        agent:
          reasoning_effort: high
          future_unknown_key: 42
          reasoning_overrides:
            old-model: low
          verbose: true

        model:
          default: claude-opus-4.5
        """
        let updated = PowerSettingsWriter.setReasoningOverrides(
            in: yaml, pairs: [(key: "new-model", value: "xhigh")], capabilities: v020
        )!
        #expect(updated.contains("# top comment"))
        #expect(updated.contains("future_unknown_key: 42"))
        #expect(updated.contains("verbose: true"))
        #expect(updated.contains("default: claude-opus-4.5"))
        #expect(!updated.contains("old-model"))
        let cfg = HermesConfig(yaml: updated)
        #expect(cfg.reasoningOverrides == ["new-model": "xhigh"])
    }

    @Test func removingLastOverrideDeletesTheKeyEntirely() {
        let yaml = """
        agent:
          reasoning_overrides:
            some-model: high
          verbose: false
        """
        let updated = PowerSettingsWriter.setReasoningOverrides(
            in: yaml, pairs: [], capabilities: v020
        )!
        #expect(!updated.contains("reasoning_overrides"))
        #expect(updated.contains("verbose: false"))
        #expect(HermesConfig(yaml: updated).reasoningOverrides.isEmpty)
        // Idempotent: deleting again is a byte-for-byte no-op.
        #expect(PowerSettingsWriter.setReasoningOverrides(
            in: updated, pairs: [], capabilities: v020
        ) == updated)
    }

    @Test func emptyInlineDictParsesAsAbsent() {
        let cfg = HermesConfig(yaml: "agent:\n  reasoning_overrides: {}\n")
        #expect(cfg.reasoningOverrides.isEmpty)
    }

    // MARK: - Reasoning overrides: validation + gating

    @Test func reasoningOverridesWriterRefusesPreV020() {
        let refused = PowerSettingsWriter.setReasoningOverrides(
            in: "agent:\n", pairs: [(key: "m", value: "high")], capabilities: v019
        )
        #expect(refused == nil)
        #expect(PowerSettingsWriter.setReasoningOverrides(
            in: "agent:\n", pairs: [], capabilities: .empty
        ) == nil)
    }

    @Test func reasoningOverridesWriterRejectsInvalidEffort() {
        let refused = PowerSettingsWriter.setReasoningOverrides(
            in: "agent:\n", pairs: [(key: "m", value: "turbo")], capabilities: v020
        )
        #expect(refused == nil)
    }

    @Test func effortVocabularyMatchesHermes() {
        // hermes_constants.py VALID_REASONING_EFFORTS + the "none" disable
        // alias; max/ultra are v0.20-only picker options.
        #expect(HermesReasoningEffort.levels(capabilities: v020)
            == ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
        #expect(HermesReasoningEffort.levels(capabilities: v019)
            == ["none", "minimal", "low", "medium", "high", "xhigh"])
        #expect(HermesReasoningEffort.isValid("ULTRA"))
        #expect(!HermesReasoningEffort.isValid("extreme"))
        #expect(!HermesReasoningEffort.isValid(""))
    }

    // MARK: - Excluded providers

    @Test func excludedProvidersWriteParseRoundTrip() {
        let yaml = "model:\n  default: claude-opus-4.5\n"
        let updated = PowerSettingsWriter.setExcludedProviders(
            in: yaml, providers: ["openrouter", "vercel"], capabilities: v020
        )!
        let cfg = HermesConfig(yaml: updated)
        #expect(cfg.excludedProviders == ["openrouter", "vercel"])
        #expect(updated.contains("default: claude-opus-4.5"))
        // Stable: rewriting the same list is byte-identical.
        #expect(PowerSettingsWriter.setExcludedProviders(
            in: updated, providers: ["openrouter", "vercel"], capabilities: v020
        ) == updated)
    }

    @Test func excludedProvidersPreservesSiblingKeysInSection() {
        let yaml = """
        model_catalog:
          excluded_providers:
            - old-provider
          refresh_hours: 24
        """
        let updated = PowerSettingsWriter.setExcludedProviders(
            in: yaml, providers: ["groq"], capabilities: v020
        )!
        #expect(updated.contains("refresh_hours: 24"))
        #expect(!updated.contains("old-provider"))
        #expect(HermesConfig(yaml: updated).excludedProviders == ["groq"])
    }

    @Test func removingLastExcludedProviderDeletesTheKey() {
        let yaml = """
        model_catalog:
          excluded_providers:
            - openrouter
          refresh_hours: 24
        """
        let updated = PowerSettingsWriter.setExcludedProviders(
            in: yaml, providers: [], capabilities: v020
        )!
        #expect(!updated.contains("excluded_providers"))
        #expect(updated.contains("refresh_hours: 24"))
        #expect(HermesConfig(yaml: updated).excludedProviders.isEmpty)
    }

    @Test func excludedProvidersWriterRefusesPreV020() {
        #expect(PowerSettingsWriter.setExcludedProviders(
            in: "", providers: ["openrouter"], capabilities: v019
        ) == nil)
    }

    @Test func excludedProvidersAbsentKeyDefaultsEmpty() {
        #expect(HermesConfig(yaml: "model:\n  default: x\n").excludedProviders.isEmpty)
        #expect(HermesConfig.empty.excludedProviders.isEmpty)
        #expect(HermesConfig.empty.reasoningOverrides.isEmpty)
    }

    // MARK: - Fresh-eyes audit regressions (flow dicts, CRLF, aliases)

    @Test func inlineEmptyFlowDictIsReplacedNotDuplicated() {
        // Stock cli-config.yaml.example:916 ships `reasoning_overrides: {}`
        // uncommented — hermes doctor scaffolds user configs from it, so
        // this is the MAINLINE shape. It must be replaced, never duplicated.
        let yaml = "agent:\n  reasoning_effort: medium\n  reasoning_overrides: {}\n  verbose: false\n"
        let updated = PowerSettingsWriter.setReasoningOverrides(
            in: yaml, pairs: [(key: "gpt-5.2", value: "low")], capabilities: v020
        )!
        #expect(occurrences(of: "reasoning_overrides", in: updated) == 1)
        #expect(!updated.contains("{}"))
        #expect(updated.contains("reasoning_effort: medium"))
        #expect(updated.contains("verbose: false"))
        #expect(HermesConfig(yaml: updated).reasoningOverrides == ["gpt-5.2": "low"])
    }

    @Test func inlinePopulatedFlowDictIsReplacedNotDuplicated() {
        let yaml = "agent:\n  reasoning_overrides: {old-model: low}\n"
        let updated = PowerSettingsWriter.setReasoningOverrides(
            in: yaml, pairs: [(key: "new-model", value: "high")], capabilities: v020
        )!
        #expect(occurrences(of: "reasoning_overrides", in: updated) == 1)
        #expect(!updated.contains("old-model"))
        #expect(HermesConfig(yaml: updated).reasoningOverrides == ["new-model": "high"])
    }

    @Test func emptyPairsDeleteInlineFlowDictLine() {
        let yaml = "agent:\n  reasoning_overrides: {a: low}\n  verbose: false\n"
        let updated = PowerSettingsWriter.setReasoningOverrides(
            in: yaml, pairs: [], capabilities: v020
        )!
        #expect(!updated.contains("reasoning_overrides"))
        #expect(updated.contains("verbose: false"))
    }

    @Test func inlineFlowListIsReplacedNotDuplicated() {
        // setList variant of the same bug (`excluded_providers: []`).
        let yaml = "model_catalog:\n  excluded_providers: []\n  refresh_hours: 24\n"
        let updated = PowerSettingsWriter.setExcludedProviders(
            in: yaml, providers: ["groq"], capabilities: v020
        )!
        #expect(occurrences(of: "excluded_providers", in: updated) == 1)
        #expect(!updated.contains("[]"))
        #expect(updated.contains("refresh_hours: 24"))
        #expect(HermesConfig(yaml: updated).excludedProviders == ["groq"])
    }

    @Test func inlinePopulatedFlowListIsReplacedNotDuplicated() {
        let yaml = "model_catalog:\n  excluded_providers: [alpha, beta]\n"
        let updated = PowerSettingsWriter.setExcludedProviders(
            in: yaml, providers: ["groq"], capabilities: v020
        )!
        #expect(occurrences(of: "excluded_providers", in: updated) == 1)
        #expect(!updated.contains("alpha"))
        #expect(HermesConfig(yaml: updated).excludedProviders == ["groq"])
    }

    @Test func flowDictReadBackIsVisibleInParsedConfig() {
        // Hand-written flat flow dicts must be VISIBLE, not silently active.
        let cfg = HermesConfig(yaml: "agent:\n  reasoning_overrides: {a-model: low, 'llama3:8b': high}\n")
        #expect(cfg.reasoningOverrides == ["a-model": "low", "llama3:8b": "high"])
        let empty = HermesConfig(yaml: "agent:\n  reasoning_overrides: {}\n")
        #expect(empty.reasoningOverrides == [:])
        // Trailing comment after the brace tolerated.
        let commented = HermesConfig(yaml: "agent:\n  reasoning_overrides: {b: max}  # note\n")
        #expect(commented.reasoningOverrides == ["b": "max"])
        // Nested/exotic flow falls back to empty (never crashes) — and the
        // writer still replaces the line (covered above), so nothing is
        // silently retained.
        let exotic = HermesConfig(yaml: "agent:\n  reasoning_overrides: {a: {b: c}}\n")
        #expect(exotic.reasoningOverrides == [:])
    }

    @Test func sectionHeaderWithTrailingCommentIsNotDuplicated() {
        // `agent:  # note` used to read as section-missing → a SECOND
        // top-level `agent:` appended → PyYAML last-wins clobbers the
        // original mapping. Must splice into the existing section.
        let yaml = "agent:  # tuning knobs\n  reasoning_effort: medium\n"
        let updated = PowerSettingsWriter.setReasoningOverrides(
            in: yaml, pairs: [(key: "m", value: "low")], capabilities: v020
        )!
        #expect(occurrences(of: "agent:", in: updated) == 1)
        #expect(updated.contains("# tuning knobs"))
        let cfg = HermesConfig(yaml: updated)
        #expect(cfg.reasoningEffort == "medium")
        #expect(cfg.reasoningOverrides == ["m": "low"])
    }

    @Test func crlfFileEditedWithoutDuplicatingSection() {
        let yaml = "agent:\r\n  reasoning_effort: medium\r\n  reasoning_overrides: {}\r\nmodel:\r\n  default: x\r\n"
        let updated = PowerSettingsWriter.setReasoningOverrides(
            in: yaml, pairs: [(key: "m", value: "high")], capabilities: v020
        )!
        #expect(occurrences(of: "agent:", in: updated) == 1)
        #expect(occurrences(of: "reasoning_overrides", in: updated) == 1)
        // Original CRLF flavor preserved; no bare-LF lines introduced.
        #expect(updated.contains("\r\n"))
        #expect(!updated.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(updated.contains("reasoning_effort: medium"))
        #expect(updated.contains("default: x"))
    }

    @Test func crlfFileEditedWithoutDuplicatingListSection() {
        // setList shares the locator — gateway allowlists had the same
        // pre-existing exposure.
        let yaml = "slack:\r\n  reply_to_mode: thread\r\n"
        let updated = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        )
        #expect(occurrences(of: "slack:", in: updated) == 1)
        #expect(updated.contains("\r\n"))
        #expect(!updated.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(updated.contains("reply_to_mode: thread"))
        #expect(updated.contains("- C1"))
    }

    @Test func hermesDisableAliasesAcceptedAndRoundTrippedVerbatim() {
        // parse_reasoning_effort (hermes_constants.py:967) accepts
        // disabled/false/off as "none" aliases — a hand-edited alias row
        // must not brick the save, and the user's spelling is preserved.
        for alias in ["disabled", "false", "off", "none"] {
            #expect(HermesReasoningEffort.isValid(alias))
            let updated = PowerSettingsWriter.setReasoningOverrides(
                in: "agent:\n  verbose: false\n",
                pairs: [(key: "some-model", value: alias)],
                capabilities: v020
            )
            #expect(updated != nil)
            #expect(updated!.contains("some-model: \(alias)"))
        }
        #expect(!HermesReasoningEffort.isValid("bogus"))
        // Aliases are pass-through only — never offered in the picker.
        #expect(!HermesReasoningEffort.levels(capabilities: v020).contains("disabled"))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
