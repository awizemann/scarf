import Foundation
import Testing
@testable import ScarfCore

// MARK: - Round-4 decision 12: typed sub-floor `/steer` and `/queue`

/// The menu has hidden `/steer` and `/queue` below their v0.13 floor since
/// P37, but nothing stopped a user TYPING either one — and below the floor
/// the adapter does not dispatch it. `_handle_slash_command` returns `None`
/// for a name outside `_COMMANDS` and the raw text falls through to the LLM
/// as an ordinary prompt (`acp_adapter/commands.py:88-95` @ `v2026.9.7`);
/// both names enter the dict together at `acp_adapter/server.py:170`/`:171`
/// @ `v2026.5.7`, and `acp_adapter/` at `v2026.4.30` has neither.
///
/// So the sub-floor turn is a REAL turn: the optimistic mirrors must not
/// fire, the working indicator must not be suppressed, and the user gets one
/// line saying what Scarf actually sent.
@Suite("P44 · typed sub-floor /steer and /queue")
struct TypedSubFloorSlashP44Tests {

    private static let v012 = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
    private static let v013 = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")

    @Test func theFloorPredicateAnswersPerNameNotPerCommandness() {
        #expect(!RichChatViewModel.nonInterruptiveSlashIsDispatched("steer", capabilities: Self.v012))
        #expect(!RichChatViewModel.nonInterruptiveSlashIsDispatched("queue", capabilities: Self.v012))
        #expect(RichChatViewModel.nonInterruptiveSlashIsDispatched("steer", capabilities: Self.v013))
        #expect(RichChatViewModel.nonInterruptiveSlashIsDispatched("queue", capabilities: Self.v013))
        // It asks "is THIS name floored", not "is this a slash command" —
        // `availableCommands`' filter relies on the `default: true` arm.
        #expect(RichChatViewModel.nonInterruptiveSlashIsDispatched("help", capabilities: Self.v012))
        #expect(RichChatViewModel.nonInterruptiveSlashIsDispatched(nil, capabilities: Self.v012))
    }

    /// An unknown host (`.empty`, the C1 degradation arm) is below the floor.
    @Test func anUndetectedHostIsTreatedAsBelowTheFloor() {
        #expect(!RichChatViewModel.nonInterruptiveSlashIsDispatched("steer", capabilities: .empty))
        #expect(!RichChatViewModel.nonInterruptiveSlashIsDispatched("queue", capabilities: .empty))
    }

    @MainActor
    @Test func theSendPathPredicateIsCapabilityAwareWhileTheLegacyOneIsNot() {
        let vm = RichChatViewModel(context: .local)
        vm.publishCapabilities(Self.v012)
        // The legacy predicate still answers the VOCABULARY question — it is
        // what `subFloorSlashNotice` and the roster are built on.
        #expect(vm.isNonInterruptiveSlash("/steer be careful"))
        #expect(vm.isNonInterruptiveSlash("/queue summarize"))
        // The send paths use the capability-aware twin. Without it a v0.12
        // host painted the queue chip and suppressed the working indicator.
        #expect(!vm.isDispatchedNonInterruptiveSlash("/steer be careful"))
        #expect(!vm.isDispatchedNonInterruptiveSlash("/queue summarize"))

        vm.publishCapabilities(Self.v013)
        #expect(vm.isDispatchedNonInterruptiveSlash("/steer be careful"))
        #expect(vm.isDispatchedNonInterruptiveSlash("/queue summarize"))
        // Ordinary text and a dispatched-but-interruptive slash are never
        // "non-interruptive" under either predicate.
        #expect(!vm.isDispatchedNonInterruptiveSlash("hello"))
        #expect(!vm.isDispatchedNonInterruptiveSlash("/goal ship v2.11"))
    }

    @Test func theNoticeFiresOnlyForASubFloorNonInterruptiveName() {
        let steer = RichChatViewModel.subFloorSlashNotice(name: "steer", capabilities: Self.v012)
        let queue = RichChatViewModel.subFloorSlashNotice(name: "queue", capabilities: Self.v012)
        #expect(steer?.contains("/steer") == true)
        #expect(queue?.contains("/queue") == true)
        // One line, and it says what happened rather than offering a remedy
        // the host cannot honour.
        #expect(steer?.contains("\n") == false)
        #expect(steer?.contains("ordinary prompt") == true)

        #expect(RichChatViewModel.subFloorSlashNotice(name: "steer", capabilities: Self.v013) == nil)
        #expect(RichChatViewModel.subFloorSlashNotice(name: "queue", capabilities: Self.v013) == nil)
        #expect(RichChatViewModel.subFloorSlashNotice(name: "goal", capabilities: Self.v012) == nil)
        #expect(RichChatViewModel.subFloorSlashNotice(name: nil, capabilities: Self.v012) == nil)
    }

    /// The roster gate and the send gate must be the SAME answer — they were
    /// two independent derivations, and only one of them asked.
    @MainActor
    @Test func theRosterAndTheSendPathAgreeOnEveryNonInterruptiveName() {
        for caps in [Self.v012, Self.v013, HermesCapabilities.empty] {
            let vm = RichChatViewModel(context: .local)
            vm.publishCapabilities(caps)
            let offered = Set(vm.availableCommands.map(\.name))
            for cmd in RichChatViewModel.nonInterruptiveCommands {
                let dispatched = RichChatViewModel.nonInterruptiveSlashIsDispatched(
                    cmd.name, capabilities: caps
                )
                #expect(vm.isDispatchedNonInterruptiveSlash("/\(cmd.name) x") == dispatched)
                if !dispatched {
                    #expect(!offered.contains(cmd.name),
                            "\(cmd.name) is offered on a host that will not dispatch it")
                }
            }
        }
    }
}

// MARK: - Round-4 decision 14 + the `/queue`-on-idle LOW

@Suite("P44 · the idle slash grey-out")
struct IdleSlashGreyOutP44Tests {

    private static let target = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    private static let v012 = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")

    /// The arm decision 14 retired. A pre-v0.13 host with an open, idle
    /// session greys NOTHING now — the roster already hides both rows.
    @Test func noSteerArmSurvivesOnAPreV013IdleSession() {
        let disabled = RichChatViewModel.disabledSlashCommandNames(
            isAgentWorking: false, hasActiveSession: true, capabilities: Self.v012
        )
        #expect(!disabled.contains("steer"))
        #expect(disabled.isEmpty)
        #expect(RichChatViewModel.disabledSlashCommandReason(
            isAgentWorking: false, hasActiveSession: true, capabilities: Self.v012
        ) == nil)
    }

    /// The arm that replaced it. `_cmd_queue` appends to
    /// `state.queued_prompts` whatever the session is doing
    /// (`_queue_prompt`, `acp_adapter/commands.py:33-36` @ `v2026.9.7`,
    /// called by `_cmd_queue` at `:285-290`), and the only drain
    /// is the tail of a running turn (`server.py:908-915`) — so on an idle
    /// session the prompt runs two turns later, not "after the current turn".
    @Test func queueIsGreyedOnAnIdleButOpenSession() {
        let disabled = RichChatViewModel.disabledSlashCommandNames(
            isAgentWorking: false, hasActiveSession: true, capabilities: Self.target
        )
        #expect(disabled == ["queue"])
        let reason = RichChatViewModel.disabledSlashCommandReason(
            isAgentWorking: false, hasActiveSession: true, capabilities: Self.target
        )
        #expect(reason?.contains("/queue") == true)
        #expect(reason?.contains("/steer") == false)
    }

    /// …and only while idle. A working session is exactly what `/queue` is for.
    @Test func queueIsTappableWhileTheAgentIsWorking() {
        let disabled = RichChatViewModel.disabledSlashCommandNames(
            isAgentWorking: true, hasActiveSession: true, capabilities: Self.target
        )
        #expect(disabled.isEmpty)
    }

    /// The pre-session case is untouched: every session-required row greys,
    /// with its own reason.
    @Test func theNoSessionCaseIsUnchanged() throws {
        let disabled = RichChatViewModel.disabledSlashCommandNames(
            isAgentWorking: false, hasActiveSession: false, capabilities: Self.target
        )
        #expect(disabled == RichChatViewModel.sessionRequiredCommandNames)
        let reason = try #require(RichChatViewModel.disabledSlashCommandReason(
            isAgentWorking: false, hasActiveSession: false, capabilities: Self.target
        ))
        #expect(reason.lowercased().contains("chat is open"))
    }

    /// Decision 14's other half: the flag itself is gone. A source pin,
    /// because "nothing reads it" is the whole argument for retiring it and a
    /// re-added reader would restore the drift without failing anything else.
    @Test func hasACPSteerOnIdleIsGoneFromTheCapabilitySurface() throws {
        let root = P44Repo.root
        for rel in [
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift",
            "scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(!source.contains("var hasACPSteerOnIdle"),
                    "\(rel) still declares hasACPSteerOnIdle")
            #expect(!source.contains(".hasACPSteerOnIdle"),
                    "\(rel) still READS hasACPSteerOnIdle")
        }
    }
}

// MARK: - Round-4 decision 13: the widened effort picker

/// A SwiftUI `Picker` whose selection matches no tag renders BLANK, so a
/// 0.18.x host carrying `ultra` in config.yaml showed an empty control. The
/// options are widened to the stored value; the affordance is what stops the
/// widening from reading as support.
@Suite("P44 · reasoning-effort picker widening")
struct ReasoningEffortWideningP44Tests {

    /// `VALID_REASONING_EFFORTS` gains `max` at `v2026.7.7` (0.18.1,
    /// `hermes_constants.py:794`) and `ultra` at `v2026.7.20` (0.19.0,
    /// `:835-837`).
    private static let v0180 = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
    private static let v0181 = HermesCapabilities.parseLine("Hermes Agent v0.18.1 (2026.7.7)")
    private static let v0190 = HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)")

    @Test func aStoredLevelAboveTheFloorIsAlwaysSelectable() {
        let widened = HermesReasoningEffort.levels(capabilities: Self.v0181, selected: "ultra")
        #expect(widened.contains("ultra"))
        #expect(widened.first == "ultra", "the out-of-range value leads, matching effortOptions")
        // `max` is IN this host's vocabulary, so nothing is widened.
        #expect(HermesReasoningEffort.levels(capabilities: Self.v0181, selected: "max")
                == HermesReasoningEffort.levels(capabilities: Self.v0181))
        // Neither is offered on 0.18.0.
        let both = HermesReasoningEffort.levels(capabilities: Self.v0180, selected: "max")
        #expect(both.first == "max")
        #expect(!HermesReasoningEffort.levels(capabilities: Self.v0180).contains("max"))
    }

    /// The "Hermes default" sentinel widens nothing — the two top-level
    /// pickers prepend `""` themselves and a duplicate row would be a second
    /// blank option.
    @Test func theEmptySentinelWidensNothing() {
        #expect(HermesReasoningEffort.levels(capabilities: Self.v0190, selected: "")
                == HermesReasoningEffort.levels(capabilities: Self.v0190))
    }

    /// The affordance says what Hermes DOES, walked at the tag:
    /// `parse_reasoning_effort` returns `None` for an unrecognised value
    /// (`hermes_constants.py:876-889` @ `v2026.9.7`, `:797-812` @
    /// `v2026.7.1`, `:797-820` @ `v2026.7.7`, `:840-864` @ `v2026.7.20`) and
    /// `resolve_reasoning_config` then logs `Unknown reasoning_effort '%s',
    /// using default (medium)` (`:975-976`) — and the chat-completions
    /// transport substitutes that `medium` EXPLICITLY
    /// (`agent/transports/chat_completions.py:420-422`). P44b: it is
    /// Hermes's own default, NOT "the model provider's own default", which
    /// is what this used to say and assert.
    @Test func theAffordanceNamesTheFallbackAndOnlyWhenUnsupported() throws {
        let notice = try #require(HermesReasoningEffort.unsupportedLevelNotice(
            for: "ultra", capabilities: Self.v0181
        ))
        #expect(notice.contains("ultra"))
        #expect(notice.lowercased().contains("medium"))
        #expect(notice.lowercased().contains("own default"))
        #expect(!notice.lowercased().contains("provider"),
                "the notice must not credit the model provider — Hermes substitutes medium itself")
        #expect(!notice.contains("\n"))

        #expect(HermesReasoningEffort.unsupportedLevelNotice(for: "max", capabilities: Self.v0181) == nil)
        #expect(HermesReasoningEffort.unsupportedLevelNotice(for: "high", capabilities: Self.v0180) == nil)
        #expect(HermesReasoningEffort.unsupportedLevelNotice(for: "", capabilities: Self.v0180) == nil)
        // On the target host nothing is out of vocabulary.
        let target = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        for level in HermesReasoningEffort.baseLevels + ["max", "ultra"] {
            #expect(HermesReasoningEffort.unsupportedLevelNotice(for: level, capabilities: target) == nil)
        }
    }

    /// The widening and the affordance are two halves of one rule: a LEVEL is
    /// prepended if and only if it draws a notice.
    ///
    /// The disable aliases are the deliberate exception P44b added — they are
    /// widened (a stored value always needs a row) but draw no notice on a
    /// host that accepts them, because they are reasoning off, not an
    /// ignored value. `ReasoningDisableAliasP44bTests` owns that half.
    @Test func wideningAndTheAffordanceAgree() {
        let hosts = [Self.v0180, Self.v0181, Self.v0190, HermesCapabilities.empty]
        for caps in hosts {
            for level in HermesReasoningEffort.baseLevels + ["max", "ultra"] {
                let widened = HermesReasoningEffort.levels(capabilities: caps, selected: level) !=
                    HermesReasoningEffort.levels(capabilities: caps)
                let notified = HermesReasoningEffort.unsupportedLevelNotice(
                    for: level, capabilities: caps
                ) != nil
                #expect(widened == notified, "\(level) on \(caps.versionLine)")
            }
        }
    }

    /// All THREE pickers must ask the widened question. The two top-level
    /// ones asked `levels(capabilities:)` flat; only `ReasoningOverridesSection`
    /// had the fix, in its own private copy.
    @Test func allThreePickerSitesUseTheWidenedOverload() throws {
        let root = P44Repo.root
        for rel in [
            "scarf/scarf/Features/Settings/Views/Tabs/AgentTab.swift",
            "scarf/scarf/Features/Settings/Views/Tabs/AuxiliaryTab.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(source.contains("selected:"),
                    "\(rel) does not pass `selected:` to HermesReasoningEffort.levels")
            #expect(source.contains("UnsupportedEffortNote"),
                    "\(rel) widens its picker without the affordance decision 13 requires")
        }
        // `effortOptions(current:)` must now DELEGATE rather than re-derive.
        let agentTab = try String(
            contentsOf: root.appendingPathComponent("scarf/scarf/Features/Settings/Views/Tabs/AgentTab.swift"),
            encoding: .utf8
        )
        #expect(agentTab.contains("HermesReasoningEffort.levels(capabilities: capabilities, selected: current)"),
                "effortOptions still carries its own copy of the widening")
    }
}

// MARK: - t-6fa3fc84: the shared-key WRITE

/// `platform_section` (`gateway/config_loader.py:171-180` @ `v2026.9.7`)
/// picks ONE section to bridge a platform's `_SHARED_KEYS` from, and a
/// top-level `<name>:` block REPLACES the nested one as that source rather
/// than out-ranking it key by key. `_bridged_keys` (`:224-239`) then copies
/// the chosen section's shared keys into `extra`, which is where the adapter
/// reads them (`_slack_require_mention`,
/// `plugins/platforms/slack/adapter.py:5917-5926`).
@Suite("P44 · platform shared-key write resolution")
struct HermesPlatformSharedKeyWriteP44Tests {

    @Test func theBridgeSourceFollowsHermesPrecedence() {
        // Top-level block wins outright.
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack",
            configText: "slack:\n  allowed_channels:\n    - C1\nplatforms:\n  slack:\n    require_mention: false\n"
        ) == "slack")
        // Nested under `gateway.platforms` beats plain `platforms`.
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack",
            configText: "gateway:\n  platforms:\n    slack:\n      require_mention: false\n"
        ) == "gateway.platforms.slack")
        // The modern nested spelling.
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack",
            configText: "platforms:\n  slack:\n    require_mention: false\n"
        ) == "platforms.slack")
        // A config that mentions the platform nowhere — a fresh host — gets
        // the nested default, i.e. the pre-P44 behaviour.
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", configText: "") == "platforms.slack")
        // A BARE `slack:` is `None` to PyYAML, not a dict, so it is not a block.
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack",
            configText: "slack:\nplatforms:\n  slack:\n    require_mention: false\n"
        ) == "platforms.slack")
    }

    @Test func onlySharedKeysOfBridgeResolvedPlatformsAreSplit() {
        #expect(HermesPlatformSharedKeys.split(key: "platforms.slack.require_mention")?.sharedKey == "require_mention")
        #expect(HermesPlatformSharedKeys.split(key: "platforms.slack.extra.reply_in_thread")?.sharedKey == "reply_in_thread")
        #expect(HermesPlatformSharedKeys.split(key: "telegram.require_mention")?.platform == "telegram")
        #expect(HermesPlatformSharedKeys.split(key: "gateway.platforms.slack.require_mention")?.platform == "slack")
        // Not a shared key.
        #expect(HermesPlatformSharedKeys.split(key: "platforms.slack.reply_to_mode") == nil)
        #expect(HermesPlatformSharedKeys.split(key: "platforms.slack.extra.reply_broadcast") == nil)
        // A platform whose READER still expects one hard-coded spelling.
        #expect(HermesPlatformSharedKeys.split(key: "platforms.signal.extra.require_mention") == nil)
        #expect(HermesPlatformSharedKeys.split(key: "discord.require_mention") == nil)
        // An unrecognised prefix, and a non-platform segment.
        #expect(HermesPlatformSharedKeys.split(key: "gateway.slack.require_mention") == nil)
        #expect(HermesPlatformSharedKeys.split(key: "agent.allow_from") == nil)
        #expect(HermesPlatformSharedKeys.split(key: "require_mention") == nil)
    }

    /// The bug itself: with a top-level `slack:` block on disk, the form's
    /// `platforms.slack.require_mention` is bridged from nowhere.
    @Test func aTopLevelBlockMovesTheWriteOntoIt() throws {
        let yaml = "slack:\n  allowed_channels:\n    - C1\n"
        let resolved = HermesPlatformSharedKeys.resolved(
            [
                "platforms.slack.reply_to_mode": "first",
                "platforms.slack.require_mention": "false",
                "platforms.slack.extra.reply_in_thread": "true",
                "platforms.slack.extra.reply_broadcast": "false",
            ],
            configText: yaml
        )
        #expect(resolved["slack.require_mention"] == "false")
        #expect(resolved["slack.reply_in_thread"] == "true")
        #expect(resolved["platforms.slack.require_mention"] == nil)
        #expect(resolved["platforms.slack.extra.reply_in_thread"] == nil)
        // The two non-shared keys keep their spellings untouched.
        #expect(resolved["platforms.slack.reply_to_mode"] == "first")
        #expect(resolved["platforms.slack.extra.reply_broadcast"] == "false")
        #expect(resolved.count == 4)
    }

    /// And with no top-level block the shared keys land on the nested
    /// section — the spelling `_bridged_keys` reads, which for
    /// `reply_in_thread` means the SECTION and not `extra:` (the bridge
    /// `extra.update(bridged)`s over it).
    @Test func aNestedOnlyConfigKeepsTheNestedSpelling() {
        let resolved = HermesPlatformSharedKeys.resolved(
            [
                "platforms.slack.require_mention": "false",
                "platforms.slack.extra.reply_in_thread": "true",
            ],
            configText: "platforms:\n  slack:\n    reply_to_mode: first\n"
        )
        #expect(resolved["platforms.slack.require_mention"] == "false")
        #expect(resolved["platforms.slack.reply_in_thread"] == "true")
    }

    /// What the resolved write produces must be what the reader reads back —
    /// the parity the write side was missing.
    @Test func theResolvedWriteRoundTripsThroughTheReader() throws {
        for (existing, label) in [
            ("slack:\n  allowed_channels:\n    - C1\n", "top-level"),
            ("platforms:\n  slack:\n    reply_to_mode: first\n", "nested"),
            ("gateway:\n  platforms:\n    slack:\n      reply_to_mode: first\n", "gateway-nested"),
            ("", "fresh"),
        ] {
            let resolved = HermesPlatformSharedKeys.resolved(
                [
                    "platforms.slack.require_mention": "false",
                    "platforms.slack.extra.reply_in_thread": "false",
                ],
                configText: existing
            )
            // Splice the resolved keys back in as flat dotted rows — enough
            // for the flat parser, which is what `HermesConfig(yaml:)` uses.
            // All the resolved keys share one parent path here, so they go
            // into ONE nested block — a second copy of the same header chain
            // is not a thing config.yaml ever contains.
            let yaml = existing + Self.nestedBlock(resolved)
            let config = HermesConfig(yaml: yaml)
            #expect(config.slack.requireMention == false, "require_mention lost on the \(label) config")
            #expect(config.slack.replyInThread == false, "reply_in_thread lost on the \(label) config")
        }
    }

    /// Render `{a.b.c: v, a.b.d: w}` as the one nested block config.yaml
    /// would hold. Every key must share a parent path.
    private static func nestedBlock(_ kv: [String: String]) -> String {
        let split = kv.keys.map { $0.split(separator: ".").map(String.init) }
        guard let parents = split.first?.dropLast() else { return "" }
        var out = ""
        for (i, part) in parents.enumerated() {
            out += String(repeating: "  ", count: i) + part + ":\n"
        }
        let indent = String(repeating: "  ", count: parents.count)
        for (key, value) in kv.sorted(by: { $0.key < $1.key }) {
            out += indent + (key.split(separator: ".").last.map(String.init) ?? key) + ": " + value + "\n"
        }
        return out
    }

    /// The allowlist is the honest half of this fix. Rewriting a write whose
    /// READER still expects one hard-coded spelling would trade half the bug
    /// for the other half, so `bridgeResolvedKeys` must contain exactly the
    /// `(platform, key)` PAIRS `HermesConfig+YAML` reads through
    /// `sharedPlatformScalar` / `sharedPlatformBool`. A reader that adopts
    /// the bridge fails here until its writer is let in too. Scoping this by
    /// platform alone was P46 finding 1(a): `slack` resolves the bridge for
    /// `require_mention` and does NOT for `gateway_restart_notification`.
    @Test func theAllowlistMatchesTheReadersThatResolveTheBridge() throws {
        let source = try String(
            contentsOf: P44Repo.root.appendingPathComponent(
                "scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift"
            ),
            encoding: .utf8
        )
        // Comment lines mention the helpers in prose; only CALL sites count.
        let body = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let pattern = #"sharedPlatform(?:Scalar|Bool)\(\"([a-z_]+)\", *\"([a-z_]+)\""#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = body as NSString
        var pairs: Set<HermesPlatformSharedKeys.SharedKeyRef> = []
        for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 2 {
            pairs.insert(.init(platform: ns.substring(with: m.range(at: 1)),
                               key: ns.substring(with: m.range(at: 2))))
        }
        #expect(!pairs.isEmpty, "the scan found no sharedPlatform* call sites — it has broken")
        #expect(pairs == HermesPlatformSharedKeys.bridgeResolvedKeys, """
            HermesConfig+YAML resolves the bridge for \(pairs.sorted()), but \
            HermesPlatformSharedKeys.bridgeResolvedKeys says \
            \(HermesPlatformSharedKeys.bridgeResolvedKeys.sorted()). Move the \
            reader and the writer in the same commit.
            """)
    }

    /// The shared executor must actually route its batch through the
    /// resolution — this fix lives in one place precisely so it cannot be
    /// half-applied, and a source pin is what says so.
    @Test func theSharedSaveExecutorResolvesBeforeItSpawns() throws {
        let source = try String(
            contentsOf: P44Repo.root.appendingPathComponent(
                "scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/PlatformSetupHelpers.swift"
            ),
            encoding: .utf8
        )
        let resolveAt = try #require(source.range(of: "let configKV = resolveSharedKeys("))
        let spawnAt = try #require(source.range(of: "HermesConfigSet.argv(key: key"))
        #expect(resolveAt.lowerBound < spawnAt.lowerBound,
                "the batch is spawned before it is resolved")
    }
}

// MARK: - Shared

enum P44Repo {
    /// Repo root, derived from this file's location.
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // → ScarfCoreTests
            .deletingLastPathComponent()  // → Tests
            .deletingLastPathComponent()  // → ScarfCore
            .deletingLastPathComponent()  // → Packages
            .deletingLastPathComponent()  // → scarf
            .deletingLastPathComponent()  // → repo root
    }
}
