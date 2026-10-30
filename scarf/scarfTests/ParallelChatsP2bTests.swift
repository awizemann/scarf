import Testing
import AppKit
import Foundation
import ScarfCore
@testable import scarf

/// Parallel chats P2b: handoffs and terminal launches that leave a working
/// chat running, a kickoff prompt surviving the budget dialog's Wait, a failed
/// background chat staying in the list, Live Voice bound to its chat, the
/// `parallel_chats_used` event, and the gateway-death error path.
///
/// ACP is scripted through the `acpClientFactory` seam. Installs a capturing
/// analytics tracker in places, so the suite is serialized.
@Suite(.serialized) struct ParallelChatsP2bTests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias Registry = ParallelChatsRegistryTests
    typealias Rows = ParallelChatsRowsNotificationsTests
    typealias Controlled = Rows.ControlledChannel
    typealias Scripted = Lifecycle.ScriptedACPChannel

    @MainActor
    static func makeVM(_ home: TempHermesHome, _ notifier: Rows.RecordingNotifier? = nil,
                       budget: LiveChatBudget? = nil) -> ChatViewModel {
        Rows.makeVM(home, notifier ?? Rows.RecordingNotifier(), budget: budget)
    }

    // MARK: - Item 1: the Dashboard's New Session

    @Test @MainActor func dashboardNewSessionStartsANewChatAndAWorkingOneKeepsRunning() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        Rows.install([chA, chB], on: vm)
        let coordinator = AppCoordinator(usageTracker: CapturingUsageTracker())

        #expect(await Rows.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat

        coordinator.pendingNewChat = true
        vm.consumePendingOpen(from: coordinator)

        #expect(!coordinator.pendingNewChat, "the handoff would fire again on the next visit")
        #expect(vm.focusedChat !== chatA)
        #expect(await Registry.readyOn(vm, "sess-B"), "no new chat started")
        #expect(chatA.hasTurnInFlight, "the working chat was stopped")
        #expect(!(await chA.closed))
        vm.leaveChat()
    }

    // MARK: - Item 2: terminal launches

    @Test @MainActor func aTerminalLaunchLeavesAWorkingChatRunning() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Controlled(sessionId: "sess-A")
        Rows.install([chA], on: vm)
        var launches: [[String]] = []
        vm.terminalLaunchOverride = { launches.append($0) }

        #expect(await Rows.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        vm.displayMode = .terminal
        vm.startNewSession()

        #expect(launches == [["chat"]])
        #expect(vm.focusedChat !== chatA, "the terminal's session change landed on the working chat")
        #expect(vm.chats.contains { $0 === chatA })
        #expect(chatA.hasTurnInFlight, "the working chat was stopped")
        #expect(chatA.richChatViewModel.sessionId == "sess-A", "the working chat was reset")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!(await chA.closed))
        vm.leaveChat()
    }

    @Test @MainActor func aTerminalLaunchStillStopsAnIdleFocusedChat() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        _ = Registry.install([chA], on: vm)
        var launches: [[String]] = []
        vm.terminalLaunchOverride = { launches.append($0) }

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        vm.displayMode = .terminal
        vm.startNewSession()

        #expect(launches == [["chat"]])
        #expect(vm.focusedChat === chatA, "nothing was working: the chat should be reused as before")
        #expect(await Lifecycle.waitUntil { await chA.closed }, "the idle chat kept its process")
    }

    /// Resuming, in terminal mode, the conversation a chat is working in:
    /// neither a second agent on it nor a stopped chat.
    @Test @MainActor func aTerminalResumeOfAWorkingConversationShowsTheChatInstead() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        Rows.install([chA, chB], on: vm)
        var launches: [[String]] = []
        vm.terminalLaunchOverride = { launches.append($0) }

        #expect(await Rows.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(await Rows.startWorking(vm, chB, "work in B"))
        vm.displayMode = .terminal
        vm.resumeSession("sess-A")

        #expect(launches.isEmpty, "a terminal opened on a conversation still working")
        #expect(vm.displayMode == .richChat)
        #expect(vm.focusedChat === chatA)
        #expect(chatA.hasTurnInFlight, "the working chat was stopped")
        #expect(vm.richChatViewModel.transientHint != nil, "nothing said why no terminal opened")
        vm.leaveChat()
    }

    // MARK: - Item 3: Wait keeps a kickoff prompt

    /// Budget 1, a working chat: the kickoff's open is blocked and Wait keeps
    /// the prompt, which then opens once a slot is free. A blocked open
    /// counts as started only when it really starts.
    @Test @MainActor func waitKeepsAKickoffPromptAndOpenNowSendsIt() async throws {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, budget: LiveChatBudget(localLimit: 1))
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        Rows.install([chA, chB], on: vm)
        func started() -> Int { tracker.captured.filter { $0.name == "chat_session_started" }.count }

        #expect(await Rows.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(started() == 1)

        vm.startNewSession(projectPath: nil, initialPrompt: "kick it off")
        #expect(vm.budgetBlocked != nil)
        #expect(started() == 1, "a blocked open counted as started")

        vm.waitForBudget()
        let kickoff = try #require(vm.parkedKickoffs.first, "Wait lost the kickoff prompt")
        #expect(kickoff.prompt == "kick it off")
        #expect(vm.focusedChat === chatA, "Wait moved the user")

        // Still full: asked again, and Wait keeps it again.
        vm.openParkedKickoff(kickoff)
        #expect(vm.parkedKickoffs.isEmpty)
        #expect(vm.budgetBlocked != nil)
        vm.waitForBudget()
        let again = try #require(vm.parkedKickoffs.first, "the second Wait lost the kickoff prompt")

        await chA.completePrompts()
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        vm.openParkedKickoff(again)
        #expect(await Lifecycle.waitUntil { await chB.promptTexts == ["kick it off"] }, "the kickoff never went out")
        #expect(vm.parkedKickoffs.isEmpty)
        #expect(started() == 2)
        vm.leaveChat()
    }

    /// An open with no prompt loses nothing: the row is still there to click.
    @Test @MainActor func waitOnAPlainOpenParksNothing() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, budget: LiveChatBudget(localLimit: 1))
        let chA = Controlled(sessionId: "sess-A")
        Rows.install([chA], on: vm)
        #expect(await Rows.startWorking(vm, chA, "work in A"))

        vm.startNewSession()
        vm.waitForBudget()
        #expect(vm.parkedKickoffs.isEmpty)
        vm.leaveChat()
    }

    // MARK: - Item 4: a failed background chat stays


    /// The reconnect ladder runs out on a background chat with a held send:
    /// it stays listed with the error state and its "couldn't be sent" hint
    /// (past the hint's usual lifetime), holds no budget slot, isn't working,
    /// and a notification says so. Focusing it reconnects through the full
    /// path and withdraws the notification.
    @Test @MainActor func aBackgroundChatWhoseLadderRanOutStaysAndReconnectsOnFocus() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let notifier = Rows.RecordingNotifier()
        let budget = LiveChatBudget()
        let vm = Self.makeVM(home, notifier, budget: budget)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .answeringPrompts(sessionId: "sess-B"))
        let chAgain = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        defer { gateCont.finish() }
        let calls = Lifecycle.CallCounter()
        let reconnectWorks = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let n = calls.next()
            if n == 1 { return ACPClient(context: ctx) { _ in chA } }
            if n == 2 { return ACPClient(context: ctx) { _ in chB } }
            if reconnectWorks.count > 0 { return ACPClient(context: ctx) { _ in chAgain } }
            // Each ladder attempt waits for the gate, then fails.
            return ACPClient(context: ctx) { _ in
                for await _ in gate { break }
                return Scripted(behavior: .failInitialize)
            }
        }

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        chatA.reconnectBaseDelay = 1_000_000
        chatA.hintLifetimeNanos = 50_000_000
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-B"))
        let chatB = vm.focusedChat
        #expect(chatB !== chatA)

        await chA.close()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { chatA.acpStatus.hasPrefix("Reconnecting (") })
        chatA.sendRichText("held for the ladder", images: [], autoStartInterceptor: nil)
        #expect(chatA.isWorking, "a held send is work")

        // Every attempt fails.
        for _ in 0..<5 { gateCont.yield(()) }
        gateCont.finish()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { chatA.rowState == .error }, "no error row state")

        #expect(vm.chats.contains { $0 === chatA }, "the failed chat left the list")
        #expect(vm.liveChat(covering: "sess-A") === chatA, "its row can't find it")
        #expect(!chatA.holdsProcess)
        #expect(budget.liveCount(on: ControlMasterKey.of(home.context)) == 1, "a dead chat holds a budget slot")
        #expect(!chatA.isWorking, "a dead chat counts as working for the close confirm")
        #expect(vm.workingChats.isEmpty)

        let failed = try #require(notifier.posted.first { $0.kind == .connectionFailed })
        #expect(failed.title == ChatNotificationPolicy.connectionFailedTitle(chatName: "hello"))
        #expect(failed.route?.sessionId == "sess-A")

        // Longer than the hint's lifetime: nobody has seen this one yet.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(chatA.richChatViewModel.transientHint?.contains("couldn't be sent") == true, "the hint timed out unseen")

        chatA.hintLifetimeNanos = 60_000_000_000 // shown now; outlasts the reconnect below
        _ = reconnectWorks.next()
        vm.focus(chatA)
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) {
            chatA.acpStatus == ChatViewModel.ACPPhase.ready && chatA.isACPConnected
        }, "focusing the chat didn't reconnect it")
        #expect(await chAgain.sentMethods.contains("session/load"))
        #expect(chatA.rowState != .error)
        #expect(!chatA.isReleased)
        #expect(chatA.richChatViewModel.transientHint?.contains("couldn't be sent") == true, "the reconnect ate the hint")
        #expect(notifier.removed.contains(failed.identifier), "the notification outlived the focus")
        vm.leaveChat()
    }

    /// A start with a session and a typed message that fails in the
    /// background gets the same treatment. (A blank one stays dropped:
    /// `aKeptBackgroundStartThatFailsIsDropped`.)
    @Test @MainActor func aFailedBackgroundStartWithASessionStaysWithItsError() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        defer { gateCont.finish() }
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 { return ACPClient(context: ctx) { _ in chA } }
            return ACPClient(context: ctx) { _ in
                for await _ in gate { break }
                return Scripted(behavior: .failInitialize)
            }
        }

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })

        vm.resumeSession("sess-K")
        let chatK = vm.focusedChat
        #expect(chatK !== chatA)
        vm.sendText("typed while it starts") // an autostart carrying the text
        #expect(await Lifecycle.waitUntil { calls.count >= 2 })
        vm.focus(chatA)
        #expect(vm.chats.contains { $0 === chatK }, "a start carrying typed text was dropped")

        gateCont.yield(())
        gateCont.yield(())
        gateCont.finish()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { chatK.rowState == .error }, "no error row state")
        #expect(vm.chats.contains { $0 === chatK }, "a failed start with a session left the list")
        #expect(chatK.isReleased)
        #expect(!chatK.holdsProcess)
        #expect(!chatK.isWorking)
        #expect(chatK.richChatViewModel.transientHint?.contains("couldn't be sent") == true, "the typed text vanished without a word")
        vm.leaveChat()
    }

    // MARK: - Item 5: Live Voice is bound to its chat

    @Test @MainActor func voiceTurnsGoOnlyToTheChatVoiceStartedIn() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        Rows.install([chA, chB], on: vm)

        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        let chatA = vm.focusedChat
        #expect(vm.canStartVoiceTurns)
        #expect(!vm.canHostVoiceTurns, "turns accepted with no voice session bound")
        vm.voiceChat = chatA
        #expect(vm.canHostVoiceTurns)
        #expect(vm.voiceChatID == "sess-A")

        // Bound to A, B shown: nothing reaches B. (The window ends voice on
        // a chat change; this is the check behind that.)
        vm.sendText("keep A") // has a turn, so the new chat doesn't replace it
        #expect(await Lifecycle.waitUntil { await chA.hasHeldPrompt })
        vm.voiceChat = nil
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-B"))
        let chatB = vm.focusedChat
        vm.voiceChat = chatA
        #expect(!vm.canHostVoiceTurns)
        await #expect(throws: ChatViewModel.VoiceTurnSubmitError.noSession) {
            try await vm.submitVoiceTurn(VoiceTurnRequest(id: "v1", prompt: "spoken", context: ""))
        }
        #expect(await chB.promptTexts.isEmpty, "a voice turn landed in the chat shown")
        #expect(vm.voiceChatID == "sess-A", "the host read the chat shown, not its own")
        #expect(vm.isBusyWithNonVoiceTurn, "the host read the chat shown, not its own")

        // A chat change unbinds it.
        vm.focus(chatA)
        #expect(vm.voiceChat == nil)
        #expect(vm.voiceChatID == nil)
        #expect(vm.voiceSeedTurns().isEmpty)
        #expect(chatB !== chatA)
        vm.leaveChat()
    }

    // MARK: - Item 6: parallel_chats_used

    @Test @MainActor func concurrentChatsReportEachBucketOnce() async throws {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let channels = ["A", "B", "C", "D", "E"].map { Controlled(sessionId: "sess-\($0)") }
        Rows.install(channels, on: vm)
        func buckets() -> [String] {
            tracker.captured.filter { $0.name == "parallel_chats_used" }.compactMap { $0.props["live_chats_bucket"] }
        }

        #expect(await Rows.startWorking(vm, channels[0], "one"))
        #expect(buckets().isEmpty, "one chat isn't parallel")
        #expect(await Rows.startWorking(vm, channels[1], "two"))
        #expect(buckets() == ["2"])
        #expect(await Rows.startWorking(vm, channels[2], "three"))
        #expect(await Rows.startWorking(vm, channels[3], "four"))
        #expect(await Rows.startWorking(vm, channels[4], "five"))
        #expect(buckets() == ["2", "3", "4_plus"], "a bucket reported twice, or one missed")

        let event = try #require(tracker.captured.first { $0.name == "parallel_chats_used" })
        #expect(event.props == ["trigger": "concurrent", "live_chats_bucket": "2",
                                "transport": "local", "budget_choice": "none"])
        vm.leaveChat()
    }

    @Test @MainActor func theBudgetDialogReportsTheChoiceMade() async throws {
        let tracker = CapturingUsageTracker()
        Analytics.install(tracker)
        defer { Analytics.install(nil) }
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, budget: LiveChatBudget(localLimit: 1))
        let chA = Controlled(sessionId: "sess-A")
        Rows.install([chA], on: vm)
        #expect(await Rows.startWorking(vm, chA, "work in A"))

        vm.startNewSession()
        #expect(!tracker.captured.contains { $0.name == "parallel_chats_used" }, "reported before the dialog resolved")
        vm.waitForBudget()
        let event = try #require(tracker.captured.first { $0.name == "parallel_chats_used" })
        #expect(event.props["trigger"] == "budget_blocked")
        #expect(event.props["budget_choice"] == "waited")
        vm.leaveChat()
    }

    // MARK: - Item 7: gateway death

    /// What gateway_client.py:197-198 @ v0.22.5 raises for an in-flight prompt.
    static let gatewayDied = "Gateway disconnected; turn outcome is unknown. Resume the printed session ID to check whether it completed or was interrupted; do not resend the work."

    /// The failure shows Hermes's text, not "Internal error", and nothing
    /// resends the prompt or respawns anything.
    @Test @MainActor func aPromptLostWithTheGatewayIsShownAndNeverResent() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            // Past the first, a fresh channel: two clients on one would trap.
            let channel: any ACPChannel = calls.next() == 1 ? ch : Scripted(behavior: .happy(sessionId: "sess-extra"))
            return ACPClient(context: ctx) { _ in channel }
        }

        #expect(await Rows.startWorking(vm, ch, "do the work"))
        await ch.failPrompts(details: Self.gatewayDied)
        #expect(await Lifecycle.waitUntil { vm.acpError != nil })

        let shown = try #require(vm.acpError)
        #expect(shown.contains("turn outcome is unknown"), "showed \(shown)")
        #expect(!shown.contains("Internal error"), "showed \(shown)")
        #expect(vm.acpErrorHint?.contains("didn't resend") == true)
        #expect(vm.richChatViewModel.acpErrorDiscardIDs.isEmpty)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(await ch.promptTexts == ["do the work"], "the prompt was resent")
        #expect(calls.count == 1, "a failed prompt respawned hermes acp")
        #expect(vm.isACPConnected, "the viewer is alive; nothing should have torn it down")
        vm.leaveChat()
    }

    /// The refusal names the lost turn; the banner's offer sends `/discard
    /// <id>` to the same client and the error goes.
    @Test @MainActor func aLostTurnRefusalOffersToDiscardIt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)

        #expect(await Rows.startWorking(vm, ch, "next message"))
        await ch.failPrompts(details: "unknown_execution: do not resend accepted input; a turn in this session was lost when the gateway restarted and its outcome is unknown (nothing was submitted). Send `/discard adm-7` here (or `hermes sessions discard sess-A` in a terminal), then continue.")
        #expect(await Lifecycle.waitUntil { vm.acpError != nil })

        #expect(vm.richChatViewModel.acpErrorDiscardIDs == ["adm-7"])
        #expect(vm.acpErrorHint?.contains("/discard adm-7") == true)
        #expect(vm.acpErrorHint?.contains("wasn't sent") == true)

        vm.discardLostTurn()
        #expect(vm.acpError == nil)
        #expect(vm.richChatViewModel.acpErrorDiscardIDs.isEmpty)
        #expect(await Lifecycle.waitUntil { await ch.promptTexts == ["next message", "/discard adm-7"] },
                "the discard never went out")
        vm.leaveChat()
    }

    // MARK: - Audit: discarding two lost turns

    /// The second `/discard` waits for the first to return, and doesn't go if
    /// the first failed.
    @Test @MainActor func twoLostTurnsAreDiscardedOneAtATime() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)
        let refusal = "unknown_execution: do not resend accepted input; a turn in this session was lost when the gateway restarted and its outcome is unknown (nothing was submitted). Send `/discard adm-1` and `/discard adm-2` here (or `hermes sessions discard sess-A` in a terminal), then continue."

        #expect(await Rows.startWorking(vm, ch, "next message"))
        await ch.failPrompts(details: refusal)
        #expect(await Lifecycle.waitUntil { vm.acpError != nil })
        #expect(vm.richChatViewModel.acpErrorDiscardIDs == ["adm-1", "adm-2"])

        vm.discardLostTurn()
        #expect(await Lifecycle.waitUntil { await ch.promptTexts == ["next message", "/discard adm-1"] })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await ch.promptTexts.count == 2, "the second discard overlapped the first")
        await ch.completePrompts()
        #expect(await Lifecycle.waitUntil { await ch.promptTexts == ["next message", "/discard adm-1", "/discard adm-2"] },
                "the second discard never went out")
        await ch.completePrompts()

        // A failing first discard stops there, with its error on screen.
        vm.sendText("again")
        #expect(await Lifecycle.waitUntil { await ch.hasHeldPrompt })
        await ch.failPrompts(details: refusal)
        #expect(await Lifecycle.waitUntil { vm.richChatViewModel.acpErrorDiscardIDs.count == 2 })
        let sent = await ch.promptTexts.count
        vm.discardLostTurn()
        #expect(await Lifecycle.waitUntil { await ch.promptTexts.count == sent + 1 })
        await ch.failPrompts(details: "stale_generation")
        #expect(await Lifecycle.waitUntil { vm.acpError != nil })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await ch.promptTexts.count == sent + 1, "the next discard went out after a failure")
        vm.leaveChat()
    }

    // MARK: - Audit: what a failed start carried

    /// Starts whose client waits for `gate`, then fails.
    @MainActor
    static func failingStarts(_ vm: ChatViewModel, first: any ACPChannel, gate: AsyncStream<Void>) -> Lifecycle.CallCounter {
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 { return ACPClient(context: ctx) { _ in first } }
            return ACPClient(context: ctx) { _ in
                for await _ in gate { break }
                return Scripted(behavior: .failInitialize)
            }
        }
        return calls
    }

    /// A kickoff start with no session fails in the background: the chat is
    /// dropped and the prompt parked.
    @Test @MainActor func aKickoffWhoseBackgroundStartFailsIsParked() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        defer { gateCont.finish() }
        let calls = Self.failingStarts(vm, first: chA, gate: gate)

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        vm.startNewSession(projectPath: "/tmp/proj-kick", initialPrompt: "kick it off")
        let chatK = vm.focusedChat
        #expect(await Lifecycle.waitUntil { calls.count == 2 })
        vm.focus(chatA)
        #expect(vm.chats.contains { $0 === chatK })

        gateCont.yield(())
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { !vm.chats.contains { $0 === chatK } })
        let parked = try #require(vm.parkedKickoffs.first, "the kickoff vanished with its chat")
        #expect(parked.prompt == "kick it off")
        #expect(parked.projectPath == "/tmp/proj-kick")
        vm.leaveChat()
    }

    /// The same with a session to come back to: the chat is kept and the
    /// kickoff still parked.
    @Test @MainActor func aKickoffOnASessionWhoseBackgroundStartFailsIsParked() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        defer { gateCont.finish() }
        let calls = Self.failingStarts(vm, first: chA, gate: gate)

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        vm.startNewSession()
        let chatK = vm.focusedChat
        chatK.targetSessionId = "sess-K"
        chatK.startACPSession(resume: "sess-K", initialPrompt: "kick it off")
        #expect(await Lifecycle.waitUntil { calls.count >= 2 })
        vm.focus(chatA)

        gateCont.yield(())
        gateCont.yield(())
        gateCont.finish()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { !vm.parkedKickoffs.isEmpty }, "the kickoff vanished")
        #expect(vm.parkedKickoffs.map(\.prompt) == ["kick it off"])
        #expect(vm.chats.contains { $0 === chatK }, "a chat with a session left the list")
        #expect(chatK.rowState == .error)
        vm.leaveChat()
    }

    /// A typed first message with no session, in a chat that is then dropped,
    /// comes to the composer of the chat the user is in.
    @Test @MainActor func aTypedFirstMessageWhoseBackgroundStartFailsComesBack() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        defer { gateCont.finish() }
        let calls = Self.failingStarts(vm, first: chA, gate: gate)

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        vm.startNewSession()
        let chatT = vm.focusedChat
        #expect(chatT !== chatA)
        gateCont.yield(()) // the blank chat's own start fails, leaving it blank
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { vm.acpStatus == ChatViewModel.ACPPhase.failed })
        vm.sendText("typed first message")
        #expect(await Lifecycle.waitUntil { calls.count >= 3 })
        vm.focus(chatA)
        #expect(vm.chats.contains { $0 === chatT })

        gateCont.yield(())
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { !vm.chats.contains { $0 === chatT } })
        #expect(chatA.composer.text == "typed first message", "the message vanished with its chat")
        #expect(chatA.richChatViewModel.transientHint?.contains("couldn't start") == true)
        vm.leaveChat()
    }

    /// The watchdog tears a wedged autostart down in the background: the chat
    /// stays, and says its message wasn't sent.
    @Test @MainActor func aBackgroundStartTheWatchdogKillsSaysItsMessageWasNotSent() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        defer { gateCont.finish() } // wedged until the test ends
        let calls = Self.failingStarts(vm, first: chA, gate: gate)

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        vm.sessionStartWatchdogNanos = 400_000_000
        vm.resumeSession("sess-K")
        let chatK = vm.focusedChat
        #expect(chatK !== chatA)
        vm.sendText("typed while it starts")
        vm.focus(chatA)
        #expect(await Lifecycle.waitUntil { calls.count >= 2 })

        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { chatK.rowState == .error }, "the watchdog never fired")
        #expect(vm.chats.contains { $0 === chatK })
        #expect(chatK.richChatViewModel.transientHint?.contains("couldn't be sent") == true, "the message vanished without a word")
        vm.leaveChat()
    }

    /// A resume whose process dies during the load hands over to the ladder:
    /// the message it was carrying goes out on the ladder's client.
    @Test @MainActor func aDeadResumeHandsItsTypedMessageToTheLadder() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let first = ChatSessionsR16bMacTests.GatedReplayChannel()
        let second = ChatSessionsR16bMacTests.GatedReplayChannel()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let channel: any ACPChannel = calls.next() == 1 ? first : second
            return ACPClient(context: ctx) { _ in channel }
        }
        vm.richChatViewModel.setSessionId("sess-old")

        vm.sendText("typed")
        #expect(await Lifecycle.waitUntil { await first.hasPendingLoad })
        await first.close()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { await second.hasPendingLoad })
        await second.releaseLoad()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { await second.promptTexts == ["typed"] },
                "the message was lost in the hand-over")
        #expect(await Lifecycle.waitUntil { !vm.focusedChat.startHoldsUserInput })
        vm.leaveChat()
    }

    // MARK: - Audit: parked kickoffs and the confirms

    @Test func theConfirmsNameParkedKickoffs() throws {
        let close = try #require(ChatClosePolicy.prompt(.closeWindow, workingChatNames: [], parkedKickoffs: ["Atlas"]))
        #expect(close.title == "1 first message hasn't been sent")
        #expect(close.message == "Closing this window discards the first message waiting for “Atlas”.")

        let both = try #require(ChatClosePolicy.prompt(.switchProfile, workingChatNames: ["A"], parkedKickoffs: ["Atlas", "Zed"]))
        #expect(both.title == "1 chat is still replying")
        #expect(both.message.contains("Switching profile stops “A”."))
        #expect(both.message.contains("Switching profile discards the first message waiting for “Atlas”"))
        #expect(both.message.contains("“Zed”"))

        let quit = try #require(ChatClosePolicy.quitPrompt(workingChatNames: [[], []], parkedKickoffs: ["Atlas", "Zed"]))
        #expect(quit.title == "2 first messages haven't been sent")
        #expect(quit.message.contains("Quitting Scarf discards"))
        #expect(ChatClosePolicy.quitPrompt(workingChatNames: [[]], parkedKickoffs: []) == nil)
    }

    /// Quitting with only a parked kickoff asks, across the directory.
    @Test @MainActor func quittingWithAParkedKickoffAsks() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let directory = ChatWindowDirectory()
        let vm = Self.makeVM(home)
        let coordinator = AppCoordinator(usageTracker: NoopUsageTracker()) // the directory holds it weakly
        defer { withExtendedLifetime(coordinator) {} }
        directory.register(chat: vm, coordinator: coordinator,
                           serverID: home.context.id, hermesHome: home.context.paths.home, openWindow: { _ in })
        vm.parkKickoff(projectPath: "/tmp/Atlas", initialPrompt: "kick")
        let quit = AppQuitGuard()
        quit.workingChatNames = { directory.workingChatNamesByWindow() }
        quit.parkedKickoffNames = { directory.parkedKickoffNames() }
        var asked: [ChatClosePolicy.Prompt] = []
        quit.confirm = { asked.append($0); return false }
        quit.finish = { _ in }

        #expect(quit.shouldTerminate() == .terminateCancel)
        #expect(asked.first?.message.contains("“Atlas”") == true)
    }

    // MARK: - Audit: a refused close

    /// Close Anyway refused because a sheet is attached: the next close asks.
    @Test @MainActor func aCloseRefusedByASheetDoesNotSkipTheNextConfirm() async throws {
        typealias Close = ParallelChatsCloseConfirmTests
        let inner = Close.RecordingDelegate()
        let window = Close.makeWindow(inner)
        let proxy = WindowCloseDelegateProxy.install(on: window)
        var decisions: [(Bool) -> Void] = []
        proxy.present = { _, _, decide in decisions.append(decide) }
        proxy.setPrompt(owner: proxy) { Close.prompt }

        window.performClose(nil)
        try #require(decisions.count == 1)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: { _ in })
        #expect(await Lifecycle.waitUntil { window.attachedSheet != nil })
        let decide = try #require(decisions.first)
        decide(true)
        #expect(window.isVisible, "a window with a sheet closed")
        window.endSheet(sheet)
        #expect(await Lifecycle.waitUntil { window.attachedSheet == nil })

        window.performClose(nil)
        #expect(decisions.count == 2, "the refused close's agreement carried over to this one")
        #expect(window.isVisible)
        window.orderOut(nil)
    }

    // MARK: - Audit: the prompt failure hint

    /// No text from the server: the fallback hint, and the raw error.
    @Test @MainActor func aFailedPromptWithNoServerTextGetsTheFallbackHint() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)
        #expect(await Rows.startWorking(vm, ch, "do the work"))
        await ch.failPrompts()
        #expect(await Lifecycle.waitUntil { vm.acpError != nil })
        #expect(await Lifecycle.waitUntil { vm.acpErrorHint != nil }, "the fallback hint is gone")
        #expect(vm.acpErrorHint?.contains("The provider returned an error") == true)
        vm.leaveChat()
    }

    /// Hermes's text with no classified hint: no provider guess beside it.
    @Test @MainActor func aFailedPromptWithServerTextKeepsItAndGetsNoGuess() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)
        #expect(await Rows.startWorking(vm, ch, "do the work"))
        await ch.failPrompts(details: "session is wedged somehow")
        #expect(await Lifecycle.waitUntil { vm.acpError != nil })
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.acpError?.contains("session is wedged somehow") == true)
        #expect(vm.acpErrorHint == nil)
        vm.leaveChat()
    }

    // MARK: - Audit: handoffs

    /// Project chat and session both set: one opens, the session id doesn't
    /// linger to open a second on the next call.
    @Test @MainActor func aProjectHandoffDropsAPendingResume() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-P")
        Rows.install([ch], on: vm)
        let coordinator = AppCoordinator(usageTracker: NoopUsageTracker())

        coordinator.pendingProjectChat = "/tmp/proj"
        coordinator.selectedSessionId = "sess-other"
        vm.consumePendingOpen(from: coordinator)
        #expect(coordinator.pendingProjectChat == nil)
        #expect(coordinator.selectedSessionId == nil, "the resume stayed pending")
        vm.consumePendingOpen(from: coordinator)
        #expect(!vm.chats.contains { $0.covers("sess-other") })
        #expect(await Registry.readyOn(vm, "sess-P"))
        vm.leaveChat()
    }

    // MARK: - Audit: banners

    /// A background chat in the reconnect ladder has no process, and still
    /// holds the config banners back.
    @Test @MainActor func aChatInTheLadderHoldsTheBannersBack() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        defer { gateCont.finish() }
        _ = Self.failingStarts(vm, first: chA, gate: gate)

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        await chA.close()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { chatA.acpStatus.hasPrefix("Reconnecting (") })
        #expect(!chatA.hasActiveProcess)
        #expect(vm.hasActiveProcessInWindow, "the banners came back during the ladder")
        vm.leaveChat()
    }

    // MARK: - Audit: Wait paths

    /// A newer blocked open replaces the dialog: the older kickoff is parked.
    @Test @MainActor func aNewerBlockedOpenParksTheOlderKickoff() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, budget: LiveChatBudget(localLimit: 1))
        let chA = Controlled(sessionId: "sess-A")
        Rows.install([chA], on: vm)
        #expect(await Rows.startWorking(vm, chA, "work"))

        vm.startNewSession(projectPath: nil, initialPrompt: "older kickoff")
        #expect(vm.budgetBlocked != nil)
        vm.startNewSession()
        #expect(vm.budgetBlocked != nil)
        #expect(vm.parkedKickoffs.map(\.prompt) == ["older kickoff"], "the replaced dialog lost its kickoff")
        vm.leaveChat()
    }

    /// Stop on the dialog, but the user has moved on before the open replays:
    /// the kickoff isn't run, and isn't lost.
    @Test @MainActor func aStaleReplayParksItsKickoff() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, budget: LiveChatBudget(localLimit: 1))
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        Rows.install([chA, chB], on: vm)
        #expect(await Rows.startWorking(vm, chA, "work"))
        let chatA = vm.focusedChat

        vm.startNewSession(projectPath: nil, initialPrompt: "kick it off")
        let block = try #require(vm.budgetBlocked)
        vm.stopChatForBudget(block, chatID: chatA.id)
        vm.startNewSession() // moved on: this is the route now

        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { !vm.parkedKickoffs.isEmpty }, "the stale replay lost its kickoff")
        #expect(vm.parkedKickoffs.map(\.prompt) == ["kick it off"])
        #expect(await chB.promptTexts.isEmpty, "the stale replay ran")
        vm.leaveChat()
    }

    /// A start past the window's own admission (a preflight replay, say) that
    /// the spawn admission blocks: Wait parks the kickoff.
    @Test @MainActor func aSpawnBlockedKickoffIsParkedOnWait() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 1)
        let other = Self.makeVM(home, budget: budget)
        let vm = Self.makeVM(home, budget: budget)
        let chA = Controlled(sessionId: "sess-A")
        Rows.install([chA], on: other)
        #expect(await Rows.startWorking(other, chA, "work"))

        vm.focusedChat.startACPSession(resume: nil, projectPath: "/tmp/proj", initialPrompt: "kick it off")
        #expect(vm.budgetBlocked != nil)
        vm.waitForBudget()
        #expect(vm.parkedKickoffs.map(\.prompt) == ["kick it off"])
        other.leaveChat()
    }

    // MARK: - Audit: Quit Anyway reaches the bot conversation

    @Test @MainActor func stopAllWindowsClosesTheOpenBotConversation() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        // The conversation runs in the bot's own profile home.
        let botHome = home.path + "/profiles/scout"
        try FileManager.default.createDirectory(atPath: botHome, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: home.path + "/config.yaml", toPath: botHome + "/config.yaml")
        let channel = Scripted(behavior: .happy(sessionId: "bot-chat-1"))
        let coordinator = AppCoordinator(usageTracker: NoopUsageTracker())
        let capabilities = HermesCapabilities.parseLine("Hermes Agent v0.22.5 (2026.10.1)")
        let bots = coordinator.featureViewModel(for: .bots) {
            BotsViewModel(context: home.context, capabilities: capabilities)
        }
        bots.makeConversation = { ctx, name in
            BotConversationViewModel(
                profileName: name,
                context: ctx,
                locator: { _ in HermesDataService.CanonicalBotChat(registryId: "bot-chat-1", liveId: "bot-chat-1", liveSource: "acp") },
                creator: { _, _, _ in nil },
                acpClientMaker: { ctx, _, _ in ACPClient(context: ctx) { _ in channel } }
            )
        }
        bots.openConversation(for: "scout")
        let conversation = try #require(bots.conversation)
        #expect(await Lifecycle.waitUntil { conversation.chat.isACPConnected })

        let directory = ChatWindowDirectory()
        let vm = Self.makeVM(home)
        directory.register(chat: vm, coordinator: coordinator, serverID: home.context.id,
                           hermesHome: home.context.paths.home, openWindow: { _ in })
        let teardowns = directory.stopAllWindows()
        #expect(!teardowns.isEmpty, "the bot chat's teardown wasn't handed to the quit")
        #expect(bots.conversation == nil)
        #expect(await Lifecycle.waitUntil { await channel.closed }, "the bot conversation outlived Quit Anyway")
    }

    // MARK: - Item 8: the confirms

    @Test @MainActor func cancelIsTheReturnKeyDefaultInTheCloseAndQuitConfirms() throws {
        let prompt = ChatClosePolicy.Prompt(title: "t", message: "m")
        for title in ["Close Anyway", "Quit Anyway"] {
            let alert = ChatClosePolicy.alert(for: prompt, confirmTitle: title)
            alert.layout() // the default button's key is assigned here
            let first = try #require(alert.buttons.first)
            let confirm = try #require(alert.buttons.last)
            #expect(alert.buttons.count == 2)
            #expect(first.title == "Cancel")
            #expect(first.keyEquivalent == "\r", "Return doesn't land on Cancel")
            #expect(alert.window.defaultButtonCell?.title == "Cancel", "the window's default button isn't Cancel")
            #expect(confirm.title == title)
            #expect(confirm.keyEquivalent != "\r", "Return lands on the destructive button")
            #expect(confirm.hasDestructiveAction)
        }
        // The answer the destructive button gives: it is the second added.
        #expect(ChatClosePolicy.confirmResponse == .alertSecondButtonReturn)
    }

    /// A Bot Chat's first message creates the conversation over the CLI, with
    /// no ACP turn: closing during it asks, naming the bot.
    @Test @MainActor func aBotChatsFirstMessageCountsAsWorking() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let vm = BotConversationViewModel(
            profileName: "scout",
            context: home.context,
            locator: { _ in nil },
            creator: { _, _, _ in
                for await _ in gate { break }
                return nil
            },
            acpClientMaker: { ctx, _, _ in
                ACPClient(context: ctx) { _ in Scripted(behavior: .happy(sessionId: "s")) }
            }
        )
        vm.open()
        #expect(await Lifecycle.waitUntil { vm.phase == .noConversationYet })
        #expect(vm.chat.workingChats.isEmpty)

        vm.send("first message")
        #expect(vm.phase == .creating)
        let working = vm.chat.workingChats
        #expect(working.count == 1, "closing during the first message wouldn't ask")
        #expect(working.first?.displayTitle == "scout")

        gateCont.yield(())
        gateCont.finish()
        #expect(await Lifecycle.waitUntil { vm.phase != .creating })
        #expect(vm.chat.workingChats.isEmpty, "still working after the message was delivered")
        vm.close()
    }
}
