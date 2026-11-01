import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Parallel chats P1, step 2: the live-chat budget (`LiveChatBudget`),
/// releasing and re-attaching a chat's process, the approval mode a chat
/// remembers across a reload, and single-flight ControlMaster recovery with
/// staggered reconnects (`SSHMasterRecovery`).
///
/// ACP is scripted through the `acpClientFactory` seam, one channel per
/// spawn in call order. Every test builds its own budget: all test contexts
/// are `.local`, so they would share the app-wide one.
@Suite struct ParallelChatsBudgetTests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias Registry = ParallelChatsRegistryTests
    typealias Scripted = ChatViewModelStartLifecycleTests.ScriptedACPChannel
    typealias Gated = ChatSessionsR16bMacTests.GatedReplayChannel

    // MARK: - Scripted channel

    /// Answers every request, completes prompts at once (`end_turn`),
    /// reports `loadMode` as the session's mode on `session/load` (nil:
    /// no `modes` at all, as a host without them answers), and
    /// records methods and every `session/set_mode` mode id.
    actor ModeChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let sessionId: String
        private let loadMode: String?
        private let rejectSetMode: Bool

        private(set) var closed = false
        private(set) var sentMethods: [String] = []
        private(set) var modeIds: [String] = []
        var diagnosticID: String? { "mode-channel" }

        init(sessionId: String, loadMode: String? = "default", rejectSetMode: Bool = false) {
            self.sessionId = sessionId
            self.loadMode = loadMode
            self.rejectSetMode = rejectSetMode
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = inStream
            incomingCont = inCont
            stderr = errStream
            stderrCont = errCont
        }

        func send(_ line: String) async throws {
            if closed { throw ACPChannelError.writeEndClosed }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String
            else { return }
            sentMethods.append(method)
            if method == "session/set_mode",
               let modeId = (obj["params"] as? [String: Any])?["modeId"] as? String {
                modeIds.append(modeId)
            }
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/set_mode" where rejectSetMode:
                reply(["jsonrpc": "2.0", "id": id,
                       "error": ["code": -32603, "message": "scripted set_mode failure"]])
            case "session/new":
                reply(["jsonrpc": "2.0", "id": id,
                       "result": ["sessionId": sessionId, "modes": ["currentModeId": "default"]]])
            case "session/load":
                var result: [String: Any] = ["sessionId": sessionId]
                if let loadMode { result["modes"] = ["currentModeId": loadMode] }
                reply(["jsonrpc": "2.0", "id": id, "result": result])
            case "session/prompt":
                reply(["jsonrpc": "2.0", "id": id, "result": ["stopReason": "end_turn"]])
            default:
                reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        private func reply(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }

        func close() async {
            guard !closed else { return }
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }
    }

    // MARK: - Helpers

    /// Start a new chat on `channel` and leave a turn in flight (a `happy`
    /// channel never answers the prompt): a working chat.
    @MainActor
    static func startWorking(_ vm: ChatViewModel, _ channel: Scripted, _ sessionId: String) async -> Bool {
        vm.startNewSession()
        guard await Registry.readyOn(vm, sessionId) else { return false }
        vm.sendText("work")
        return await Lifecycle.waitUntil { await channel.sentMethods.contains("session/prompt") && vm.canStopCurrentTurn }
    }

    @MainActor
    static func userTexts(_ chat: ChatSession) -> [String] {
        chat.richChatViewModel.messages.filter(\.isUser).map(\.content)
    }

    // MARK: - Release on a full budget

    /// Budget 2, an idle chat and a working one: a third open releases the
    /// idle chat's process — its channel closes, the chat stays in the
    /// window with its transcript — and leaves the working one running.
    @Test @MainActor func aThirdOpenReleasesTheIdleChatNotTheWorkingOne() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context, liveChatBudget: LiveChatBudget(localLimit: 2))
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .happy(sessionId: "sess-B"))
        let chC = Scripted(behavior: .answeringPrompts(sessionId: "sess-C"))
        let calls = Registry.install([chA, chB, chC], on: vm)

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Self.startWorking(vm, chB, "sess-B"))
        let chatB = vm.focusedChat
        // Least recently used is not enough: the working chat goes first in
        // that order, and is still not released.
        chatB.lastUsedAt = .distantPast

        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-C"), "the third open never came up")
        #expect(calls.count == 3)
        #expect(vm.budgetBlocked == nil)

        #expect(await Lifecycle.waitUntil { await chA.closed }, "the idle chat kept its process")
        #expect(chatA.isReleased)
        #expect(!chatA.holdsProcess)
        #expect(vm.chats.contains { $0 === chatA }, "the released chat left the window")
        #expect(Self.userTexts(chatA) == ["hello"], "the released chat lost its transcript")
        #expect(chatA.richChatViewModel.sessionId == "sess-A")

        #expect(await chB.closed == false, "the working chat was released")
        #expect(chatB.hasTurnInFlight)
        #expect(await chB.sentMethods.contains("session/cancel") == false)
        #expect(vm.liveChatBudget.liveCount(on: .local) == 2)
    }

    /// Two windows on one master count together, and the chat a window
    /// shows is never released — even when it is the least recently used.
    /// The chat the opening window is leaving is.
    @Test @MainActor func twoWindowsShareTheBudgetAndAShownChatIsNotReleased() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 2)
        let w1 = ChatViewModel(context: home.context, liveChatBudget: budget)
        let w2 = ChatViewModel(context: home.context, liveChatBudget: budget)
        let chF = Scripted(behavior: .answeringPrompts(sessionId: "sess-F"))
        _ = Registry.install([chF], on: w1)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chC = Scripted(behavior: .answeringPrompts(sessionId: "sess-C"))
        _ = Registry.install([chA, chC], on: w2)

        #expect(await Registry.startWithATurn(w1, chF, "sess-F"))
        let shown = w1.focusedChat
        #expect(await Registry.startWithATurn(w2, chA, "sess-A"))
        let leaving = w2.focusedChat
        // The shown chat is the least recently used one.
        shown.lastUsedAt = .distantPast
        #expect(budget.liveCount(on: .local) == 2)

        w2.startNewSession()
        #expect(await Registry.readyOn(w2, "sess-C"))
        #expect(await Lifecycle.waitUntil { await chA.closed }, "the chat w2 left kept its process")
        #expect(leaving.isReleased)
        #expect(await chF.closed == false, "the chat w1 shows was released")
        #expect(!shown.isReleased)
        #expect(budget.liveCount(on: .local) == 2)
    }

    /// The budget is per ControlMaster: two server entries for the same
    /// `user@host:port` share one, another host doesn't, and local is its
    /// own. (Chats held "starting" stand in for working ones — a remote
    /// start can't run here.)
    @Test @MainActor func theBudgetIsPerControlMaster() async throws {
        let host = ChatViewModel(context: .local, liveChatBudget: LiveChatBudget())
        let budget = LiveChatBudget(localLimit: 1, remoteLimit: 1)
        func chat(_ context: ServerContext) -> ChatSession {
            let chat = ChatSession(
                context: context,
                dataService: HermesDataService(context: context),
                fileService: HermesFileService(context: context)
            )
            chat.host = host
            chat.isStartingSession = true // holds a slot, busy
            budget.register(chat)
            return chat
        }
        func ssh(_ name: String, _ host: String, port: Int? = nil) -> ServerContext {
            ServerContext(id: UUID(), displayName: name, kind: .ssh(SSHConfig(host: host, user: "alan", port: port)))
        }
        let first = chat(ssh("Box", "box.example"))
        let local = chat(.local) // members are weak: keep it

        // A second entry for the same master: full, and the working chat
        // on it is what the user is offered to stop.
        let sameMaster = ssh("Box again", "BOX.example", port: 22)
        guard case .full(let working) = budget.admit(
            on: ControlMasterKey.of(sameMaster), excluding: nil) else {
            Issue.record("a second entry for the same master was admitted past the limit")
            return
        }
        #expect(working.count == 1 && working.first === first)
        // Another host has its own slots; so does local, already full.
        if case .full = budget.admit(on: ControlMasterKey.of(ssh("Other", "other.example")), excluding: nil) {
            Issue.record("another host's budget counted the first host's chat")
        }
        if case .granted = budget.admit(on: .local, excluding: nil) {
            Issue.record("the local budget ignored its chat")
        }
        #expect(budget.liveCount(on: ControlMasterKey.of(sameMaster)) == 1)
        #expect(budget.limit(for: .local) == 1)
        #expect(local.holdsProcess)
        #expect(LiveChatBudget().limit(for: ControlMasterKey.of(sameMaster)) == 4)
        #expect(LiveChatBudget().limit(for: .local) == 8)
    }

    // MARK: - Every slot working

    /// Budget 2 and both chats working: a new open asks instead of
    /// spawning, and focus stays put. Stop on one of them cancels its turn
    /// (`session/cancel`), closes its channel, keeps it as a released chat,
    /// and then the open goes ahead.
    @Test @MainActor func allWorkingAsksAndStopReleasesOneThenOpens() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context, liveChatBudget: LiveChatBudget(localLimit: 2))
        let chA = Scripted(behavior: .happy(sessionId: "sess-A"))
        let chB = Scripted(behavior: .happy(sessionId: "sess-B"))
        let chC = Scripted(behavior: .answeringPrompts(sessionId: "sess-C"))
        let calls = Registry.install([chA, chB, chC], on: vm)

        #expect(await Self.startWorking(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Self.startWorking(vm, chB, "sess-B"))
        let chatB = vm.focusedChat

        vm.startNewSession()
        let block = try #require(vm.budgetBlocked, "a full budget of working chats didn't ask")
        #expect(Set(block.working.map(\.id)) == [chatA.id, chatB.id])
        #expect(block.working.first { $0.id == chatA.id }?.title == "work")
        #expect(vm.focusedChat === chatB, "a blocked open moved focus")
        #expect(vm.chats.count == 2)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(calls.count == 2, "a blocked open spawned a process")

        vm.stopChatForBudget(block, chatID: chatA.id)
        #expect(vm.budgetBlocked == nil)
        #expect(await Lifecycle.waitUntil { await chA.sentMethods.contains("session/cancel") },
                "Stop didn't cancel the turn")
        #expect(await Lifecycle.waitUntil { await chA.closed }, "Stop didn't close the chat's channel")
        #expect(chatA.isReleased)
        #expect(vm.chats.contains { $0 === chatA })
        #expect(await Registry.readyOn(vm, "sess-C"), "the open didn't go ahead after Stop")
        #expect(calls.count == 3)
        #expect(await chB.closed == false)
        #expect(chatB.hasTurnInFlight)
        vm.leaveChat()
    }

    /// Wait drops the open: nothing spawns, nothing moves.
    @Test @MainActor func waitDropsTheBlockedOpen() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context, liveChatBudget: LiveChatBudget(localLimit: 1))
        let chA = Scripted(behavior: .happy(sessionId: "sess-A"))
        let calls = Registry.install([chA], on: vm)

        #expect(await Self.startWorking(vm, chA, "sess-A"))
        let chatA = vm.focusedChat

        vm.resumeSession("sess-other")
        #expect(vm.budgetBlocked != nil)
        vm.waitForBudget()
        #expect(vm.budgetBlocked == nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(calls.count == 1, "Wait still opened the chat")
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.count == 1)
        #expect(await chA.closed == false)
        #expect(chatA.hasTurnInFlight)
    }

    // MARK: - Re-attach

    /// Focusing a released chat re-attaches it through `session/load` (not
    /// `session/new`, no prompt of its own); the load's replay doesn't paint
    /// as new content; a send typed during the reload is held and goes out
    /// once, after it; and the re-attach takes a slot like any open — here
    /// it releases the next least recently used idle chat.
    @Test @MainActor func aReleasedChatReattachesThroughLoadAndHoldsSends() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context, liveChatBudget: LiveChatBudget(localLimit: 2))
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .answeringPrompts(sessionId: "sess-B"))
        let chC = Scripted(behavior: .answeringPrompts(sessionId: "sess-C"))
        let reattach = Gated()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            switch calls.next() {
            case 1: return ACPClient(context: ctx) { _ in chA }
            case 2: return ACPClient(context: ctx) { _ in chB }
            case 3: return ACPClient(context: ctx) { _ in chC }
            case 4: return ACPClient(context: ctx) { _ in reattach }
            default: return ACPClient(context: ctx) { _ in Scripted(behavior: .happy(sessionId: "sess-extra")) }
            }
        }

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Registry.startWithATurn(vm, chB, "sess-B"))
        let chatB = vm.focusedChat
        #expect(await Registry.startWithATurn(vm, chC, "sess-C"))
        #expect(await Lifecycle.waitUntil { await chA.closed })
        #expect(chatA.isReleased)
        let messagesBefore = chatA.richChatViewModel.messages.count

        vm.resumeSession("sess-A") // its row: a focus, which re-attaches
        #expect(vm.focusedChat === chatA, "the released chat was opened again instead of focused")
        #expect(await Lifecycle.waitUntil { await reattach.hasPendingLoad }, "the re-attach never loaded its session")
        #expect(calls.count == 4)
        #expect(!chatA.isReleased)
        #expect(await reattach.sentMethods.contains("session/new") == false)

        vm.sendText("typed during reload")
        #expect(Self.userTexts(chatA) == ["hello", "typed during reload"])
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await reattach.sentMethods.contains("session/prompt") == false,
                "a send went out before the re-attach was ready")
        #expect(calls.count == 4, "a send during the re-attach spawned another process")

        await reattach.releaseLoad()
        #expect(await Lifecycle.waitUntil { await reattach.promptTexts == ["typed during reload"] },
                "the held send never went out")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await reattach.promptTexts == ["typed during reload"], "the held send went out twice")
        let leaked = chatA.richChatViewModel.messages.filter {
            $0.content.contains("REPLAYED")
                || ($0.reasoning ?? "").contains("REPLAYED")
                || $0.toolCalls.contains { $0.callId == "replayed-tool-1" }
        }
        #expect(leaked.isEmpty, "the load's replay painted as new content")
        #expect(chatA.richChatViewModel.messages.count >= messagesBefore)
        #expect(Self.userTexts(chatA) == ["hello", "typed during reload"])

        // It took a slot: the least recently used idle chat gave one up.
        #expect(await Lifecycle.waitUntil { await chB.closed }, "the re-attach didn't count against the budget")
        #expect(chatB.isReleased)
        #expect(await chC.closed == false)
        vm.leaveChat()
    }

    /// A re-attach with nothing typed: the chat's earlier turn left the
    /// replay gate open, and the load's replay must still not paint.
    @Test @MainActor func aReattachDropsTheLoadReplayWithNothingTyped() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context, liveChatBudget: LiveChatBudget())
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let reattach = Gated()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let n = calls.next()
            if n == 1 { return ACPClient(context: ctx) { _ in chA } }
            return ACPClient(context: ctx) { _ in reattach }
        }
        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chat = vm.focusedChat
        chat.releaseProcess()

        vm.focus(chat)
        #expect(await Lifecycle.waitUntil { await reattach.hasPendingLoad })
        await reattach.releaseLoad()
        #expect(await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.isACPConnected && !chat.isReattaching
        })
        try? await Task.sleep(nanoseconds: 300_000_000)
        let leaked = chat.richChatViewModel.messages.filter {
            $0.content.contains("REPLAYED")
                || ($0.reasoning ?? "").contains("REPLAYED")
                || $0.toolCalls.contains { $0.callId == "replayed-tool-1" }
        }
        #expect(leaked.isEmpty, "the re-attach's load replay painted as new content")
        #expect(await reattach.sentMethods.contains("session/prompt") == false)
        #expect(Self.userTexts(chat) == ["hello"])
        vm.leaveChat()
    }

    /// Leaving a released chat while it re-attaches puts it back to
    /// released (it has a row), rather than dropping it as an empty start.
    @Test @MainActor func leavingAReattachingChatReleasesItAgain() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context, liveChatBudget: LiveChatBudget(localLimit: 8))
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .answeringPrompts(sessionId: "sess-B"))
        let reattach = Gated()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            switch calls.next() {
            case 1: return ACPClient(context: ctx) { _ in chA }
            case 2: return ACPClient(context: ctx) { _ in chB }
            default: return ACPClient(context: ctx) { _ in reattach }
            }
        }
        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Registry.startWithATurn(vm, chB, "sess-B"))
        let chatB = vm.focusedChat
        chatA.releaseProcess()
        #expect(chatA.isReleased)

        vm.focus(chatA)
        #expect(await Lifecycle.waitUntil { await reattach.hasPendingLoad })
        vm.focus(chatB)
        #expect(vm.chats.contains { $0 === chatA }, "a re-attaching chat left mid-load was dropped")
        #expect(chatA.isReleased)
        #expect(await Lifecycle.waitUntil { await reattach.closed }, "the abandoned re-attach leaked its process")
        #expect(Self.userTexts(chatA) == ["hello"])
    }

    // MARK: - Stop on a chat still starting

    /// Stop on a new chat whose start (with a kickoff prompt, so it was
    /// kept) hasn't made a session yet: there is nothing to re-attach, so
    /// it is superseded — not left as a released chat no click can revive.
    @Test @MainActor func stopOnAStartingNewChatDropsIt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context, liveChatBudget: LiveChatBudget(localLimit: 1))
        let wedged = Scripted(behavior: .happy(sessionId: "sess-K"))
        let next = Scripted(behavior: .answeringPrompts(sessionId: "sess-N"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 {
                return ACPClient(context: ctx) { _ in
                    for await _ in gate { break }
                    return wedged
                }
            }
            return ACPClient(context: ctx) { _ in next }
        }
        vm.startNewSession(projectPath: nil, initialPrompt: "kick it off")
        let starting = vm.focusedChat
        #expect(await Lifecycle.waitUntil { calls.count == 1 })

        vm.startNewSession()
        let block = try #require(vm.budgetBlocked)
        #expect(block.working.map(\.id) == [starting.id])
        vm.stopChatForBudget(block, chatID: starting.id)

        #expect(await Registry.readyOn(vm, "sess-N"), "the open didn't go ahead after Stop")
        #expect(!vm.chats.contains { $0.isReleased }, "a session-less chat was kept as released")
        #expect(vm.chats.count == 1)
        gateCont.yield(())
        gateCont.finish()
        #expect(await Lifecycle.waitUntil { await wedged.closed }, "the stopped start's process leaked")
        #expect(await wedged.sentMethods.contains("session/new") == false)
    }

    /// Stop on a chat whose resume was still loading (from another window's
    /// dialog): it is released on the session it was resuming, so clicking
    /// its row re-attaches that session, and a message typed meanwhile is
    /// sent once.
    @Test @MainActor func stopOnAStartingResumeReattachesThatSession() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 1)
        let w1 = ChatViewModel(context: home.context, liveChatBudget: budget)
        let w2 = ChatViewModel(context: home.context, liveChatBudget: budget)
        let loading = Gated()
        let reattach = Gated()
        let calls = Lifecycle.CallCounter()
        w1.acpClientFactory = { ctx, _ in
            let n = calls.next()
            return ACPClient(context: ctx) { _ in n == 1 ? loading : reattach }
        }
        let chOther = Scripted(behavior: .answeringPrompts(sessionId: "sess-O"))
        _ = Registry.install([chOther], on: w2)

        w1.resumeSession("sess-R")
        let resuming = w1.focusedChat
        #expect(await Lifecycle.waitUntil { await loading.hasPendingLoad })

        w2.startNewSession()
        let block = try #require(w2.budgetBlocked, "a shown, loading chat didn't block the open")
        w2.stopChatForBudget(block, chatID: resuming.id)
        #expect(await Lifecycle.waitUntil { await loading.closed })
        #expect(resuming.isReleased)
        #expect(await Registry.readyOn(w2, "sess-O"))
        w2.leaveChat() // frees the one slot

        w1.resumeSession("sess-R") // the row: focuses it, which re-attaches
        #expect(w1.focusedChat === resuming, "the stopped resume was opened twice")
        #expect(w1.chats.count == 1)
        #expect(await Lifecycle.waitUntil { await reattach.hasPendingLoad }, "focusing it didn't re-attach")
        w1.sendText("typed while reattaching")
        await reattach.releaseLoad()
        #expect(await Lifecycle.waitUntil { await reattach.promptTexts == ["typed while reattaching"] },
                "the send typed into it never went out")
        #expect(w1.richChatViewModel.sessionId == "sess-R")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await reattach.promptTexts == ["typed while reattaching"], "the send went out twice")
        #expect(await reattach.sentMethods.contains("session/new") == false)
        w1.leaveChat()
    }

    // MARK: - Remembered approval mode

    @MainActor
    static func modeVM(_ home: TempHermesHome, suite: String) async throws -> ChatViewModel {
        let vm = ChatViewModel(context: home.context, liveChatBudget: LiveChatBudget())
        vm.capabilitiesStore = try await ChatViewModelAutoAcceptEditsTests.capabilities(
            "0.15.0", context: home.context, suite: suite)
        return vm
    }

    /// Pick accept_edits in a chat and wait until Hermes took it.
    @MainActor
    static func pickAcceptEdits(_ vm: ChatViewModel, on channel: ModeChannel) async -> Bool {
        vm.switchApprovalMode(.acceptEdits)
        return await Lifecycle.waitUntil {
            await channel.modeIds == ["accept_edits"] && vm.focusedChat.userPickedApprovalMode == .acceptEdits
        }
    }

    /// Legacy Hermes forgets the picked mode with the process: a re-attach
    /// loads the session back at `default`, and the chat re-sends what the
    /// user picked.
    @Test @MainActor func aPickedModeIsResentAfterReattach() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let suite = "p1-mode-\(UUID().uuidString)"
        let vm = try await Self.modeVM(home, suite: suite)
        defer { vm.leaveChat() }
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "default")
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let ch = calls.next() == 1 ? first : second
            return ACPClient(context: ctx) { _ in ch }
        }
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        #expect(await Self.pickAcceptEdits(vm, on: first))
        let chat = vm.focusedChat

        // Let the release finish (cancel, client stop) before re-attaching.
        await chat.releaseProcess()?.value
        vm.focus(chat) // shown and released: re-attaches
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 15) { await second.modeIds == ["accept_edits"] },
                "the picked mode was not re-sent after the re-attach")
        #expect(await second.sentMethods.contains("session/load"))
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 15) {
            vm.richChatViewModel.activeApprovalMode == .acceptEdits
        })
    }

    /// The session came back in the picked mode already: nothing to send.
    @Test @MainActor func aPickedModeIsNotResentWhenTheSessionKeptIt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = try await Self.modeVM(home, suite: "p1-mode-\(UUID().uuidString)")
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "accept_edits")
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let ch = calls.next() == 1 ? first : second
            return ACPClient(context: ctx) { _ in ch }
        }
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        #expect(await Self.pickAcceptEdits(vm, on: first))
        let chat = vm.focusedChat

        chat.releaseProcess()
        vm.focus(chat)
        #expect(await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.isACPConnected
        })
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await second.sentMethods.contains("session/load"))
        #expect(await second.modeIds.isEmpty, "a mode the session already had was sent again")
        #expect(vm.richChatViewModel.activeApprovalMode == .acceptEdits)
    }

    /// Behaviour change: the reconnect ladder re-sends the picked mode too
    /// (before P1 a reconnect came back at `default`).
    @Test @MainActor func aPickedModeIsResentAfterAReconnect() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = try await Self.modeVM(home, suite: "p1-mode-\(UUID().uuidString)")
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "default")
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let ch = calls.next() == 1 ? first : second
            return ACPClient(context: ctx) { _ in ch }
        }
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        #expect(await Self.pickAcceptEdits(vm, on: first))

        await first.close() // the process dies: the ladder reloads
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { await second.sentMethods.contains("session/load") })
        #expect(await Lifecycle.waitUntil { await second.modeIds == ["accept_edits"] },
                "the reconnect didn't re-send the picked mode")
        #expect(await Lifecycle.waitUntil { vm.richChatViewModel.activeApprovalMode == .acceptEdits })
        vm.stopACP()
    }

    /// The error banner's Reconnect restarts the chat in place on the same
    /// session: the mode picked in it survives the reset and is re-sent.
    @Test @MainActor func aPickedModeSurvivesTheReconnectButton() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = try await Self.modeVM(home, suite: "p1-mode-\(UUID().uuidString)")
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: "default")
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let ch = calls.next() == 1 ? first : second
            return ACPClient(context: ctx) { _ in ch }
        }
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        #expect(await Self.pickAcceptEdits(vm, on: first))

        vm.resumeSession("sess-A", origin: .errorRetry)
        #expect(await Lifecycle.waitUntil { await second.sentMethods.contains("session/load") })
        #expect(await Lifecycle.waitUntil { await second.modeIds == ["accept_edits"] },
                "Reconnect forgot the mode picked in this chat")
        #expect(await Lifecycle.waitUntil { vm.richChatViewModel.activeApprovalMode == .acceptEdits })
        vm.stopACP()
    }

    /// A host that reports no mode on `session/load` leaves the chip on its
    /// old value — which says nothing about the fresh session. The picked
    /// mode is sent.
    @Test @MainActor func aPickedModeIsResentWhenTheLoadReportsNoMode() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = try await Self.modeVM(home, suite: "p1-mode-\(UUID().uuidString)")
        let first = ModeChannel(sessionId: "sess-A")
        let second = ModeChannel(sessionId: "sess-A", loadMode: nil)
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let ch = calls.next() == 1 ? first : second
            return ACPClient(context: ctx) { _ in ch }
        }
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        #expect(await Self.pickAcceptEdits(vm, on: first))
        let chat = vm.focusedChat

        chat.releaseProcess()
        vm.focus(chat)
        #expect(await Lifecycle.waitUntil { await second.modeIds == ["accept_edits"] },
                "an unreported mode was taken for the picked one")
        vm.stopACP()
    }

    // MARK: - SSHMasterRecovery

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    static let box = ControlMasterKey.ssh(user: "alan", host: "box.example", port: 22)

    /// Two chats failing at once run ONE probe (one `-O exit`), and both
    /// get its outcome.
    @Test @MainActor func concurrentRecoveriesRunOneProbe() async {
        let clock = Clock()
        let recovery = SSHMasterRecovery(now: { clock.now })
        let probes = ProbeCounter()
        let probe: @Sendable () -> SSHMasterRecovery.Outcome = {
            probes.hit()
            Thread.sleep(forTimeInterval: 0.3) // a slow `-O check` + probe
            return .recovered
        }
        async let first = recovery.recover(key: Self.box, probe: probe)
        async let second = recovery.recover(key: Self.box, probe: probe)
        let results = await [first, second]
        #expect(results.map(\.outcome) == [.recovered, .recovered])
        #expect(probes.count == 1, "two concurrent recoveries probed (and -O exit-ed) twice")
        // Exactly one caller ran it; the other must not treat it as fresh
        // (the wake sweep skips its verify then).
        #expect(results.filter(\.probedHere).count == 1)
    }

    /// Within the cooldown a finished recovery's outcome stands; after it,
    /// a new probe runs. Another master is never coalesced with this one.
    @Test @MainActor func theCooldownReusesTheOutcomeThenProbesAgain() async {
        let clock = Clock()
        let recovery = SSHMasterRecovery(cooldown: 5, now: { clock.now })
        let probes = ProbeCounter()
        let probe: @Sendable () -> SSHMasterRecovery.Outcome = { probes.hit(); return .alive }

        #expect(await recovery.recover(key: Self.box, probe: probe) == .init(outcome: .alive, probedHere: true))
        clock.advance(4)
        #expect(await recovery.recover(key: Self.box, probe: probe) == .init(outcome: .alive, probedHere: false))
        #expect(probes.count == 1, "a recovery inside the cooldown probed again")

        let other = ControlMasterKey.ssh(user: "alan", host: "other.example", port: 22)
        _ = await recovery.recover(key: other, probe: probe)
        #expect(probes.count == 2, "another master shared this one's outcome")

        clock.advance(2)
        _ = await recovery.recover(key: Self.box, probe: probe)
        #expect(probes.count == 3, "no new probe after the cooldown")
    }

    /// After a recovery that left no master, the first chat to reconnect
    /// leads and the next waits for the leader's start; a healthy master
    /// opens no wave.
    @Test @MainActor func followersWaitForTheLeader() async {
        let recovery = SSHMasterRecovery(followerWait: 10)
        _ = await recovery.recover(key: Self.box) { .alive }
        #expect(await recovery.reconnectTurn(for: Self.box) == .free, "a healthy master staggered reconnects")

        let other = ControlMasterKey.ssh(user: "alan", host: "other.example", port: 22)
        _ = await recovery.recover(key: other) { .recovered }
        guard case .leader(let waveId) = await recovery.reconnectTurn(for: other) else {
            Issue.record("the first reconnect after a recovery didn't lead")
            return
        }

        let started = Date()
        let follower = Task { @MainActor in await recovery.reconnectTurn(for: other) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        recovery.leaderStarted(for: other, waveId: waveId)
        #expect(await follower.value == .follower)
        let waited = Date().timeIntervalSince(started)
        #expect(waited >= 0.25, "the follower didn't wait for the leader")
        #expect(waited < 5, "the follower waited out its timeout instead of the leader")
        // The wave is over: the next reconnect goes at once.
        #expect(await recovery.reconnectTurn(for: other) == .free)
    }

    /// A leader that never reports holds nobody past the follower timeout.
    @Test @MainActor func aSilentLeaderReleasesFollowersAfterTheTimeout() async {
        let recovery = SSHMasterRecovery(followerWait: 0.2)
        recovery.openReconnectWave(for: Self.box)
        #expect(await recovery.reconnectTurn(for: Self.box).isLeader)
        let started = Date()
        #expect(await recovery.reconnectTurn(for: Self.box) == .follower)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    /// A follower parked when the wave expires still gets its turn — the
    /// expiry releases it, not only its own (long) timer.
    @Test @MainActor func aFollowerParkedWhenTheWaveExpiresReturns() async {
        let clock = Clock()
        let recovery = SSHMasterRecovery(followerWait: 60, waveLifetime: 30, now: { clock.now })
        recovery.openReconnectWave(for: Self.box)
        #expect(await recovery.reconnectTurn(for: Self.box).isLeader)
        let follower = Task { @MainActor in await recovery.reconnectTurn(for: Self.box) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        clock.advance(31)
        #expect(await recovery.reconnectTurn(for: Self.box) == .free)
        let done = ProbeCounter()
        Task { @MainActor in _ = await follower.value; done.hit() }
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 2) { done.count == 1 },
                "a follower parked on an expired wave never returned")
    }

    /// A ladder torn down while it waits (Stop, leaving) is not left parked.
    @Test @MainActor func aCancelledFollowerReturns() async {
        let recovery = SSHMasterRecovery(followerWait: 60)
        recovery.openReconnectWave(for: Self.box)
        #expect(await recovery.reconnectTurn(for: Self.box).isLeader)
        let follower = Task { @MainActor in await recovery.reconnectTurn(for: Self.box) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        follower.cancel()
        let done = ProbeCounter()
        Task { @MainActor in _ = await follower.value; done.hit() }
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 2) { done.count == 1 },
                "a cancelled follower stayed parked")
    }

    /// A leader of an older wave reporting late doesn't close the wave a
    /// newer recovery opened: that wave's follower keeps waiting for its
    /// own leader.
    @Test @MainActor func aStaleLeaderDoesNotCloseANewerWave() async {
        let recovery = SSHMasterRecovery(followerWait: 60)
        recovery.openReconnectWave(for: Self.box)
        guard case .leader(let oldWave) = await recovery.reconnectTurn(for: Self.box) else {
            Issue.record("no leader"); return
        }
        recovery.openReconnectWave(for: Self.box) // a newer recovery
        guard case .leader(let newWave) = await recovery.reconnectTurn(for: Self.box) else {
            Issue.record("no leader for the newer wave"); return
        }
        let done = ProbeCounter()
        let follower = Task { @MainActor in _ = await recovery.reconnectTurn(for: Self.box); done.hit() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        recovery.leaderStarted(for: Self.box, waveId: oldWave)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(done.count == 0, "the stale leader released the newer wave's follower")

        recovery.leaderStarted(for: Self.box, waveId: newWave)
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 2) { done.count == 1 })
        _ = await follower.value
    }

    /// In the reconnect ladder: two chats whose connections died after a
    /// recovery reconnect one at a time — the second spawns only once the
    /// first's `hermes acp` has started.
    @Test @MainActor func theReconnectLadderStaggersBehindTheLeader() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let recovery = SSHMasterRecovery(followerWait: 10)
        let vm = ChatViewModel(context: home.context, liveChatBudget: LiveChatBudget(), masterRecovery: recovery)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .answeringPrompts(sessionId: "sess-B"))
        let leaderChannel = Scripted(behavior: .happy(sessionId: "sess-A"))
        let followerChannel = Scripted(behavior: .happy(sessionId: "sess-B"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            switch calls.next() {
            case 1: return ACPClient(context: ctx) { _ in chA }
            case 2: return ACPClient(context: ctx) { _ in chB }
            case 3:
                return ACPClient(context: ctx) { _ in
                    for await _ in gate { break } // the leader's ssh handshake
                    return leaderChannel
                }
            default: return ACPClient(context: ctx) { _ in followerChannel }
            }
        }
        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        #expect(await Registry.startWithATurn(vm, chB, "sess-B"))

        // A recovery just left the host without a master (`.local` has no
        // probe of its own, so the wave is opened directly).
        recovery.openReconnectWave(for: .local)
        await chA.close()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { calls.count == 3 }, "the leader never reconnected")
        await chB.close()
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(calls.count == 3, "a follower spawned while the leader was still starting")

        gateCont.yield(())
        gateCont.finish()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { calls.count == 4 },
                "the follower never reconnected after the leader started")
        #expect(await Lifecycle.waitUntil { await followerChannel.sentMethods.contains("session/load") })
        vm.leaveChat()
    }

    // MARK: - Bot Chat

    /// `.single` (Bot Chat) stays outside the budget: a limit of one never
    /// blocks it, and its chat never counts.
    @Test @MainActor func singleModeIgnoresTheBudget() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 1)
        let other = ChatViewModel(context: home.context, liveChatBudget: budget)
        let chW = Scripted(behavior: .happy(sessionId: "sess-W"))
        _ = Registry.install([chW], on: other)
        #expect(await Self.startWorking(other, chW, "sess-W"))

        let bot = ChatViewModel(context: home.context, mode: .single, liveChatBudget: budget)
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .answeringPrompts(sessionId: "sess-B"))
        let calls = Registry.install([chA, chB], on: bot)
        bot.startNewSession()
        #expect(await Registry.readyOn(bot, "sess-A"))
        bot.resumeSession("sess-B")
        #expect(await Registry.readyOn(bot, "sess-B"))
        #expect(bot.budgetBlocked == nil)
        #expect(calls.count == 2)
        #expect(bot.chats.count == 1)
        #expect(budget.liveCount(on: .local) == 1, "Bot Chat's chat counted against the budget")
        #expect(await chW.closed == false)
        other.leaveChat()
    }
}
