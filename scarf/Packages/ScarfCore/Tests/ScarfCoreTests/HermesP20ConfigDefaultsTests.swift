import Testing
import Foundation
@testable import ScarfCore

/// P20 — config-read defaults and platform read paths.
///
/// Every expectation here fails against the pre-P20 parser. The Hermes side of
/// each claim was verified in BOTH layers (`hermes_cli/config_defaults.py` and
/// the key's own reader) at tag `v2026.9.7`, and any default that changed
/// inside the supported window (>= v0.6.0) was walked across all 32 `v2026.*`
/// tags by extracting `DEFAULT_CONFIG` at each one — a changed default is a
/// sentinel plus a `display…(capabilities:)` resolver, never a literal.
@Suite("P20 config defaults and platform read paths")
struct HermesP20ConfigDefaultsTests {

    /// A config that mentions no key this suite cares about, so every
    /// expectation below is about the ABSENT-key path.
    private static let bare = "model:\n  default: x\n"

    private static func caps(_ version: String) -> HermesCapabilities {
        HermesCapabilities.parse("Hermes Agent v\(version) (2026.1.1)")
    }

    // MARK: - Absent-key defaults that are stable across the window (literals)

    /// `config_defaults.py:1194,1200,1203` @ v2026.9.7 and the reader
    /// `agent/agent_init.py:1263,1266`. Identical at every tag from v2026.3.30
    /// (v0.6.0) on, so these are literals, not sentinels. `nudge_interval` is
    /// in the schema only from v2026.8.19 (v0.20.5) but its reader has
    /// defaulted to 10 since the key's first reader (v2026.5.28 / v0.15.0), so
    /// the effective default is 10 throughout.
    ///
    /// Pre-P20 these parsed to `false`/0/0/0.
    @Test func memoryDefaultsAreHermesOwn() {
        let c = HermesConfig(yaml: Self.bare)
        #expect(c.memoryEnabled)
        #expect(c.memoryCharLimit == 2200)
        #expect(c.userCharLimit == 1375)
        #expect(c.nudgeInterval == 10)
    }

    /// The three memory steppers in `MemoryTab` range `500...10_000`,
    /// `500...10_000` and `1...50`. With the old 0 defaults an absent key
    /// rendered each row OUTSIDE its own range, so the first tap jumped to the
    /// range floor and wrote 500/500/1 over host defaults of 2200/1375/10.
    /// This pins the invariant the tab depends on: the resolved default is a
    /// value the stepper can actually display and step from.
    @Test func memoryDefaultsSitInsideTheirStepperRanges() {
        let c = HermesConfig(yaml: Self.bare)
        #expect((500...10_000).contains(c.memoryCharLimit))
        #expect((500...10_000).contains(c.userCharLimit))
        #expect((1...50).contains(c.nudgeInterval))
    }

    /// `config_defaults.py:318-321` @ v2026.9.7, unchanged at every tag from
    /// v2026.3.30 (v0.6.0). Pre-P20 these parsed to 0/0/0/false, i.e. "no CPU,
    /// no memory, no disk, wiped between sessions".
    @Test func containerLimitDefaultsAreHermesOwn() {
        let c = HermesConfig(yaml: Self.bare)
        #expect(c.terminal.containerCPU == 1)
        #expect(c.terminal.containerMemory == 5120)
        #expect(c.terminal.containerDisk == 51200)
        #expect(c.terminal.containerPersistent)
    }

    /// `config_defaults.py:1121` @ v2026.9.7 (`"auto_tts": False`) and the
    /// reader `hermes_cli/cli_voice_mixin.py:516`
    /// (`.get("auto_tts", False)`); `False` at every tag in the window.
    /// Pre-P20 an absent key read ON — the toggle claimed every reply would be
    /// spoken aloud.
    @Test func autoTTSDefaultsOff() {
        #expect(!HermesConfig(yaml: Self.bare).autoTTS)
        #expect(HermesConfig(yaml: "voice:\n  auto_tts: yes\n").autoTTS)
    }

    /// `config_defaults.py:2174` @ v2026.9.7, and `True` at the key's very
    /// first appearance (v2026.5.28 / v0.15.0 — no earlier tag has a
    /// `bitwarden` section at all). Pre-P20 an absent key read OFF.
    @Test func bitwardenOverrideExistingDefaultsOn() {
        #expect(HermesConfig(yaml: Self.bare).bitwarden.overrideExisting)
        #expect(!HermesConfig(yaml: "secrets:\n  bitwarden:\n    override_existing: 'off'\n").bitwarden.overrideExisting)
    }

    /// `telegram.require_mention` is in NO schema layer at any of the 32
    /// `v2026.*` tags, so the reader's own fallback is the default:
    /// `_extra_bool("require_mention", "TELEGRAM_REQUIRE_MENTION", "false")`
    /// (`plugins/platforms/telegram/adapter.py:5030` @ v2026.9.7). Scarf
    /// carried `true` as a known divergence through P17; P20 corrects it.
    @Test func telegramRequireMentionDefaultsOff() {
        #expect(!HermesConfig(yaml: Self.bare).telegram.requireMention)
    }

    // MARK: - Defaults that CHANGED inside the window (sentinel + resolver)

    /// `display.show_reasoning` flipped `False` → `True` at tag **v2026.7.7
    /// (v0.18.1)** and stayed true through v2026.9.7 (`config_defaults.py:784`,
    /// reader `cli.py:2584`). v2026.7.1 (v0.18.0) is the last `False`.
    ///
    /// Pre-P20 the parse baked in `false`, so the toggle rendered OFF on every
    /// stock v0.18.1+ host that streams reasoning live.
    @Test func showReasoningIsASentinelResolvedAtV0181() {
        let absent = HermesConfig(yaml: Self.bare)
        #expect(absent.showReasoning == nil)
        #expect(absent.displayShowReasoning(capabilities: Self.caps("0.18.1")))
        #expect(absent.displayShowReasoning(capabilities: Self.caps("0.21.1")))
        #expect(!absent.displayShowReasoning(capabilities: Self.caps("0.18.0")))
        #expect(!absent.displayShowReasoning(capabilities: Self.caps("0.6.0")))
        // Unknown host resolves to the OLDER default, per the
        // `displayGatewayTurnLeaseTimeout` convention.
        #expect(!absent.displayShowReasoning(capabilities: .empty))
        // A present key always wins over the host default, in both directions.
        let off = HermesConfig(yaml: "display:\n  show_reasoning: false\n")
        #expect(!off.displayShowReasoning(capabilities: Self.caps("0.21.1")))
        let on = HermesConfig(yaml: "display:\n  show_reasoning: 'on'\n")
        #expect(on.displayShowReasoning(capabilities: Self.caps("0.6.0")))
    }

    /// `approvals.timeout` went 60 → 300 at tag **v2026.7.30 (v0.19.1)**, the
    /// first tag with `config_defaults.py` (`:1535` @ v2026.9.7; the reader
    /// `tools/approval_context.py:240` agrees and its docstring names the
    /// reason). v2026.7.20 (v0.19.0) still ships 60, as does every tag back to
    /// v2026.3.30 (v0.6.0).
    @Test func approvalTimeoutIsASentinelResolvedAtV0191() {
        let absent = HermesConfig(yaml: Self.bare)
        #expect(absent.approvalTimeout == 0)
        #expect(absent.displayApprovalTimeout(capabilities: Self.caps("0.19.1")) == 300)
        #expect(absent.displayApprovalTimeout(capabilities: Self.caps("0.21.1")) == 300)
        #expect(absent.displayApprovalTimeout(capabilities: Self.caps("0.19.0")) == 60)
        #expect(absent.displayApprovalTimeout(capabilities: .empty) == 60)
        let set = HermesConfig(yaml: "approvals:\n  timeout: 45\n")
        #expect(set.displayApprovalTimeout(capabilities: Self.caps("0.21.1")) == 45)
    }

    /// `agent.gateway_notify_interval` went 600 → 180 at tag **v2026.4.23
    /// (v0.11.0)** and holds through v2026.9.7 (`config_defaults.py:196`);
    /// v2026.4.13/v2026.4.16 (v0.9.0/v0.10.0) ship 600 and no earlier tag has
    /// the key.
    ///
    /// A TRUE optional, not a 0 sentinel: `0` means "no still-working notices"
    /// and must survive the round trip.
    @Test func gatewayNotifyIntervalIsATrueOptionalResolvedAtV011() {
        let absent = HermesConfig(yaml: Self.bare)
        #expect(absent.gatewayNotifyInterval == nil)
        #expect(absent.displayGatewayNotifyInterval(capabilities: Self.caps("0.11.0")) == 180)
        #expect(absent.displayGatewayNotifyInterval(capabilities: Self.caps("0.21.1")) == 180)
        #expect(absent.displayGatewayNotifyInterval(capabilities: Self.caps("0.10.0")) == 600)
        #expect(absent.displayGatewayNotifyInterval(capabilities: .empty) == 600)
        // An explicit 0 is a real setting and must NOT resolve to a default.
        let off = HermesConfig(yaml: "agent:\n  gateway_notify_interval: 0\n")
        #expect(off.gatewayNotifyInterval == 0)
        #expect(off.displayGatewayNotifyInterval(capabilities: Self.caps("0.21.1")) == 0)
    }

    /// `approvals.mode` flipped `manual` → `smart` at tag **v2026.7.20
    /// (v0.19.0)** (`config_defaults.py:1534` @ v2026.9.7); every tag from
    /// v2026.3.17 (v0.3.0) through v2026.7.7.2 (v0.18.2) ships `manual`.
    ///
    /// Pre-P20 the parse baked in `manual`, telling every stock v0.19+ user
    /// that Scarf would ask before each guarded command while the guardian
    /// model was actually deciding. Product decision 5: an absent key renders
    /// a distinct host-default row and writes nothing.
    @Test func approvalModeIsASentinelResolvedAtV019() {
        let absent = HermesConfig(yaml: Self.bare)
        #expect(absent.approvalMode.isEmpty)
        #expect(absent.storedApprovalMode == nil)
        #expect(absent.displayApprovalMode(capabilities: Self.caps("0.19.0")) == .smart)
        #expect(absent.displayApprovalMode(capabilities: Self.caps("0.21.1")) == .smart)
        #expect(absent.displayApprovalMode(capabilities: Self.caps("0.18.2")) == .manual)
        // An UNDETECTED host is not guessed at in either direction.
        #expect(absent.displayApprovalMode(capabilities: .empty) == nil)
        #expect(absent.approvalModeHostDefaultLabel(capabilities: Self.caps("0.19.0")) == "Host default (smart)")
        #expect(absent.approvalModeHostDefaultLabel(capabilities: Self.caps("0.18.2")) == "Host default (manual)")
        #expect(absent.approvalModeHostDefaultLabel(capabilities: .empty) == "Host default (unknown)")
    }

    /// A stored mode still wins everywhere, still normalised the way
    /// `_normalize_approval_mode` reads it (`auto` was never a member).
    @Test func storedApprovalModeWinsAndIsNormalised() {
        let off = HermesConfig(yaml: "approvals:\n  mode: 'off'\n")
        #expect(off.storedApprovalMode == .off)
        #expect(off.displayApprovalMode(capabilities: Self.caps("0.21.1")) == .off)
        // A config still carrying the `auto` Scarf used to write reads as the
        // `manual` Hermes actually enforces for it — NOT as "absent".
        let auto = HermesConfig(yaml: "approvals:\n  mode: auto\n")
        #expect(auto.storedApprovalMode == .manual)
    }

    /// `agent.reasoning_effort` is in no schema layer at any supported tag, so
    /// an absent key means "the model provider's own default" — not `medium`,
    /// which Scarf asserted and would write on the next save.
    @Test func reasoningEffortAbsentMeansProviderDefault() {
        #expect(HermesConfig(yaml: Self.bare).reasoningEffort.isEmpty)
        #expect(HermesConfig(yaml: "agent:\n  reasoning_effort: high\n").reasoningEffort == "high")
    }

    // MARK: - Closed-enum scalars (finding: ten remaining `str()` reads)

    /// Each of these drives a `PickerRow`, so a whitespace-preceded trailing
    /// comment — legal YAML that PyYAML strips — must not survive into the
    /// selection, or the control renders blank and the next save writes over a
    /// value the user never saw. `str()` only stripped a quote pair.
    @Test(arguments: [
        ("agent", "reasoning_effort", "high"),
        ("agent", "tool_use_enforcement", "auto"),
        ("logging", "level", "DEBUG"),
        ("memory", "provider", "mem0"),
        ("display", "personality", "dry"),
        ("wake_word", "capture", "always"),
        ("terminal", "modal_mode", "sandbox"),
    ])
    func closedEnumScalarsStripTrailingComments(section: String, key: String, value: String) {
        let yaml = "\(section):\n  \(key): \(value)  # why\n"
        let c = HermesConfig(yaml: yaml)
        let read: String
        switch "\(section).\(key)" {
        case "agent.reasoning_effort": read = c.reasoningEffort
        case "agent.tool_use_enforcement": read = c.toolUseEnforcement
        case "logging.level": read = c.logging.level
        case "memory.provider": read = c.memoryProvider
        case "display.personality": read = c.personality
        case "wake_word.capture": read = c.voice.wakeWordCapture
        case "terminal.modal_mode": read = c.terminal.modalMode
        default: read = "<unmapped>"
        }
        #expect(read == value, "\(section).\(key) kept its trailing comment")
    }

    /// The four nested voice enums, same rule.
    @Test func nestedVoiceEnumsStripTrailingComments() {
        let c = HermesConfig(yaml: """
        tts:
          openai:
            voice: nova  # warmer
          neutts:
            device: cuda  # gpu box
        stt:
          local:
            model: small  # faster
          groq:
            model: whisper-large-v3  # not turbo
        """)
        #expect(c.voice.ttsOpenAIVoice == "nova")
        #expect(c.voice.ttsNeuTTSDevice == "cuda")
        #expect(c.voice.sttLocalModel == "small")
        #expect(c.voice.sttGroqModel == "whisper-large-v3")
    }

    // MARK: - Slack / platform read paths

    /// `reply_in_thread` is a `_SHARED_KEYS` member
    /// (`gateway/config_loader.py:200` @ v2026.9.7), so a top-level
    /// `slack.reply_in_thread` is bridged into `extra` and OVERWRITES the
    /// `extra:` value (`extra.update(bridged)`, :283). Reading it from
    /// `extra:` only showed the losing half.
    @Test func slackReplyInThreadHonoursTheSharedKeyBridge() {
        let c = HermesConfig(yaml: """
        slack:
          reply_in_thread: false
        platforms:
          slack:
            extra:
              reply_in_thread: true
        """)
        #expect(!c.slack.replyInThread)
        // Absent everywhere → the adapter's own True default.
        #expect(HermesConfig(yaml: Self.bare).slack.replyInThread)
    }

    /// With no top-level `slack:` block, `platform_section` picks the nested
    /// one and its shared keys bridge over the `extra:` spelling.
    @Test func slackNestedBlockBridgesOverExtraWhenNoTopLevelBlock() {
        let c = HermesConfig(yaml: """
        platforms:
          slack:
            reply_in_thread: false
            extra:
              reply_in_thread: true
        """)
        #expect(!c.slack.replyInThread)
    }

    /// A top-level `slack:` block REPLACES the nested block as the bridge
    /// source outright (`platform_section`, `config_loader.py:171-180`), so a
    /// `platforms.slack.require_mention` under it is never bridged and never
    /// reaches the adapter — the merged `extra:` value is what survives.
    @Test func topLevelSlackBlockShadowsNestedSharedKeys() {
        let c = HermesConfig(yaml: """
        slack:
          allowed_channels:
            - C01
        platforms:
          slack:
            reply_in_thread: false
            extra:
              reply_in_thread: true
        """)
        #expect(c.slack.replyInThread)
    }

    /// `slack.reply_to_mode` at the TOP level is read by no Hermes version:
    /// it is not in `_SHARED_KEYS` (so it is never bridged) and
    /// `merge_platform_sections` (`config_loader.py:149-152`) never merges a
    /// bare top-level `slack:` block into `platforms_data`, which is what
    /// `PlatformConfig.from_dict` reads it from (`gateway/config.py:437`).
    /// Scarf's own writer only ever emits the nested spelling, so nothing
    /// Scarf produced is affected.
    @Test func topLevelSlackReplyToModeIsNotRead() {
        #expect(HermesConfig(yaml: "slack:\n  reply_to_mode: all\n").slack.replyToMode == "first")
        #expect(HermesConfig(yaml: "platforms:\n  slack:\n    reply_to_mode: all\n").slack.replyToMode == "all")
    }

    // MARK: - `display.busy_ack_enabled`'s env-bridge vocabulary

    /// The one boolean key whose effective vocabulary is NOT the universal
    /// boolish set, because it reaches its reader through an env bridge that
    /// stringifies: `os.environ[env] = str(section[key])`
    /// (`gateway/run.py:1816-1820`) and then
    /// `os.environ.get(..., "true").lower() != "true"` disables
    /// (`gateway/run_busy.py:727`). PyYAML loads `1` as the INT 1, so
    /// `str(1)` = `"1"` ≠ `"true"` and the ack is DISABLED — while every
    /// other boolean key in the file reads `1` as on.
    @Test func busyAckEnabledModelsTheEnvBridgeComparison() {
        #expect(HermesConfig(yaml: Self.bare).displayBusyAckEnabled)
        for on in ["true", "True", "yes", "on", "TRUE"] {
            #expect(HermesConfig(yaml: "display:\n  busy_ack_enabled: \(on)\n").displayBusyAckEnabled,
                    "`\(on)` loads as Python True → str() → \"true\" → ack enabled")
        }
        for off in ["1", "0", "false", "no", "off", "2"] {
            #expect(!HermesConfig(yaml: "display:\n  busy_ack_enabled: \(off)\n").displayBusyAckEnabled,
                    "`\(off)` does not stringify to \"true\" → ack disabled")
        }
    }

    // MARK: - `multiplex_profile_allowlist` / `multiplex_profiles`

    /// `pick` returns the top-level value when the key is PRESENT, null
    /// included, and `_normalize_multiplex_profile_allowlist(None)` returns
    /// `None` = serve ALL profiles (`gateway/config.py:45-48,668-670,734`).
    /// Failing closed to `[]` there told the user their gateway was restricted
    /// to the `default` profile when it was not.
    @Test func nullMultiplexAllowlistMeansServeAll() {
        #expect(HermesConfig(yaml: "multiplex_profile_allowlist: null\n").multiplexProfileAllowlist == nil)
        #expect(HermesConfig(yaml: "multiplex_profile_allowlist: ~\n").multiplexProfileAllowlist == nil)
        // A present top-level key SHADOWS the nested one even when it is null.
        let shadowed = HermesConfig(yaml: """
        multiplex_profile_allowlist: null
        gateway:
          multiplex_profile_allowlist:
            - work
        """)
        #expect(shadowed.multiplexProfileAllowlist == nil)
        // A present, non-list scalar still fails CLOSED, as Hermes does.
        #expect(HermesConfig(yaml: "multiplex_profile_allowlist: work\n").multiplexProfileAllowlist == [])
        // A real list still parses.
        #expect(HermesConfig(yaml: "multiplex_profile_allowlist:\n  - work\n").multiplexProfileAllowlist == ["work"])
    }

    /// `multiplex_profiles` top-level wins only when NOT null
    /// (`gateway/config.py:708-710`), and `multiplexIsTopLevel` is what
    /// `SettingsViewModel.setMultiplexProfiles` uses to pick the key it writes
    /// — so a null top-level key must not claim to be in effect.
    @Test func nullTopLevelMultiplexProfilesDefersToTheGatewayKey() {
        let nulled = ProfileRoutesYAML.parse("""
        multiplex_profiles: null
        gateway:
          multiplex_profiles: true
        """)
        #expect(nulled.multiplexProfiles)
        #expect(!nulled.multiplexIsTopLevel)

        let live = ProfileRoutesYAML.parse("""
        multiplex_profiles: false
        gateway:
          multiplex_profiles: true
        """)
        #expect(!live.multiplexProfiles)
        #expect(live.multiplexIsTopLevel)
    }
}
