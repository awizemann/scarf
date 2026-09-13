#if canImport(SQLite3)

import Testing
import Foundation
@testable import ScarfCore

/// Behavioral coverage for the shared slash-menu helpers on
/// `RichChatViewModel`. These helpers are the single source of truth
/// the Mac (`RichChatInputBar`, `ChatViewModel`) and iOS
/// (`IOSSlashCommandMenu`, `ChatController`) chat surfaces both read
/// from — drift here is a parity bug.
@Suite struct SlashMenuLogicTests {

    // MARK: - parseSlashName

    @Test func parseSlashNameExtractsNameOnly() {
        let r = RichChatViewModel.parseSlashName("/clear")
        #expect(r.name == "clear")
        #expect(r.args == "")
    }

    @Test func parseSlashNameExtractsNameAndArgs() {
        let r = RichChatViewModel.parseSlashName("/goal lock the rust refactor")
        #expect(r.name == "goal")
        #expect(r.args == "lock the rust refactor")
    }

    @Test func parseSlashNameReturnsNilForNonSlashText() {
        let r = RichChatViewModel.parseSlashName("just a message")
        #expect(r.name == nil)
        #expect(r.args == "")
    }

    @Test func parseSlashNameTrimsLeadingWhitespace() {
        let r = RichChatViewModel.parseSlashName("   /steer go faster")
        #expect(r.name == "steer")
        #expect(r.args == "go faster")
    }

    @Test func parseSlashNameHandlesBareSlash() {
        let r = RichChatViewModel.parseSlashName("/")
        #expect(r.name == "")
        #expect(r.args == "")
    }


    // MARK: - shouldShowSlashMenu

    @Test func shouldShowSlashMenuTrueForSlashOnly() {
        #expect(RichChatViewModel.shouldShowSlashMenu(text: "/"))
    }

    @Test func shouldShowSlashMenuTrueWhileTypingName() {
        #expect(RichChatViewModel.shouldShowSlashMenu(text: "/goa"))
    }

    @Test func shouldShowSlashMenuFalseOnceSpaceAppears() {
        #expect(!RichChatViewModel.shouldShowSlashMenu(text: "/goal "))
    }

    @Test func shouldShowSlashMenuFalseOnceNewlineAppears() {
        #expect(!RichChatViewModel.shouldShowSlashMenu(text: "/goal\n"))
    }

    @Test func shouldShowSlashMenuFalseForPlainText() {
        #expect(!RichChatViewModel.shouldShowSlashMenu(text: "hello"))
    }

    @Test func shouldShowSlashMenuFalseForEmpty() {
        #expect(!RichChatViewModel.shouldShowSlashMenu(text: ""))
    }

    // MARK: - slashMenuQuery

    @Test func slashMenuQueryStripsLeadingSlash() {
        #expect(RichChatViewModel.slashMenuQuery(text: "/clear") == "clear")
    }

    @Test func slashMenuQueryEmptyForSlashOnly() {
        #expect(RichChatViewModel.slashMenuQuery(text: "/") == "")
    }

    @Test func slashMenuQueryEmptyForNonSlash() {
        #expect(RichChatViewModel.slashMenuQuery(text: "no slash") == "")
    }

    // MARK: - filterSlashCommands

    private func makeCommand(_ name: String, source: HermesSlashCommand.Source = .acp) -> HermesSlashCommand {
        HermesSlashCommand(name: name, description: "", argumentHint: nil, source: source)
    }

    @Test func filterSlashCommandsReturnsAllForEmptyQuery() {
        let cmds = ["new", "clear", "goal"].map { makeCommand($0) }
        let r = RichChatViewModel.filterSlashCommands(cmds, query: "")
        #expect(r.count == 3)
    }

    @Test func filterSlashCommandsPrefixMatches() {
        let cmds = ["new", "clear", "goal"].map { makeCommand($0) }
        let r = RichChatViewModel.filterSlashCommands(cmds, query: "g")
        #expect(r.map(\.name) == ["goal"])
    }

    @Test func filterSlashCommandsIsCaseInsensitive() {
        let cmds = ["new", "Goal", "Queue"].map { makeCommand($0) }
        let r = RichChatViewModel.filterSlashCommands(cmds, query: "go")
        #expect(r.map(\.name) == ["Goal"])
    }

    @Test func filterSlashCommandsReturnsEmptyForNoMatch() {
        let cmds = ["new", "clear"].map { makeCommand($0) }
        let r = RichChatViewModel.filterSlashCommands(cmds, query: "zzz")
        #expect(r.isEmpty)
    }

    // MARK: - disabledSlashCommandNames

    /// P44 / round-4 decision 14 + the `/queue`-on-idle LOW. A pre-v0.13
    /// host has no `/queue` row to grey (the roster hides it), and the
    /// retired `hasACPSteerOnIdle` arm no longer greys `steer` either — so
    /// an idle sub-floor session disables nothing.
    @Test func disabledSlashGreysNothingOnPreV013Idle() {
        let caps = HermesCapabilities(
            versionLine: "0.12.0",
            semver: HermesCapabilities.SemVer(major: 0, minor: 12, patch: 0),
            dateVersion: nil
        )
        let disabled = RichChatViewModel.disabledSlashCommandNames(
            isAgentWorking: false,
            hasActiveSession: true,
            capabilities: caps
        )
        #expect(disabled.isEmpty)
    }

    /// The arm that replaced it: on a host that HAS `/queue`, an idle
    /// session greys the row — `_cmd_queue` would append to a queue whose
    /// only drain is the tail of a running turn.
    @Test func disabledSlashGreysQueueOnV013IdleSession() {
        let caps = HermesCapabilities(
            versionLine: "0.13.0",
            semver: HermesCapabilities.SemVer(major: 0, minor: 13, patch: 0),
            dateVersion: nil
        )
        let disabled = RichChatViewModel.disabledSlashCommandNames(
            isAgentWorking: false,
            hasActiveSession: true,
            capabilities: caps
        )
        #expect(disabled == ["queue"])
    }

    @Test func disabledSlashEmptyWhileAgentIsWorking() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        let disabled = RichChatViewModel.disabledSlashCommandNames(
            isAgentWorking: true,
            hasActiveSession: true,
            capabilities: caps
        )
        #expect(disabled.isEmpty)
    }

    @Test func disabledSlashReasonAccompaniesGreying() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        let reason = RichChatViewModel.disabledSlashCommandReason(
            isAgentWorking: false,
            hasActiveSession: true,
            capabilities: caps
        )
        #expect(reason != nil)
        #expect(reason?.contains("/queue") == true)
    }

    @Test func disabledSlashReasonNilWhenNothingDisabled() {
        let caps = HermesCapabilities(
            versionLine: "0.13.0",
            semver: HermesCapabilities.SemVer(major: 0, minor: 13, patch: 0),
            dateVersion: nil
        )
        let reason = RichChatViewModel.disabledSlashCommandReason(
            isAgentWorking: true,
            hasActiveSession: true,
            capabilities: caps
        )
        #expect(reason == nil)
    }

    // P2 of the projects-feature fix — pre-session, every session-
    // required command goes greyed-out instead of being filtered out.

    @Test func disabledSlashGreysAllAgentCommandsPreSession() {
        let caps = HermesCapabilities(
            versionLine: "0.15.0",
            semver: HermesCapabilities.SemVer(major: 0, minor: 15, patch: 0),
            dateVersion: nil
        )
        let disabled = RichChatViewModel.disabledSlashCommandNames(
            isAgentWorking: false,
            hasActiveSession: false,
            capabilities: caps
        )
        // The full session-required set should be disabled — that's
        // the v2.10 fix that replaces the empty-menu pre-session UX.
        // P34: the set is the ACP adapter's roster, so `clear` and `yolo`
        // are no longer in it — they were never ACP names.
        #expect(disabled.contains("reset"))
        #expect(disabled.contains("compact"))
        #expect(disabled.contains("model"))
        #expect(disabled.contains("context"))
        #expect(disabled.contains("version"))
        #expect(disabled.contains("steer"))
        #expect(disabled.contains("queue"))
        // `/goal` is gateway-only (not advertised by the ACP adapter), so
        // it is not in the session-required set and never greyed.
        #expect(!disabled.contains("goal"))
        // `/new` is NEVER session-required — it's how you GET a session.
        #expect(!disabled.contains("new"))
    }

    @Test func disabledSlashReasonMentionsOpeningChatPreSession() {
        let caps = HermesCapabilities.empty
        let reason = RichChatViewModel.disabledSlashCommandReason(
            isAgentWorking: false,
            hasActiveSession: false,
            capabilities: caps
        )
        #expect(reason != nil)
        #expect(reason?.lowercased().contains("chat is open") == true)
    }

    // MARK: - availableCommands capability gating

    @MainActor
    @Test func availableCommandsHidesQueueOnPreV013() {
        let vm = RichChatViewModel(context: .local)
        // A session is engaged so the checks below assess CAPABILITY
        // gating rather than the session-present prereq (`/steer` and
        // `/queue` both need one).
        vm.setSessionId("scratch-session")
        vm.publishCapabilities(
            HermesCapabilities(
                versionLine: "0.12.0",
                semver: HermesCapabilities.SemVer(major: 0, minor: 12, patch: 0),
                dateVersion: nil
            )
        )
        let names = Set(vm.availableCommands.map(\.name))
        #expect(!names.contains("queue"))
        // P37 finding 2: `steer` used to be asserted PRESENT here. It is a
        // v0.13 ACP surface like `queue` — the two are adjacent lines in the
        // adapter's command dict at the same first tag
        // (`acp_adapter/server.py:170`/`:171` @ `v2026.5.7`, neither at
        // `v2026.4.30`) — so a v0.12 host is offered neither.
        #expect(!names.contains("steer"))
        #expect(names.contains("new"))
        // `/goal` and `/subgoal` are gateway-only — never surfaced.
        #expect(!names.contains("goal"))
        #expect(!names.contains("subgoal"))
    }

    @MainActor
    @Test func availableCommandsExposesQueueOnV013ButNeverGoal() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("scratch-session")
        vm.publishCapabilities(
            HermesCapabilities(
                versionLine: "0.13.0",
                semver: HermesCapabilities.SemVer(major: 0, minor: 13, patch: 0),
                dateVersion: nil
            )
        )
        let names = Set(vm.availableCommands.map(\.name))
        #expect(names.contains("queue"))
        #expect(names.contains("steer"))
        #expect(names.contains("new"))
        // `/goal` and `/subgoal` are NOT advertised by the ACP adapter.
        #expect(!names.contains("goal"))
        #expect(!names.contains("subgoal"))
    }

    // MARK: - clientSideSlashCommand
    //
    // Regression coverage for TestFlight feedback ADyrlh (2026-05-11):
    // `/new` was being sent to Hermes as a prompt and routed to the
    // LLM, which responded "/new is a TUI slash command…". Scarf now
    // intercepts `/new` client-side via this classifier.

    @Test func clientSideSlashCommandNewWithoutArgs() {
        let r = RichChatViewModel.clientSideSlashCommand(for: "/new")
        #expect(r == .newSession(name: nil))
    }

    @Test func clientSideSlashCommandNewWithSessionName() {
        let r = RichChatViewModel.clientSideSlashCommand(for: "/new rust refactor")
        #expect(r == .newSession(name: "rust refactor"))
    }

    @Test func clientSideSlashCommandNewWithWhitespaceArgsIsNil() {
        let r = RichChatViewModel.clientSideSlashCommand(for: "/new    ")
        #expect(r == .newSession(name: nil))
    }

    @Test func clientSideSlashCommandIgnoresOtherSlashes() {
        // Non-interruptive + ACP-handled commands keep their existing
        // wire paths. The classifier returns nil so the send pipeline
        // doesn't intercept them.
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/goal lock it") == nil)
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/queue follow up") == nil)
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/steer faster") == nil)
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/clear") == nil)
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/compact") == nil)
    }

    @Test func clientSideSlashCommandIgnoresPlainText() {
        #expect(RichChatViewModel.clientSideSlashCommand(for: "what is wall-e?") == nil)
        #expect(RichChatViewModel.clientSideSlashCommand(for: "") == nil)
        #expect(RichChatViewModel.clientSideSlashCommand(for: "/") == nil)
    }

    @MainActor
    @Test func availableCommandsAlwaysIncludesAgentCommandsForGreyOut() {
        // P2 of the projects-feature fix: pre-session, the agent
        // commands stay in the menu (greyed out via
        // disabledSlashCommandNames) instead of being filtered out.
        // Both states must include them; only the disabled set differs.
        // A target-tag host, so the compress command carries its post-0.19.1
        // `compress` spelling (see `hasACPCompressSpelling`) — this test is
        // about grey-out, not about the ACP rename.
        let vm = RichChatViewModel(context: .local)
        vm.publishCapabilities(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"))
        let namesBefore = Set(vm.availableCommands.map(\.name))
        #expect(namesBefore.contains("reset"))
        #expect(namesBefore.contains("compress"))
        #expect(namesBefore.contains("model"))
        #expect(namesBefore.contains("help"))

        vm.setSessionId("abc-123")
        let namesAfter = Set(vm.availableCommands.map(\.name))
        #expect(namesAfter.contains("reset"))
        #expect(namesAfter.contains("compress"))
        #expect(namesAfter.contains("model"))
        #expect(namesAfter.contains("help"))
    }
}

#endif
