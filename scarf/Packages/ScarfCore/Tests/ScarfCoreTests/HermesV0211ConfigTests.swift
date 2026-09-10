import Testing
import Foundation
@testable import ScarfCore

/// Phase 1 of the Hermes v0.21.1 (tag v2026.9.7) parity cycle — the
/// `agent.service_tier` bounded modes (A4), the split telemetry opt-ins
/// (A5) and the new Settings config keys (C9).
///
/// Every default asserted here was read off `hermes_cli/config_defaults.py`
/// at v2026.9.7 (and, for `model.streaming`, off its only reader,
/// `agent/agent_init.py:1184`, which is where its `"true"` default lives).
/// Four of the new keys default TRUE upstream, which is the whole reason
/// these tests exist: a parser that defaulted them to `false` would render
/// every one of those toggles off while the host did the opposite.
@Suite("Hermes v0.21.1 config parsing")
struct HermesV0211ConfigTests {

    // MARK: - agent.service_tier (A4)

    /// Every spelling Hermes's `_parse_service_tier_config` maps onto
    /// `None` (cli.py:277 @ v2026.9.7). A drift alarm: if upstream adds or
    /// drops an alias, this fixture is what catches it.
    @Test(arguments: ["", "normal", "default", "standard", "off", "none", "  NORMAL  "])
    func serviceTierOffAliases(_ raw: String) {
        #expect(HermesServiceTier.normalize(raw) == .off)
    }

    /// Every spelling mapped onto `"priority"` (cli.py:279).
    @Test(arguments: ["fast", "priority", "on", "Priority", " FAST "])
    func serviceTierAlwaysAliases(_ raw: String) {
        #expect(HermesServiceTier.normalize(raw) == .always)
    }

    /// The two v0.21.1 bounded modes (`agent/fast_mode.py:16`).
    @Test func serviceTierBoundedModes() {
        #expect(HermesServiceTier.normalize("auto") == .auto)
        #expect(HermesServiceTier.normalize("cold") == .cold)
        #expect(HermesServiceTier.auto.isBounded)
        #expect(HermesServiceTier.cold.isBounded)
        #expect(!HermesServiceTier.off.isBounded)
        #expect(!HermesServiceTier.always.isBounded)
    }

    /// Anything else is warn-and-ignore upstream, i.e. the host runs the
    /// normal tier — so the picker must say Off, not invent a fifth state.
    @Test func serviceTierUnknownValueReadsAsOff() {
        #expect(HermesServiceTier.normalize("turbo") == .off)
    }

    /// The values Scarf writes. `off`/`always` deliberately keep the
    /// aliases the old Bool toggle wrote so an upgrade causes no config
    /// churn; both are exact synonyms in the parser on every supported host.
    @Test func serviceTierWritesTheAliasesScarfHasAlwaysWritten() {
        #expect(HermesServiceTier.off.configValue == "normal")
        #expect(HermesServiceTier.always.configValue == "fast")
        #expect(HermesServiceTier.auto.configValue == "auto")
        #expect(HermesServiceTier.cold.configValue == "cold")
        // Round-trip: what Scarf writes must read back as what it wrote.
        for tier in HermesServiceTier.allCases {
            #expect(HermesServiceTier.normalize(tier.configValue) == tier)
        }
    }

    /// Pre-target host: exactly the two values the Bool toggle round-tripped.
    @Test func serviceTierOptionsOnPreTargetHostAreTheTogglePair() {
        let v0210 = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(!v0210.hasServiceTierBoundedModes)
        #expect(HermesServiceTier.options(capabilities: v0210, current: .off) == [.off, .always])
        #expect(HermesServiceTier.options(capabilities: v0210, current: .always) == [.off, .always])
    }

    /// …but a value already on disk that the host can't use stays VISIBLE
    /// rather than rendering as a blank picker that overwrites it.
    @Test func serviceTierOptionsKeepAnUnsupportedCurrentValue() {
        let v0210 = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(HermesServiceTier.options(capabilities: v0210, current: .cold) == [.off, .always, .cold])
    }

    @Test func serviceTierOptionsOnTargetHostAreAllFour() {
        let v0211 = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(v0211.hasServiceTierBoundedModes)
        #expect(HermesServiceTier.options(capabilities: v0211, current: .off) == [.off, .always, .auto, .cold])
    }

    /// An unknown host version must not offer values it may not understand.
    @Test func serviceTierOptionsOnUnknownHostAreTheTogglePair() {
        #expect(!HermesCapabilities.empty.hasServiceTierBoundedModes)
        #expect(HermesServiceTier.options(capabilities: .empty, current: .off) == [.off, .always])
    }

    @Test func fastAutoSecondsDefaultsTo60() {
        #expect(HermesConfig(yaml: "").agentFastAutoSeconds == 60)
    }

    @Test func fastAutoSecondsReadsExplicitValue() {
        let cfg = HermesConfig(yaml: """
        agent:
          service_tier: auto
          fast_auto_seconds: 15
        """)
        #expect(cfg.agentFastAutoSeconds == 15)
        #expect(HermesServiceTier.normalize(cfg.serviceTier) == .auto)
    }

    // MARK: - telemetry.shared_metrics (A5)

    /// Collection and transmission are two independent opt-ins, both off
    /// by default.
    @Test func sharedMetricsSendDefaultsOff() {
        let cfg = HermesConfig(yaml: "")
        #expect(!cfg.telemetry.sharedMetricsEnabled)
        #expect(!cfg.telemetry.sharedMetricsSend)
        #expect(cfg.telemetry.sharedMetricsEndpoint.isEmpty)
    }

    @Test func sharedMetricsSendIsReadIndependentlyOfEnabled() {
        let cfg = HermesConfig(yaml: """
        telemetry:
          shared_metrics:
            enabled: false
            send: true
        """)
        // The UI must show the TRUE stored state; Hermes is what refuses to
        // transmit without `enabled`, and it logs an error when asked to.
        #expect(!cfg.telemetry.sharedMetricsEnabled)
        #expect(cfg.telemetry.sharedMetricsSend)
    }

    /// Absent endpoint → the upstream default's host, which is what the
    /// Advanced-tab copy names.
    @Test func sharedMetricsEndpointHostFallsBackToUpstreamDefault() {
        #expect(HermesConfig(yaml: "").telemetry.sharedMetricsEndpointHost == "telemetry.nousresearch.com")
    }

    @Test func sharedMetricsEndpointHostUsesTheConfiguredOverride() {
        let cfg = HermesConfig(yaml: """
        telemetry:
          shared_metrics:
            enabled: true
            send: true
            endpoint: https://staging.example.test/v1/telemetry
        """)
        #expect(cfg.telemetry.sharedMetricsEndpoint == "https://staging.example.test/v1/telemetry")
        #expect(cfg.telemetry.sharedMetricsEndpointHost == "staging.example.test")
    }

    /// A garbage endpoint must not blank the copy — it falls back to the
    /// default host rather than rendering "…uploaded to ".
    @Test func sharedMetricsEndpointHostSurvivesAnUnparseableValue() {
        let cfg = HermesConfig(yaml: """
        telemetry:
          shared_metrics:
            endpoint: not a url
        """)
        #expect(!cfg.telemetry.sharedMetricsEndpointHost.isEmpty)
    }

    // MARK: - C9 config keys: the TRUE-by-default four

    /// The whole point of this test: an absent key on these four means the
    /// host is doing the thing, so the parse must say `true`.
    @Test func trueByDefaultKeysReadTrueWhenAbsent() {
        let cfg = HermesConfig(yaml: "")
        #expect(cfg.updatesCheck)
        #expect(cfg.gatewayTrustEnv)
        #expect(cfg.modelStreaming)
        #expect(cfg.toolLoopNonInteractiveHardStop)
        #expect(cfg.display.resumeLastSession)
    }

    @Test func trueByDefaultKeysReadAnExplicitFalse() {
        let cfg = HermesConfig(yaml: """
        updates:
          check: false
        gateway:
          trust_env: false
        model:
          streaming: false
        tool_loop_guardrails:
          non_interactive_hard_stop_enabled: false
        display:
          resume_last_session: false
        """)
        #expect(!cfg.updatesCheck)
        #expect(!cfg.gatewayTrustEnv)
        #expect(!cfg.modelStreaming)
        #expect(!cfg.toolLoopNonInteractiveHardStop)
        #expect(!cfg.display.resumeLastSession)
    }

    /// A true-by-default key must not be flipped ON by a falsy spelling
    /// the literal `== "true"` reader would have missed. Hermes's own
    /// reader for `model.streaming` disables on any of these
    /// (`agent/agent_init.py`), and PyYAML turns the same words into
    /// `False` for the config_defaults-backed keys.
    @Test(arguments: ["no", "off", "0", "False", " FALSE "])
    func trueByDefaultKeysHonourEveryFalsySpelling(_ falsy: String) {
        let cfg = HermesConfig(yaml: """
        updates:
          check: \(falsy)
        model:
          streaming: \(falsy)
        display:
          resume_last_session: \(falsy)
        """)
        #expect(!cfg.updatesCheck)
        #expect(!cfg.modelStreaming)
        #expect(!cfg.display.resumeLastSession)
    }

    /// …and a truthy spelling still reads ON.
    @Test func trueByDefaultKeysStayOnForATruthyValue() {
        let cfg = HermesConfig(yaml: """
        updates:
          check: yes
        """)
        #expect(cfg.updatesCheck)
    }

    /// `model.streaming` is a PROVIDER-request switch; `display.streaming`
    /// is terminal rendering. They must never be conflated — the pair is
    /// the reason this key gets its own row and its own field.
    @Test func modelStreamingIsIndependentOfDisplayStreaming() {
        let cfg = HermesConfig(yaml: """
        display:
          streaming: false
        model:
          streaming: true
        """)
        #expect(!cfg.streaming)
        #expect(cfg.modelStreaming)
    }

    // MARK: - C9 config keys: the FALSE/0-by-default rest

    @Test func bellOnPromptDefaultsFalseAndIsSeparateFromBellOnComplete() {
        #expect(!HermesConfig(yaml: "").display.bellOnPrompt)
        let cfg = HermesConfig(yaml: """
        display:
          bell_on_complete: false
          bell_on_prompt: true
        """)
        #expect(!cfg.display.bellOnComplete)
        #expect(cfg.display.bellOnPrompt)
    }

    @Test func delegationV0211KeysDefaultOff() {
        let cfg = HermesConfig(yaml: "")
        #expect(!cfg.delegation.independentCompletions)
        #expect(cfg.delegation.compressionThresholdTokens == 0)
    }

    @Test func delegationV0211KeysReadExplicitValues() {
        let cfg = HermesConfig(yaml: """
        delegation:
          independent_completions: true
          compression_threshold_tokens: 200000
        """)
        #expect(cfg.delegation.independentCompletions)
        #expect(cfg.delegation.compressionThresholdTokens == 200_000)
    }

    /// Hermes enables the subagent compaction cap only at >= 16000 and
    /// warns-and-ignores anything in between, so the Settings stepper steps
    /// by exactly that floor: 0 (off) → 16000 → 32000, never into the dead
    /// band.
    @Test func compressionThresholdFloorMatchesHermes() {
        #expect(DelegationSettings.compressionThresholdTokensMinimum == 16_000)
    }

    // MARK: - Scalar normalisation (H2)

    /// `parseNestedYAML` keeps everything after `key: ` verbatim, so a
    /// trailing ` # comment` and surrounding quotes ride along with the
    /// value. Both are legal YAML for the same scalar; a typed reader that
    /// compares the raw text matches neither — and for a TRUE-by-default
    /// key that means an explicit `false` reads as ON, then one Settings
    /// save writes the `true` back over the user's choice.
    @Test(arguments: ["false", "false  # was true", "false\t# off",
                      "\"false\"", "'false'", "\"false\"  # quoted + comment",
                      "False", "no", "off", "0", " off "])
    func falsySpellingsTurnOffATrueByDefaultKey(_ spelling: String) {
        let cfg = HermesConfig(yaml: """
        display:
          resume_last_session: \(spelling)
        gateway:
          trust_env: \(spelling)
        updates:
          check: \(spelling)
        model:
          streaming: \(spelling)
        tool_loop_guardrails:
          non_interactive_hard_stop_enabled: \(spelling)
        """)
        #expect(!cfg.display.resumeLastSession, "resume_last_session: \(spelling)")
        #expect(!cfg.gatewayTrustEnv, "gateway.trust_env: \(spelling)")
        #expect(!cfg.updatesCheck, "updates.check: \(spelling)")
        #expect(!cfg.modelStreaming, "model.streaming: \(spelling)")
        #expect(!cfg.toolLoopNonInteractiveHardStop, "hard_stop: \(spelling)")
    }

    /// The other direction: a truthy spelling with a comment or quotes must
    /// stay ON for a FALSE-by-default key.
    @Test(arguments: ["true", "true  # explicitly on", "\"true\"", "'true'", "True"])
    func truthySpellingsTurnOnAFalseByDefaultKey(_ spelling: String) {
        let cfg = HermesConfig(yaml: """
        display:
          bell_on_prompt: \(spelling)
        """)
        #expect(cfg.display.bellOnPrompt, "bell_on_prompt: \(spelling)")
    }

    /// Numeric readers share the normaliser — an int with a trailing
    /// comment used to fall back to the default silently.
    @Test func numericScalarsTolerateCommentsAndQuotes() {
        let cfg = HermesConfig(yaml: """
        delegation:
          compression_threshold_tokens: 32000  # two ticks
        """)
        #expect(cfg.delegation.compressionThresholdTokens == 32_000)
    }

    /// A `#` that is not preceded by whitespace is part of the value, per
    /// YAML — the normaliser must not eat it.
    @Test func hashWithoutLeadingSpaceIsPartOfTheValue() {
        #expect(HermesYAML.normalizedScalar("a#b") == "a#b")
        #expect(HermesYAML.normalizedScalar("a#b # note") == "a#b")
        #expect(HermesYAML.normalizedScalar("# whole line") == "")
    }

    /// Pre-target parity: `<platform>.gateway_restart_notification` reads
    /// through the same helper, so a commented `false` must survive.
    @Test func platformRestartNotificationHonoursACommentedFalse() {
        let cfg = HermesConfig(yaml: """
        slack:
          gateway_restart_notification: false  # too noisy
          allowed_channels:
            - C123
        """)
        #expect(cfg.gatewayPlatforms["slack"]?.gatewayRestartNotification == false)
    }

    // MARK: - M8 — the Fast Mode row's control is host-gated (C1)

    /// A pre-target host, and an undetected one, keep the Bool toggle they
    /// have always rendered. Replacing it with a picker there changes what
    /// an unchanged host looks like and buys nothing: `auto`/`cold` are
    /// warn-and-ignored by that parser.
    @Test func fastModeRendersTheToggleBelowV0211AndThePickerAtOrAbove() {
        #expect(HermesServiceTier.editorStyle(capabilities: .empty) == .toggle)
        #expect(HermesServiceTier.editorStyle(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")) == .toggle)
        #expect(HermesServiceTier.editorStyle(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")) == .picker)
        #expect(HermesServiceTier.editorStyle(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.22.0 (2026.10.1)")) == .picker)
    }

    /// A probe that failed reads as `.empty` — every floor false — but the
    /// config on disk may genuinely hold a bounded `auto`/`cold`. Rendering
    /// the Bool toggle there showed it as "off" and rewrote the key to
    /// `normal` on the first tap, destroying a value Scarf had no grounds to
    /// call invalid. That one state falls through to the picker.
    @Test func probeFailedButBoundedStoredValueRendersThePickerNotTheToggle() {
        for stored in [HermesServiceTier.auto, .cold] {
            #expect(HermesServiceTier.editorStyle(capabilities: .empty, current: stored) == .picker,
                    "\(stored) on an undetected host must not get the lossy toggle")
            // Same on a genuinely pre-target host that was downgraded under a
            // config written by a newer one.
            #expect(HermesServiceTier.editorStyle(
                capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)"),
                current: stored) == .picker)
        }
        // The unbounded values are untouched: a pre-target host still gets
        // exactly the toggle it always rendered (C1).
        for stored in [HermesServiceTier.off, .always] {
            #expect(HermesServiceTier.editorStyle(capabilities: .empty, current: stored) == .toggle)
            #expect(HermesServiceTier.editorStyle(
                capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)"),
                current: stored) == .toggle)
        }
    }

    /// End-to-end for the same bug through the real entry points: the value
    /// on disk normalizes to a bounded mode, the editor is the picker, the
    /// picker lists that mode, and round-tripping the selection writes the
    /// SAME scalar back rather than `normal`.
    @Test func boundedStoredValueSurvivesOnAnUndetectedHost() {
        for raw in ["auto", " Cold ", "COLD"] {
            let tier = HermesServiceTier.normalize(raw)
            #expect(tier.isBounded, "\(raw) should normalize to a bounded mode")
            #expect(HermesServiceTier.editorStyle(capabilities: .empty, current: tier) == .picker)
            let options = HermesServiceTier.options(capabilities: .empty, current: tier)
            #expect(options.contains(tier), "picker must list the stored \(raw)")
            #expect(options == [.off, .always, tier], "widened at the end, order preserved")
            // Re-selecting what is already selected is a no-op on the file.
            #expect(tier.configValue == raw.trimmingCharacters(in: .whitespaces).lowercased())
        }
    }
}
