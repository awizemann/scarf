import Testing
import Foundation
import ScarfCore
@testable import scarf

/// The v3.8.0 audit's chat-lifecycle findings, each driven through a real
/// `ChatViewModel` over a scripted channel.
@Suite struct ChatAuditP2Tests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias Rows = ParallelChatsRowsNotificationsTests
    typealias Gated = ChatSessionsR16bMacTests.GatedReplayChannel

    // MARK: - Stuck on "Agent working" (#1)

    /// Holds the first turn's post-processing open until the test releases it.
    @MainActor
    final class PostProcessingHold {
        private(set) var reached = false
        private var calls = 0
        private let gate: AsyncStream<Void>
        private let gateContinuation: AsyncStream<Void>.Continuation

        init() {
            (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        }

        func hook(_ text: String) async {
            calls += 1
            guard calls == 1 else { return }
            reached = true
            for await _ in gate { break }
        }

        func release() { gateContinuation.finish() }
    }

    /// Runs "first" to its end by `finish`, holds its post-processing open,
    /// then runs a second turn to its end: its completion has to land.
    @MainActor
    private static func aLaterTurnCompletes(
        finishFirst finish: (Rows.ControlledChannel) async -> Void
    ) async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let channel = Rows.ControlledChannel(sessionId: "sess-A")
        Rows.install([channel], on: vm)
        let hold = PostProcessingHold()
        vm.focusedChat.afterTurnClosedForTesting = { await hold.hook($0) }
        defer { hold.release() }

        #expect(await Rows.startWorking(vm, channel, "first"))
        await finish(channel)
        #expect(await Lifecycle.waitUntil { hold.reached })
        #expect(!vm.richChatViewModel.isAgentWorking)
        #expect(!vm.focusedChat.hasTurnInFlight, "a closed turn still counted as in flight")

        vm.sendText("/second")
        #expect(await Lifecycle.waitUntil { await channel.hasHeldPrompt })
        #expect(vm.richChatViewModel.isAgentWorking)
        await channel.completePrompts()
        #expect(await Lifecycle.waitUntil { !vm.richChatViewModel.isAgentWorking },
                "the later turn skipped its completion: stuck on Agent working")
        #expect(await Lifecycle.waitUntil { !vm.focusedChat.hasTurnInFlight })
        vm.leaveChat()
    }

    @Test @MainActor func aTurnReturningDuringAnEarlierTurnsPostProcessingCompletes() async throws {
        try await Self.aLaterTurnCompletes { await $0.completePrompts() }
    }

    @Test @MainActor func aTurnReturningAfterAnEarlierTurnFailedCompletes() async throws {
        try await Self.aLaterTurnCompletes { await $0.failPrompts() }
    }

    // MARK: - Held sends survive stop() (#4)

    /// A send held behind an autostart's undrained load, then a deliberate
    /// stop: `holdingForPendingClient` is false by then, and the held send
    /// used to survive, so the chat counted as working for good.
    @Test @MainActor func stopDropsSendsHeldForAClient() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let channel = Gated()
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.richChatViewModel.setSessionId("sess-old")

        vm.sendText("first")
        #expect(await Lifecycle.waitUntil { await channel.hasPendingLoad })
        vm.sendText("second")
        #expect(vm.focusedChat.hasHeldSends)

        vm.focusedChat.stop()
        #expect(!vm.focusedChat.hasHeldSends, "stop() left a held send behind")
        #expect(!vm.focusedChat.isBusyForBudget)
        #expect(vm.workingChats.isEmpty, "a stopped chat still counted as working")
        #expect(!vm.richChatViewModel.isAgentWorking, "a stopped chat still showed Agent working")
        await channel.releaseLoad()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await channel.promptTexts.isEmpty, "a stopped start still sent")
    }

    /// A caller that wants a hint still gets one: the budget's release says
    /// what was lost where it was typed.
    @Test @MainActor func releaseStillSaysWhatItDropped() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let channel = Gated()
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.richChatViewModel.setSessionId("sess-old")

        vm.sendText("first")
        #expect(await Lifecycle.waitUntil { await channel.hasPendingLoad })
        vm.sendText("second")

        vm.focusedChat.releaseProcess()
        #expect(!vm.focusedChat.hasHeldSends)
        #expect(vm.richChatViewModel.transientHint?.contains("couldn't be sent") == true)
        #expect(!vm.richChatViewModel.isAgentWorking)
    }

    // MARK: - Spawn after close or delete (#5)

    /// `resumeSession` is in its off-main attribution read when these run
    /// (same actor, no suspension yet), so the pipeline resumes afterwards:
    /// it must abandon rather than spawn `hermes acp` for a gone window.
    @MainActor
    private static func expectNoSpawn(afterStop stop: (ChatViewModel) -> Void) async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            _ = calls.next()
            let channel = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "sess-R"))
            return ACPClient(context: ctx) { _ in channel }
        }

        vm.resumeSession("sess-R")
        stop(vm)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(calls.count == 0, "a stopped chat's pending start spawned hermes acp")
        #expect(!vm.isPreparingSession)
    }

    @Test @MainActor func stopAllChatsAbandonsTheFocusedChatsPendingStart() async throws {
        try await Self.expectNoSpawn { _ = $0.stopAllChats() }
    }

    @Test @MainActor func stopForDeletionAbandonsAPendingStart() async throws {
        try await Self.expectNoSpawn { _ = $0.focusedChat.stopForDeletion() }
    }

    /// Stop semantics stay: the focused chat is kept, and can start again.
    @Test @MainActor func aChatStoppedByStopAllChatsCanStartAgain() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let channel = Rows.ControlledChannel(sessionId: "sess-A")
        Rows.install([channel], on: vm)
        let focused = vm.focusedChat

        _ = vm.stopAllChats()
        #expect(vm.chats.count == 1 && vm.focusedChat === focused)
        vm.startNewSession()
        #expect(await ParallelChatsRegistryTests.readyOn(vm, "sess-A"))
        vm.leaveChat()
    }

    // MARK: - Sends while the session is still being created

    /// Holds `session/new` and `session/load` until told, then answers or fails.
    actor SlowOpenChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private var heldOpen: Int?
        private(set) var promptTexts: [String] = []
        var diagnosticID: String? { "slow-open-channel" }
        var isOpening: Bool { heldOpen != nil }

        init() {
            (incoming, incomingCont) = AsyncThrowingStream<String, Error>.makeStream()
            (stderr, stderrCont) = AsyncThrowingStream<String, Error>.makeStream()
        }

        func send(_ line: String) async throws {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            if method == "session/prompt",
               let prompt = (obj["params"] as? [String: Any])?["prompt"] as? [[String: Any]] {
                promptTexts.append(prompt.compactMap { $0["text"] as? String }.joined())
            }
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/new", "session/load": heldOpen = id
            case "session/prompt": reply(["jsonrpc": "2.0", "id": id, "result": ["stopReason": "end_turn"]])
            default: reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        func finishOpen() {
            guard let id = heldOpen else { return }
            heldOpen = nil
            reply(["jsonrpc": "2.0", "id": id,
                   "result": ["sessionId": "sess-slow", "modes": ["currentModeId": "default"]]])
        }

        func failOpen() {
            guard let id = heldOpen else { return }
            heldOpen = nil
            reply(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "scripted open failure"]])
        }

        func close() async {
            incomingCont.finish()
            stderrCont.finish()
        }

        private func reply(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }
    }

    @MainActor
    private static func slowVM(_ home: TempHermesHome, _ channel: SlowOpenChannel) -> ChatViewModel {
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        return vm
    }

    /// Typed during the wait: shown, counted as working, and sent once.
    @MainActor
    private static func heldThenSentOnce(start: (ChatViewModel) -> Void) async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let channel = SlowOpenChannel()
        let vm = Self.slowVM(home, channel)
        start(vm)
        #expect(await Lifecycle.waitUntil { await channel.isOpening })

        vm.sendText("typed while starting")
        #expect(vm.acpError == nil, "a send during the wait failed")
        #expect(vm.richChatViewModel.messages.contains { $0.isUser && $0.content == "typed while starting" })
        #expect(vm.focusedChat.hasHeldSends)
        #expect(vm.focusedChat.isBusyForBudget)
        #expect(vm.workingChats.count == 1, "a held send didn't count for the close prompts")

        await channel.finishOpen()
        #expect(await Lifecycle.waitUntil { await channel.promptTexts == ["typed while starting"] },
                "the held send never went out")
        #expect(!vm.focusedChat.hasHeldSends)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await channel.promptTexts == ["typed while starting"], "the send went out twice")
        // After the open and any history load: the bubble is still there, once.
        #expect(vm.richChatViewModel.messages.filter { $0.isUser && $0.content == "typed while starting" }.count == 1,
                "the sent message lost its bubble")
        #expect(vm.acpError == nil)
        vm.leaveChat()
    }

    @Test @MainActor func aSendWhileANewChatStartsIsHeldAndSentOnce() async throws {
        try await Self.heldThenSentOnce { $0.startNewSession() }
    }

    @Test @MainActor func aSendWhileAResumeLoadsIsHeldAndSentOnce() async throws {
        try await Self.heldThenSentOnce { $0.resumeSession("sess-slow") }
    }

    /// With a real `state.db`, so the history load replaces the transcript.
    @Test @MainActor func aSendDuringAResumeKeepsItsBubbleAfterTheHistoryLoads() async throws {
        let home = try ChatResumeFallback146Tests.home(sessions: [("sess-slow", "stored history")])
        defer { home.cleanup() }
        let channel = SlowOpenChannel()
        let vm = Self.slowVM(home, channel)
        vm.resumeSession("sess-slow")
        #expect(await Lifecycle.waitUntil { await channel.isOpening })

        vm.sendText("typed while loading")
        await channel.finishOpen()
        #expect(await Lifecycle.waitUntil { await channel.promptTexts == ["typed while loading"] })
        #expect(await Lifecycle.waitUntil {
            vm.richChatViewModel.messages.filter { $0.isUser && $0.content == "typed while loading" }.count == 1
        }, "the history load wiped the held send's bubble")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.richChatViewModel.messages.filter { $0.isUser && $0.content == "typed while loading" }.count == 1)
        vm.leaveChat()
    }

    @Test @MainActor func aFailedStartPutsTheHeldTextBackWithTheReason() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let channel = SlowOpenChannel()
        let vm = Self.slowVM(home, channel)
        vm.startNewSession()
        #expect(await Lifecycle.waitUntil { await channel.isOpening })
        let chat = vm.focusedChat
        vm.sendText("one")
        vm.sendText("two")

        await channel.failOpen()
        #expect(await Lifecycle.waitUntil { chat.composer.text == "one\n\ntwo" }, "the held text was lost")
        #expect(await Lifecycle.waitUntil { chat.acpError != nil }, "no reason shown")
        #expect(!chat.richChatViewModel.messages.contains { $0.isUser }, "an unsent echo stayed")
        #expect(!chat.richChatViewModel.isAgentWorking)
        #expect(!chat.hasHeldSends)
        #expect(await channel.promptTexts.isEmpty)
    }

    @Test @MainActor func stoppingDuringTheWaitPutsTheHeldTextBack() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let channel = SlowOpenChannel()
        let vm = Self.slowVM(home, channel)
        vm.startNewSession()
        #expect(await Lifecycle.waitUntil { await channel.isOpening })
        vm.sendText("typed")

        vm.focusedChat.stop()
        #expect(vm.focusedChat.composer.text == "typed")
        #expect(!vm.focusedChat.hasHeldSends)
        #expect(!vm.richChatViewModel.isAgentWorking)
        #expect(vm.richChatViewModel.transientHint?.contains("back in the composer") == true)
    }

    // Held sends when the chat goes away, images that can't fit, slash commands.

    /// A background new chat: its start fails and it is dropped. What was held
    /// comes to the chat the user is in, after their draft.
    @Test @MainActor func aDroppedBackgroundChatHandsOnItsHeldText() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let channel = SlowOpenChannel()
        let other = Rows.ControlledChannel(sessionId: "sess-B")
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        Rows.install([channel, other], on: vm)

        vm.startNewSession()
        #expect(await Lifecycle.waitUntil { await channel.isOpening })
        let slow = vm.focusedChat
        vm.sendText("held in the background")
        vm.startNewSession()
        #expect(vm.focusedChat !== slow, "a chat with a held send wasn't kept")
        #expect(await ParallelChatsRegistryTests.readyOn(vm, "sess-B"))
        vm.focusedChat.composer.text = "my draft"

        await channel.failOpen()
        #expect(await Lifecycle.waitUntil { !vm.chats.contains { $0 === slow } }, "the failed chat wasn't dropped")
        #expect(vm.focusedChat.composer.text == "my draft\n\nheld in the background",
                "the held text was lost or overwrote the draft")
        vm.leaveChat()
    }

    /// Budget Stop on the shown chat: the open reuses it and clears its draft,
    /// so the held text has to survive that.
    @Test @MainActor func budgetStopOnTheShownChatKeepsItsHeldText() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 1)
        let vm = ChatViewModel(context: home.context, liveChatBudget: budget)
        let channel = SlowOpenChannel()
        let other = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "sess-O"))
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let first = calls.next() == 1
            return first ? ACPClient(context: ctx) { _ in channel } : ACPClient(context: ctx) { _ in other }
        }
        vm.startNewSession()
        #expect(await Lifecycle.waitUntil { await channel.isOpening })
        vm.sendText("held at stop")
        let working = vm.focusedChat

        vm.startNewSession()
        let block = try #require(vm.budgetBlocked, "a chat with a held send didn't block the open")
        vm.stopChatForBudget(block, chatID: working.id)
        #expect(await ParallelChatsRegistryTests.readyOn(vm, "sess-O"))
        #expect(await Lifecycle.waitUntil { vm.focusedChat.composer.text.contains("held at stop") },
                "budget Stop lost the held text")
        #expect(vm.focusedChat.composer.text.components(separatedBy: "held at stop").count == 2,
                "the held text was handed on twice")
        vm.leaveChat()
    }

    @Test @MainActor func imagesThatCannotFitAreNamedInTheHint() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let channel = SlowOpenChannel()
        let vm = Self.slowVM(home, channel)
        vm.startNewSession()
        #expect(await Lifecycle.waitUntil { await channel.isOpening })
        let chat = vm.focusedChat
        vm.sendText("with image", images: [Rows.image()])
        chat.composer.slots.restore(Array(repeating: Rows.image(), count: ComposerAttachmentSlots.defaultCapacity))

        chat.stop()
        #expect(chat.composer.text == "with image")
        #expect(chat.richChatViewModel.transientHint?.contains("didn't fit") == true, "a lost image went unmentioned")
    }

    /// A held `/new` in a chat now in the background: no orphan bubble, and not
    /// stuck working.
    @Test @MainActor func aHeldSlashCommandLeavesNoOrphanBubble() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let channel = SlowOpenChannel()
        let other = Rows.ControlledChannel(sessionId: "sess-B")
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        Rows.install([channel, other], on: vm)
        vm.resumeSession("sess-slow")
        #expect(await Lifecycle.waitUntil { await channel.isOpening })
        let held = vm.focusedChat
        vm.sendText("/new")
        #expect(held.hasHeldSends)
        vm.startNewSession()
        #expect(await ParallelChatsRegistryTests.readyOn(vm, "sess-B"))

        await channel.finishOpen()
        #expect(await Lifecycle.waitUntil { !held.hasHeldSends })
        #expect(!held.richChatViewModel.messages.contains { $0.isUser && $0.content == "/new" }, "orphan bubble")
        #expect(!held.richChatViewModel.isAgentWorking, "stuck working")
        vm.leaveChat()
    }

    /// `RichChatInputBar`'s order: a send refused during delivery keeps its text.
    @Test @MainActor func aSendHandedBackDuringDeliveryIsNotCleared() {
        let draft = ComposerDraft()
        draft.text = "typed"
        draft.clearThenSend { draft.appendUnsent(text: "typed", images: []) }
        #expect(draft.text == "typed")
    }

    /// The last-resort path keeps the text too.
    @Test @MainActor func aSendWithNoSessionNeverLosesItsText() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Rows.makeVM(home, Rows.RecordingNotifier())
        let chat = vm.focusedChat
        chat.sendViaACP(client: ACPClient(context: home.context) { _ in SlowOpenChannel() }, text: "kept")
        #expect(chat.composer.text == "kept")
        #expect(chat.acpError != nil)
    }

    // MARK: - Needs-answer notification copy (#7)

    @Test func theNeedsAnswerBodyDependsOnlyOnTheKind() {
        func body(_ kind: String, _ prompt: RichChatViewModel.PermissionPrompt = .toolApproval) -> String {
            ChatNotificationPolicy.needsAnswerBody(kind: kind, prompt: prompt)
        }
        #expect(body("execute") == "A command is waiting for your approval.")
        #expect(body("edit") == "A file edit is waiting for your approval.")
        #expect(body("delete") == "A deletion is waiting for your approval.")
        #expect(body("other") == "A tool is waiting for your approval.")
        #expect(body("") == "A tool is waiting for your approval.")
        // A gateway question's title is the question itself: not shown either.
        #expect(body("other", .clarify) == "Hermes has a question for you.")
        #expect(body("execute", .modelConfirmation) == "Hermes wants to confirm a model switch.")
    }

    // MARK: - Project accept_edits vs the user's pick (#8)

    typealias Budget = ParallelChatsBudgetTests
    typealias ModeChannel = ParallelChatsBudgetTests.ModeChannel

    /// A chat in an opted-in project, on `first`, then `second` for the next
    /// spawn; the user has picked `pick` in it.
    @MainActor
    private static func projectChat(
        _ home: TempHermesHome, first: ModeChannel, second: ModeChannel, pick: ACPApprovalMode
    ) async throws -> ChatViewModel {
        let suite = "audit-mode-\(UUID().uuidString)"
        let vm = try await Budget.modeVM(home, suite: suite)
        let store = ProjectAutoAcceptEditsStore(suiteName: suite, testServiceSuffix: "aae-\(UUID().uuidString)")
        #expect(store.setEnabled(true, projectId: "/p/opted-in"))
        vm.autoAcceptEditsStore = store
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let channel = calls.next() == 1 ? first : second
            return ACPClient(context: ctx) { _ in channel }
        }
        vm.startNewSession(projectPath: "/p/opted-in")
        #expect(await ParallelChatsRegistryTests.readyOn(vm, "sess-A"))
        #expect(await Lifecycle.waitUntil { await first.modeIds == ["accept_edits"] })
        vm.switchApprovalMode(pick)
        #expect(await Lifecycle.waitUntil { vm.focusedChat.userPickedApprovalMode == pick })
        return vm
    }

    @MainActor
    private static func releaseAndReattach(_ vm: ChatViewModel, on second: ModeChannel) async {
        let chat = vm.focusedChat
        await chat.releaseProcess()?.value
        vm.focus(chat)
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 15) {
            let loaded = await second.sentMethods.contains("session/load")
            return loaded && vm.acpStatus == ChatViewModel.ACPPhase.ready
        })
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// A Default pick stands: the project's accept_edits is not applied on
    /// the way back, not even for a moment.
    @Test @MainActor func aReattachDoesNotApplyTheProjectsAcceptEditsOverAPick() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "default")
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .default)
        defer { vm.leaveChat() }

        await Self.releaseAndReattach(vm, on: second)
        #expect(await second.modeIds.isEmpty, "a mode was set over the user's Default pick")
        #expect(vm.richChatViewModel.activeApprovalMode == .default)
    }

    /// The session came back looser than the pick and the re-send failed: say so.
    @Test @MainActor func aFailedReattachResendThatLeavesMoreAllowedRaisesAnError() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "accept_edits", rejectSetMode: true)
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .default)
        defer { vm.leaveChat() }

        await Self.releaseAndReattach(vm, on: second)
        #expect(await second.modeIds == ["default"])
        #expect(vm.acpError?.contains("Default") == true, "a failed re-send was only logged")
    }

    /// A host that doesn't report its mode might be in anything.
    @Test @MainActor func aFailedResendOnAnUnreportedModeRaisesAnError() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: nil, rejectSetMode: true)
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .default)
        defer { vm.leaveChat() }

        await Self.releaseAndReattach(vm, on: second)
        #expect(vm.acpError != nil)
    }

    /// Failing to restore a looser pick only means more prompts: no alert.
    @Test @MainActor func aFailedResendThatCanOnlyAskMoreStaysQuiet() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "default", rejectSetMode: true)
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .dontAsk)
        defer { vm.leaveChat() }

        await Self.releaseAndReattach(vm, on: second)
        #expect(await second.modeIds == ["dont_ask"])
        #expect(vm.acpError == nil)
    }

    // MARK: - No prompts into a session looser than the pick

    /// A chat released, re-attached by typing: the re-send fails on a session
    /// that came back looser. The held text returns, and nothing goes out.
    @MainActor
    private static func refusedAfterReattach(
        _ home: TempHermesHome, first: ModeChannel, second: ModeChannel
    ) async throws -> ChatViewModel {
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .default)
        await vm.focusedChat.releaseProcess()?.value
        vm.sendText("typed while released")
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 15) {
            let set = await second.modeIds == ["default"]
            return set && vm.focusedChat.composer.text == "typed while released"
        }, "the held send never came back to the composer")
        return vm
    }

    @Test @MainActor func aHeldSendComesBackInsteadOfGoingToALooserSession() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "accept_edits", rejectSetMode: true)
        let vm = try await Self.refusedAfterReattach(home, first: first, second: second)
        defer { vm.leaveChat() }

        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await second.sentMethods.contains("session/prompt") == false, "a prompt went to a looser session")
        #expect(vm.acpError?.contains("Default") == true)
        #expect(!vm.richChatViewModel.isAgentWorking)
        #expect(!vm.richChatViewModel.messages.contains { $0.isUser && $0.content == "typed while released" },
                "the unsent message's echo stayed in the transcript")
    }

    /// The next send is refused too, keeps the banner and retries the mode;
    /// once the mode is back, sends flow again.
    @Test @MainActor func theNextSendRetriesTheModeAndOnlyFlowsOnceItIsBack() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "accept_edits", rejectSetMode: true)
        let vm = try await Self.refusedAfterReattach(home, first: first, second: second)
        defer { vm.leaveChat() }
        let chat = vm.focusedChat
        chat.composer.text = ""
        // However the banner went, a refused send puts it back.
        vm.richChatViewModel.clearACPErrorState()

        vm.sendText("again")
        #expect(chat.composer.text == "again")
        #expect(vm.acpError != nil, "the next send cleared the banner while the mode stayed looser")
        #expect(await Lifecycle.waitUntil { await second.modeIds == ["default", "default"] }, "no retry")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(vm.acpError != nil)
        #expect(await second.sentMethods.contains("session/prompt") == false)

        await second.acceptSetMode()
        chat.composer.text = ""
        vm.sendText("third")
        #expect(chat.composer.text == "third")
        #expect(await Lifecycle.waitUntil { vm.acpError == nil }, "a successful retry left the banner")
        #expect(await second.sentMethods.contains("session/prompt") == false, "the refused send went out anyway")
        #expect(vm.richChatViewModel.activeApprovalMode == .default)

        vm.sendText("fourth")
        #expect(await Lifecycle.waitUntil { await second.sentMethods.contains("session/prompt") },
                "sends didn't flow once the mode was back")
    }

    /// Picking a mode the host accepts settles it as well.
    @Test @MainActor func pickingAModeTheHostAcceptsLiftsTheRefusal() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "dont_ask", rejectSetMode: true)
        let vm = try await Self.refusedAfterReattach(home, first: first, second: second)
        defer { vm.leaveChat() }

        await second.acceptSetMode()
        vm.switchApprovalMode(.acceptEdits)
        #expect(await Lifecycle.waitUntil { vm.acpError == nil })
        vm.sendText("now")
        #expect(await Lifecycle.waitUntil { await second.sentMethods.contains("session/prompt") })
    }

    @Test @MainActor func liveVoiceIsRefusedOnALooserSession() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "accept_edits", rejectSetMode: true)
        let vm = try await Self.refusedAfterReattach(home, first: first, second: second)
        defer { vm.leaveChat() }

        vm.voiceChat = vm.focusedChat
        try await vm.submitVoiceTurn(VoiceTurnRequest(id: "v1", prompt: "spoken", context: ""))
        #expect(vm.voiceTurnReply(for: "v1")?.text == ChatViewModel.voiceBusyReply)
        #expect(await second.sentMethods.contains("session/prompt") == false)
    }

    /// The reconnect ladder too, whose own clean-up must not wipe the banner.
    @Test @MainActor func aFailedResendOnTheReconnectLadderKeepsItsError() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "accept_edits", rejectSetMode: true)
        let vm = try await Self.projectChat(home, first: first, second: second, pick: .default)
        defer { vm.leaveChat() }

        await first.close()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { await second.modeIds == ["default"] })
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { vm.acpStatus == ChatViewModel.ACPPhase.ready })
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.acpError?.contains("Default") == true, "the ladder wiped the failed re-send's error")
    }
}
