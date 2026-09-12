import Foundation
import Testing
@testable import ScarfCore

// MARK: - P44b finding 1 & 2: the effort affordance and the disable aliases

/// P44 gated the "isn't supported" affordance on `levels(capabilities:)`
/// alone, which by construction excludes `disabled` / `false` / `off` — so a
/// config carrying `agent.reasoning_effort: disabled` rendered a notice
/// saying the host ignores the value, when on every host at or above v0.18.1
/// `parse_reasoning_effort` maps all three to `{"enabled": False}`
/// (`hermes_constants.py:884-885` @ `v2026.9.7`) — reasoning off, as asked.
///
/// The alias set was walked at every `v2026.*` tag: it appears at
/// **v2026.7.7** (0.18.1, `:816`) and is byte-identical from there to
/// `v2026.9.7` (`:885`). At **v2026.7.1** (0.18.0) and earlier the function
/// is typed `(effort: str)`, disables on `"none"` ALONE (`:809`), and its
/// leading `if not effort` swallows a YAML `false` — so below that floor the
/// three spellings really are values the host ignores, and the notice is
/// correct there.
@Suite("P44b · reasoning disable aliases")
struct ReasoningDisableAliasP44bTests {

    private static let v0180 = HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")
    private static let v0181 = HermesCapabilities.parseLine("Hermes Agent v0.18.1 (2026.7.7)")
    private static let target = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")

    /// The finding, one assertion per alias.
    @Test func noAliasDrawsAFalseUnsupportedNoticeOnAHostThatAcceptsIt() {
        for alias in HermesReasoningEffort.disableAliases {
            #expect(HermesReasoningEffort.unsupportedLevelNotice(
                for: alias, capabilities: Self.target
            ) == nil, "\(alias) disables reasoning on v0.21.1 — it is not unsupported")
            #expect(HermesReasoningEffort.unsupportedLevelNotice(
                for: alias, capabilities: Self.v0181
            ) == nil, "\(alias) disables reasoning at the v0.18.1 floor")
        }
        // `none` is in the base vocabulary at every tag.
        #expect(HermesReasoningEffort.unsupportedLevelNotice(for: "none", capabilities: Self.v0180) == nil)
    }

    /// Below the floor the aliases are genuinely ignored, so the notice is
    /// the right answer — the fix is capability-aware, not a blanket mute.
    @Test func belowTheAliasFloorTheNoticeStillFires() throws {
        for alias in HermesReasoningEffort.disableAliases {
            let notice = try #require(
                HermesReasoningEffort.unsupportedLevelNotice(for: alias, capabilities: Self.v0180),
                "\(alias) does not disable reasoning on 0.18.0 — the user must be told"
            )
            #expect(notice.contains(alias))
        }
        #expect(!Self.v0180.hasReasoningDisableAliases)
        #expect(Self.v0181.hasReasoningDisableAliases)
        #expect(Self.target.hasReasoningDisableAliases)
    }

    /// C1's own case, and the one P44b left out: `.empty` — no version line
    /// at all, which is what a failed `hermes --version` probe and every
    /// host below the oldest tag Scarf parses look like. It must render as
    /// the OLDEST supported Hermes, never as the target: the aliases do not
    /// disable there, so the notice is owed.
    @Test func anUnknownHostSitsBelowTheAliasFloor() throws {
        #expect(!HermesCapabilities.empty.hasReasoningDisableAliases)
        #expect(HermesReasoningEffort.disablingSpellings(capabilities: .empty) == ["none"])
        for alias in HermesReasoningEffort.disableAliases {
            let notice = try #require(
                HermesReasoningEffort.unsupportedLevelNotice(for: alias, capabilities: .empty),
                "\(alias) is not known to disable reasoning on an unknown host"
            )
            #expect(notice.contains(alias))
        }
        // …and `none`, which every tag accepts, still draws none.
        #expect(HermesReasoningEffort.unsupportedLevelNotice(
            for: "none", capabilities: .empty) == nil)
    }

    /// Case and whitespace come from a hand-edited config.yaml, which is the
    /// only way these values reach a picker at all.
    @Test func theAliasTestIsNormalised() {
        #expect(HermesReasoningEffort.unsupportedLevelNotice(
            for: "  Disabled ", capabilities: Self.target
        ) == nil)
        #expect(HermesReasoningEffort.disablingSpellings(capabilities: Self.target)
                .isSuperset(of: HermesReasoningEffort.disableAliases))
        #expect(HermesReasoningEffort.disablingSpellings(capabilities: Self.v0180) == ["none"])
    }

    /// Decision 13's widening is the other half: an alias on disk must still
    /// have a row, on every host, or the picker renders blank.
    @Test func everyAliasStaysSelectableInThePicker() {
        for caps in [Self.v0180, Self.v0181, Self.target, HermesCapabilities.empty] {
            for alias in HermesReasoningEffort.disableAliases {
                let widened = HermesReasoningEffort.levels(capabilities: caps, selected: alias)
                #expect(widened.contains(alias), "\(alias) has no row on \(caps.versionLine ?? "unknown")")
                #expect(widened.first == alias)
            }
        }
    }

    /// Finding 2. The consumers were walked: `resolve_reasoning_config`
    /// returns `None` and logs `Unknown reasoning_effort '%s', using default
    /// (medium)` (`hermes_constants.py:957-979`, warning at `:975-976`);
    /// `agent_runtime_helpers.py:2145-2147` stores that `None`; and
    /// `agent/transports/chat_completions.py:420-422` then substitutes
    /// `medium` explicitly, as does `agent/chat_completion_helpers.py:2020`.
    /// Only `agent/anthropic_adapter.py:570` omits the parameter.
    @Test func theNoticeCreditsHermesOwnDefaultNotTheProvider() throws {
        let notice = try #require(HermesReasoningEffort.unsupportedLevelNotice(
            for: "ultra", capabilities: Self.v0181
        ))
        #expect(notice.lowercased().contains("medium"))
        #expect(!notice.lowercased().contains("provider"))
    }
}

// MARK: - P44b finding 3: a typed `/queue` on an idle session

/// The menu row greys out on an idle session, but typing `/queue` was never
/// gated: both send paths painted "Queued — runs after current turn." over
/// something that does not happen. `_queue_prompt` appends unconditionally
/// (`acp_adapter/commands.py:33-36` @ `v2026.9.7`), the only drain is the
/// tail of a running turn (`server.py:908-915`), and a dispatched slash
/// command returns `end_turn` before it (`server.py:793-799`).
@Suite("P44b · typed /queue on an idle session")
struct IdleQueueFallbackP44bTests {

    private static let target = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    private static let v012 = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")

    @Test func anIdleQueueBecomesAPlainPrompt() throws {
        let plain = try #require(RichChatViewModel.idleQueueFallbackText(
            name: "queue", args: "  summarize the diff  ",
            isAgentWorking: false, capabilities: Self.target
        ))
        #expect(plain == "summarize the diff", "the /queue prefix must not reach the wire")
    }

    @Test func aWorkingSessionQueuesAsBefore() {
        #expect(RichChatViewModel.idleQueueFallbackText(
            name: "queue", args: "summarize", isAgentWorking: true, capabilities: Self.target
        ) == nil)
    }

    /// An empty argument is Hermes's own `Usage: /queue <prompt>`
    /// (`commands.py:286-288`) — there is no plain prompt to send instead.
    @Test func anEmptyArgumentIsLeftToHermes() {
        for args in ["", "   ", "\n"] {
            #expect(RichChatViewModel.idleQueueFallbackText(
                name: "queue", args: args, isAgentWorking: false, capabilities: Self.target
            ) == nil)
        }
    }

    /// Below the v0.13 floor the text already goes to the LLM verbatim and
    /// `subFloorSlashNotice` owns the explanation — rewriting the wire text
    /// there would produce two notices for one send.
    @Test func aSubFloorHostIsTheOtherNoticesJob() {
        #expect(RichChatViewModel.idleQueueFallbackText(
            name: "queue", args: "summarize", isAgentWorking: false, capabilities: Self.v012
        ) == nil)
        #expect(RichChatViewModel.subFloorSlashNotice(name: "queue", capabilities: Self.v012) != nil)
    }

    /// No other command takes this path: `/steer` on an idle session IS
    /// dispatched and handled (`server.py:812-820` @ `v2026.5.7`).
    @Test func onlyQueueIsRewritten() {
        for name in ["steer", "goal", "subgoal", "help", nil] {
            #expect(RichChatViewModel.idleQueueFallbackText(
                name: name, args: "x", isAgentWorking: false, capabilities: Self.target
            ) == nil, "\(name ?? "nil") must not be rewritten")
        }
    }

    @Test func theNoticeIsOneLocalizedLine() {
        let notice = RichChatViewModel.idleQueueNotice
        #expect(!notice.isEmpty)
        #expect(!notice.contains("\n"))
    }

    /// Both send paths must gate the optimistic mirror AND rewrite the wire
    /// text — the defect was one platform's arm, and the twin is how it
    /// stays fixed.
    @Test func bothPlatformsGateTheMirrorAndTheWire() throws {
        let root = P44Repo.root
        let sites = [
            "scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift",
            "scarf/Scarf iOS/Chat/ChatView.swift",
        ]
        for rel in sites {
            let source = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(source.contains("wasAgentWorking"),
                    "\(rel) never snapshots the pre-echo working state")
            #expect(source.contains("idleQueueFallbackText"),
                    "\(rel) still sends a typed /queue verbatim on an idle session")
            #expect(source.contains("idleQueueNotice"),
                    "\(rel) rewrites the wire text without saying so")
            #expect(source.contains("&& wasAgentWorking"),
                    "\(rel)'s queue arm is not gated on a turn being in flight")
        }
    }
}

// MARK: - P44b finding 4: `slack: {}` is a block

/// `platform_section` takes `yaml_cfg.get(name)` and asks
/// `isinstance(section, dict)` (`gateway/config_loader.py:175` @
/// `v2026.9.7`). An explicitly empty flow map IS a dict, so `slack: {}` at
/// the top level wins the bridge and the nested `platforms.slack.*` shared
/// keys never reach `extra`. Scarf's flat parse keeps `{}` as a scalar, so
/// both the read and the write side resolved to the nested block.
@Suite("P44b · an empty top-level platform block")
struct EmptyPlatformBlockP44bTests {

    private static let yaml = """
    slack: {}
    platforms:
      slack:
        require_mention: true
    """

    /// The premise of the fix, asserted rather than assumed: the flat parse
    /// DOES record an inline flow map (`HermesYAML.swift:343-354`), empty or
    /// not — the old `?.isEmpty == false` test is what threw it away.
    @Test func theFlatParseRecordsAnEmptyFlowMap() {
        let parsed = HermesYAML.parseNestedYAML(Self.yaml)
        #expect(parsed.maps["slack"] != nil)
        #expect(parsed.maps["slack"]?.isEmpty == true)
    }

    /// And a bare header records nothing, which is what keeps the fix from
    /// crossing PyYAML's `None` case.
    @Test func aBareHeaderRecordsNoMap() {
        let parsed = HermesYAML.parseNestedYAML("slack:\nplatforms:\n  slack:\n    require_mention: true\n")
        #expect(parsed.maps["slack"] == nil)
    }

    @Test func anEmptyTopLevelBlockWinsTheBridge() {
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack", configText: Self.yaml
        ) == "slack")
    }

    /// The write side is the same call, so the fix moves both halves: the
    /// form's `platforms.slack.require_mention` is rewritten onto the
    /// section Hermes actually bridges from.
    @Test func theWriteSideFollowsTheSameAnswer() {
        let resolved = HermesPlatformSharedKeys.resolved(
            ["platforms.slack.require_mention": "false"],
            configText: Self.yaml
        )
        #expect(resolved["slack.require_mention"] == "false")
        #expect(resolved["platforms.slack.require_mention"] == nil)
    }

    /// A BARE `slack:` is `None` to PyYAML, not a dict — it must still lose
    /// to the nested block, which is the line the fix must not cross.
    @Test func aBareHeaderIsStillNotABlock() {
        let bare = """
        slack:
        platforms:
          slack:
            require_mention: true
        """
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack", configText: bare
        ) == "platforms.slack")
    }

    /// A non-empty flow map is the same shape and must answer the same way —
    /// it was already handled, and the fix must not regress it.
    @Test func aNonEmptyFlowMapStillWins() {
        let yaml = """
        slack: {require_mention: false}
        platforms:
          slack:
            require_mention: true
        """
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(platform: "slack", configText: yaml) == "slack")
    }

    /// A config that mentions the platform nowhere still lands on the
    /// nested spelling — the fall-through the fix sits in front of.
    @Test func anAbsentPlatformKeepsTheNestedDefault() {
        #expect(HermesPlatformSharedKeys.bridgeSourcePrefix(
            platform: "slack", configText: "agent:\n  model: x\n"
        ) == "platforms.slack")
    }
}

// MARK: - P44b findings 5 & 6: the citation and the bare literals

@Suite("P44b · citations and localization")
struct SlashCitationAndLocalizationP44bTests {

    /// Finding 5. The append is `_queue_prompt` at
    /// `acp_adapter/commands.py:33-36` @ `v2026.9.7`; `:285-290` is
    /// `_cmd_queue`, which CALLS it.
    @Test func theQueueAppendIsCitedWhereItLives() throws {
        let source = try String(
            contentsOf: P44Repo.root.appendingPathComponent(
                "scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift"
            ),
            encoding: .utf8
        )
        #expect(!source.contains("commands.py:285-289"),
                "the append is cited at _cmd_queue's range, not _queue_prompt's")
        #expect(source.contains("commands.py:33-36"))
    }

    /// Finding 6. Every user-visible sentence on these two surfaces goes
    /// through `String(localized:)`.
    @Test func theTwoBareLiteralsAreLocalized() throws {
        let root = P44Repo.root
        let vm = try String(
            contentsOf: root.appendingPathComponent(
                "scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift"
            ),
            encoding: .utf8
        )
        for sentence in [
            "Available once a chat is open.",
            "Use `/queue` while the agent is working",
        ] {
            #expect(vm.contains("String(localized: \"\(sentence)"),
                    "\(sentence) is still a bare literal")
        }
        let components = try String(
            contentsOf: root.appendingPathComponent(
                "scarf/scarf/Features/Settings/Views/Components/SettingsComponents.swift"
            ),
            encoding: .utf8
        )
        // P46 finding 2: the label used to PREFIX the notice with a second
        // sentence saying the same thing. `notice` is already localized and
        // already names the host and what it does with the value, so the
        // accessibility label is the notice, verbatim and nothing more.
        #expect(components.contains("accessibilityLabel(Text(verbatim: notice))"),
                "UnsupportedEffortNote's accessibility label is not the plain notice")
        #expect(!components.contains("Not supported on this host:"),
                "the doubled sentence is still there")
    }

    /// Finding 7. The plan doc is hand-authored history, so it carries a
    /// retirement note rather than a rewrite — but the retired flag must not
    /// read as current anywhere.
    @Test func theRetiredFlagIsNotDescribedAsCurrent() throws {
        let doc = try String(
            contentsOf: P44Repo.root.appendingPathComponent(
                "scarf/docs/v2.8/WS-2-goals-and-queue-plan.md"
            ),
            encoding: .utf8
        )
        #expect(doc.contains("retired in round 4"),
                "the plan still describes hasACPSteerOnIdle without saying it is gone")
    }
}
