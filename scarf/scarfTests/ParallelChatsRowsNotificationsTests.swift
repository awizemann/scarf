import Testing
import Foundation
import ScarfCore
import UserNotifications
@testable import scarf

/// Parallel chats P1, step 3: each live chat's row state, per-chat drafts,
/// approvals raised in a background chat, the chat notifications (post
/// decision, needs-answer, withdrawal) and routing a notification click to
/// the right window and chat. Plus two budget-dialog fixes: a Stop is never
/// also read as a Wait, and Stop on a typed autostart keeps the message.
///
/// ACP is scripted through the `acpClientFactory` seam; notifications go to
/// a recorder (`RecordingNotifier`), never the real notification center.
@Suite struct ParallelChatsRowsNotificationsTests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias Registry = ParallelChatsRegistryTests
    typealias Scripted = ChatViewModelStartLifecycleTests.ScriptedACPChannel

    // MARK: - Test doubles

    @MainActor
    final class RecordingNotifier: ChatNotificationPosting {
        private(set) var posted: [ChatNotification] = []
        private(set) var removed: [String] = []
        func post(_ notification: ChatNotification) { posted.append(notification) }
        func remove(identifiers: [String]) { removed += identifiers }
    }

    /// Answers `initialize`, `session/new` and `session/load` with
    /// `sessionId`; holds every `session/prompt` until the test completes or
    /// fails it; and can raise agent-side events (a reply chunk, a
    /// permission request, a tool call closing).
    actor ControlledChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        let sessionId: String
        private var heldPrompts: [Int] = []
        private(set) var closed = false
        private(set) var sentMethods: [String] = []
        private(set) var promptTexts: [String] = []
        var diagnosticID: String? { "controlled-channel" }

        init(sessionId: String) {
            self.sessionId = sessionId
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = inStream
            incomingCont = inCont
            stderr = errStream
            stderrCont = errCont
        }

        var hasHeldPrompt: Bool { !heldPrompts.isEmpty }

        func send(_ line: String) async throws {
            if closed { throw ACPChannelError.writeEndClosed }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String
            else { return }
            sentMethods.append(method)
            if method == "session/prompt",
               let prompt = (obj["params"] as? [String: Any])?["prompt"] as? [[String: Any]] {
                promptTexts.append(prompt.compactMap { $0["text"] as? String }.joined())
            }
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/new", "session/load":
                reply(["jsonrpc": "2.0", "id": id,
                       "result": ["sessionId": sessionId, "modes": ["currentModeId": "default"]]])
            case "session/prompt":
                heldPrompts.append(id)
            default:
                reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        func completePrompts() {
            for id in heldPrompts {
                reply(["jsonrpc": "2.0", "id": id, "result": ["stopReason": "end_turn"]])
            }
            heldPrompts = []
        }

        func failPrompts() {
            for id in heldPrompts {
                reply(["jsonrpc": "2.0", "id": id,
                       "error": ["code": -32603, "message": "scripted prompt failure"]])
            }
            heldPrompts = []
        }

        /// Fail held prompts as gateway-backed ACP does: `-32603` with the
        /// real text in `error.data.details`.
        func failPrompts(details: String) {
            for id in heldPrompts {
                reply(["jsonrpc": "2.0", "id": id,
                       "error": ["code": -32603, "message": "Internal error",
                                 "data": ["details": details]] as [String: Any]])
            }
            heldPrompts = []
        }

        func emitReply(_ text: String) {
            reply(["jsonrpc": "2.0", "method": "session/update",
                   "params": ["sessionId": sessionId,
                              "update": ["sessionUpdate": "agent_message_chunk",
                                         "content": ["type": "text", "text": text]] as [String: Any]
                             ] as [String: Any]])
        }

        func emitPermissionRequest(requestId: Int, title: String, toolCallId: String) {
            reply(["jsonrpc": "2.0", "id": requestId, "method": "session/request_permission",
                   "params": ["sessionId": sessionId,
                              "toolCall": ["toolCallId": toolCallId, "title": title, "kind": "execute"],
                              "options": [["optionId": "allow_once", "name": "Allow", "kind": "allow_once"],
                                          ["optionId": "deny", "name": "Deny", "kind": "reject_once"]]
                             ] as [String: Any]])
        }

        /// Hermes closing a permission request's tool call itself (it
        /// stopped waiting, acp_adapter/permissions.py:94-113 @ v2026.9.24).
        func emitToolCallClosed(toolCallId: String, status: String) {
            reply(["jsonrpc": "2.0", "method": "session/update",
                   "params": ["sessionId": sessionId,
                              "update": ["sessionUpdate": "tool_call_update",
                                         "toolCallId": toolCallId, "status": status] as [String: Any]
                             ] as [String: Any]])
        }

        func close() async {
            guard !closed else { return }
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }

        private func reply(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }
    }

    // MARK: - Helpers

    /// A window VM with its own budget and a recorder, in the state where
    /// the user is looking at its chat pane with Scarf frontmost.
    @MainActor
    static func makeVM(_ home: TempHermesHome, _ notifier: RecordingNotifier,
                       budget: LiveChatBudget? = nil,
                       mode: ChatViewModel.Mode = .window) -> ChatViewModel {
        let vm = ChatViewModel(context: home.context, mode: mode,
                               liveChatBudget: budget ?? LiveChatBudget(), notifier: notifier)
        vm.appIsActive = { true }
        vm.isChatPaneVisible = true
        vm.isWindowVisible = true
        return vm
    }

    /// One channel per spawn, in call order (a fresh scripted one past the end).
    @MainActor
    static func install(_ channels: [any ACPChannel], on vm: ChatViewModel) {
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let n = calls.next()
            let channel: any ACPChannel = n <= channels.count
                ? channels[n - 1]
                : Scripted(behavior: .happy(sessionId: "sess-extra-\(n)"))
            return ACPClient(context: ctx) { _ in channel }
        }
    }

    /// Start a chat on `channel` and send `text`: a turn held in flight.
    @MainActor
    static func startWorking(_ vm: ChatViewModel, _ channel: ControlledChannel, _ text: String) async -> Bool {
        vm.startNewSession()
        guard await Registry.readyOn(vm, channel.sessionId) else { return false }
        vm.sendText(text)
        return await Lifecycle.waitUntil { await channel.hasHeldPrompt }
    }

    // MARK: - Row state

    /// A reply finishing in a background chat: replying → finished
    /// (unread), with a "finished" notification named after THAT chat and
    /// routed to its session even though Scarf is frontmost; focusing it
    /// marks it read and withdraws the notification.
    @Test @MainActor func aBackgroundReplyFinishesUnreadAndFocusReadsIt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let notifier = RecordingNotifier()
        let vm = Self.makeVM(home, notifier)
        let chA = ControlledChannel(sessionId: "sess-A")
        let chB = ControlledChannel(sessionId: "sess-B")
        Self.install([chA, chB], on: vm)

        #expect(await Self.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(chatA.rowState == .replying)
        #expect(await Self.startWorking(vm, chB, "work in B"))
        let chatB = vm.focusedChat
        #expect(chatB !== chatA)
        #expect(chatA.rowState == .replying, "a background chat stopped reading as replying")

        await chA.emitReply("All done in A")
        #expect(await Lifecycle.waitUntil {
            chatA.richChatViewModel.messages.contains { $0.isAssistant && $0.content == "All done in A" }
        })
        await chA.completePrompts()
        #expect(await Lifecycle.waitUntil { chatA.rowState == .finishedUnread },
                "a reply finishing in the background didn't mark the chat unread")
        let note = try #require(notifier.posted.last)
        #expect(note.kind == .turnFinished)
        #expect(note.title == ChatNotificationPolicy.finishedTitle(chatName: "work in A"),
                "the notification wasn't named after the chat that finished")
        #expect(note.body == "All done in A")
        #expect(note.route == ChatNotificationRoute(serverID: home.context.id, hermesHome: home.context.paths.home, sessionId: "sess-A"))
        #expect(chatB.rowState == .replying)

        vm.resumeSession("sess-A") // its row: a focus
        #expect(vm.focusedChat === chatA)
        #expect(chatA.rowState == .idle, "focusing the chat didn't mark it read")
        #expect(notifier.removed.contains(note.identifier), "the read reply's notification stayed")
        vm.leaveChat()
    }

    /// The reply finishing in the chat the user is looking at: no unread,
    /// no notification. Pane hidden (another section), or its window not
    /// in front: unread and notified; coming back reads it and withdraws
    /// the note.
    @Test @MainActor func aReplyInTheShownChatNotifiesOnlyWhenThePaneIsHidden() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let notifier = RecordingNotifier()
        let vm = Self.makeVM(home, notifier)
        let chA = ControlledChannel(sessionId: "sess-A")
        Self.install([chA], on: vm)

        #expect(await Self.startWorking(vm, chA, "first"))
        let chatA = vm.focusedChat
        await chA.completePrompts()
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        #expect(chatA.rowState == .idle)
        #expect(notifier.posted.isEmpty, "notified about the chat the user is looking at")

        vm.isChatPaneVisible = false
        vm.sendText("second")
        #expect(await Lifecycle.waitUntil { await chA.hasHeldPrompt })
        await chA.completePrompts()
        #expect(await Lifecycle.waitUntil { notifier.posted.count == 1 })
        #expect(chatA.rowState == .finishedUnread)
        vm.isChatPaneVisible = true
        vm.chatPaneVisibilityChanged()
        #expect(chatA.rowState == .idle, "coming back to the chat didn't read it")
        #expect(notifier.removed == notifier.posted.prefix(1).map(\.identifier))

        // The pane is up but its window is minimized / behind: the same.
        vm.isWindowVisible = false
        vm.sendText("third")
        #expect(await Lifecycle.waitUntil { await chA.hasHeldPrompt })
        await chA.completePrompts()
        #expect(await Lifecycle.waitUntil { notifier.posted.count == 2 },
                "a reply in a window that isn't in front wasn't notified")
        #expect(chatA.rowState == .finishedUnread)
        vm.isWindowVisible = true
        vm.chatPaneVisibilityChanged()
        #expect(chatA.rowState == .idle)
        vm.leaveChat()
    }

    /// A turn failing in a background chat shows as an error on its row.
    @Test @MainActor func aBackgroundFailureShowsAsAnError() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, RecordingNotifier())
        let chA = ControlledChannel(sessionId: "sess-A")
        let chB = ControlledChannel(sessionId: "sess-B")
        Self.install([chA, chB], on: vm)

        #expect(await Self.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(await Self.startWorking(vm, chB, "work in B"))
        await chA.failPrompts()
        #expect(await Lifecycle.waitUntil { chatA.rowState == .error },
                "a background turn's failure didn't show on its row")
        #expect(vm.focusedChat.rowState == .replying)
        vm.leaveChat()
    }

    // MARK: - Background approvals

    /// A permission request in a background chat: the row needs an answer,
    /// a "needs your answer" notification goes out (identifier
    /// server/session/perm/<id>), and the sheet stays with the focused chat
    /// until the user focuses that one. Answering it withdraws the
    /// notification.
    @Test @MainActor func aBackgroundApprovalNeedsAnAnswerAndAnsweringWithdrawsIt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let notifier = RecordingNotifier()
        let vm = Self.makeVM(home, notifier)
        let chA = ControlledChannel(sessionId: "sess-A")
        let chB = ControlledChannel(sessionId: "sess-B")
        Self.install([chA, chB], on: vm)

        #expect(await Self.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(await Self.startWorking(vm, chB, "work in B"))

        await chA.emitPermissionRequest(requestId: 0, title: "curl -H 'Authorization: Bearer s3cret' x", toolCallId: "perm-check-1")
        #expect(await Lifecycle.waitUntil { chatA.rowState == .needsAnswer })
        #expect(vm.presentedPermission == nil, "the focused chat showed a background chat's approval")
        let note = try #require(notifier.posted.last)
        let expectedId = "\(home.context.id.uuidString)/sess-A/\(chatA.id.uuidString)/perm/0"
        #expect(note.kind == .needsAnswer)
        #expect(note.identifier == expectedId)
        #expect(note.title == ChatNotificationPolicy.needsAnswerTitle(chatName: "work in A"))
        // The kind, never the command: the title can hold a secret.
        #expect(note.body == ChatNotificationPolicy.needsAnswerBody(kind: "execute", prompt: .toolApproval))
        #expect(!note.body.contains("s3cret"), "the tool title reached the notification")
        #expect(note.route?.sessionId == "sess-A")

        vm.resumeSession("sess-A")
        let presented = try #require(vm.presentedPermission, "focusing the chat didn't bring its approval up")
        #expect(presented.chat === chatA)
        #expect(presented.permission.title.contains("s3cret"), "the card lost the detail")
        #expect(notifier.removed.contains(expectedId) == false, "focusing withdrew an unanswered approval")
        presented.chat.respondToPermission(requestId: presented.permission.requestId, optionId: "allow_once")
        #expect(notifier.removed.contains(expectedId), "answering didn't withdraw its notification")
        #expect(chatA.rowState == .replying)
        vm.leaveChat()
    }

    /// Hermes settling a background approval itself (it stopped waiting)
    /// withdraws the notification too.
    @Test @MainActor func hermesSettlingABackgroundApprovalWithdrawsItsNotification() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let notifier = RecordingNotifier()
        let vm = Self.makeVM(home, notifier)
        let chA = ControlledChannel(sessionId: "sess-A")
        let chB = ControlledChannel(sessionId: "sess-B")
        Self.install([chA, chB], on: vm)

        #expect(await Self.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(await Self.startWorking(vm, chB, "work in B"))
        await chA.emitPermissionRequest(requestId: 7, title: "deploy", toolCallId: "perm-check-7")
        #expect(await Lifecycle.waitUntil { chatA.rowState == .needsAnswer })
        let identifier = try #require(notifier.posted.last?.identifier)

        await chA.emitToolCallClosed(toolCallId: "perm-check-7", status: "failed")
        #expect(await Lifecycle.waitUntil { notifier.removed.contains(identifier) },
                "Hermes settled the approval but its notification stayed")
        #expect(chatA.rowState == .replying)
        vm.leaveChat()
    }

    /// JSON-RPC ids restart with each `hermes acp` process: two chats can
    /// each raise request 0. The sheet's identity includes the chat, so the
    /// two cards are different sheets.
    @Test @MainActor func thePermissionSheetIdentityIncludesTheChat() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, RecordingNotifier())
        let chA = ControlledChannel(sessionId: "sess-A")
        let chB = ControlledChannel(sessionId: "sess-B")
        Self.install([chA, chB], on: vm)

        #expect(await Self.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(await Self.startWorking(vm, chB, "work in B"))
        let chatB = vm.focusedChat
        await chA.emitPermissionRequest(requestId: 0, title: "a", toolCallId: "perm-a")
        await chB.emitPermissionRequest(requestId: 0, title: "b", toolCallId: "perm-b")
        #expect(await Lifecycle.waitUntil { vm.presentedPermission != nil && chatA.rowState == .needsAnswer })

        let onB = try #require(vm.presentedPermission)
        vm.resumeSession("sess-A")
        let onA = try #require(vm.presentedPermission)
        #expect(onB.permission.requestId == onA.permission.requestId)
        #expect(onB.chat === chatB && onA.chat === chatA)
        #expect(onB.id != onA.id, "two chats' request 0 shared one sheet identity")
        vm.leaveChat()
    }

    // MARK: - Drafts

    /// A draft stays with its chat: typed in A, focus B (its own empty
    /// composer), back to A — still there.
    @Test @MainActor func aDraftSurvivesAFocusRoundTrip() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, RecordingNotifier())
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .answeringPrompts(sessionId: "sess-B"))
        _ = Registry.install([chA, chB], on: vm)

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        chatA.composer.text = "half a thought"
        #expect(await Registry.startWithATurn(vm, chB, "sess-B"))
        #expect(vm.focusedChat.composer.text.isEmpty, "the new chat inherited A's draft")
        vm.resumeSession("sess-A")
        #expect(vm.focusedChat === chatA)
        #expect(chatA.composer.text == "half a thought")
        vm.leaveChat()
    }

    /// A chat reused in place for another session starts with an empty
    /// composer (#62); Reconnect on the same session keeps the draft.
    @Test @MainActor func aChatReusedForAnotherSessionDropsItsDraft() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, RecordingNotifier())
        let chA = Scripted(behavior: .happy(sessionId: "sess-A"))
        let chB = Scripted(behavior: .happy(sessionId: "sess-A"))
        let chC = Scripted(behavior: .happy(sessionId: "sess-C"))
        _ = Registry.install([chA, chB, chC], on: vm)

        vm.resumeSession("sess-A")
        #expect(await Registry.readyOn(vm, "sess-A"))
        let chat = vm.focusedChat
        chat.composer.text = "keep me"
        vm.resumeSession("sess-A", origin: .errorRetry) // Reconnect, in place
        #expect(await Registry.readyOn(vm, "sess-A"))
        #expect(chat.composer.text == "keep me", "Reconnect dropped the draft")

        // A resumed chat with no turn and nothing running isn't kept:
        // resuming another session reuses it.
        vm.stopACP()
        vm.resumeSession("sess-C")
        #expect(vm.focusedChat === chat)
        #expect(chat.composer.text.isEmpty, "a draft leaked into another session")
        vm.leaveChat()
    }

    /// A released chat keeps its draft; the released-chat cap forgets a
    /// chat with nothing to lose before an older one with a draft.
    @Test @MainActor func theReleasedCapSparesAChatWithADraft() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, RecordingNotifier(), budget: LiveChatBudget(localLimit: 1))
        vm.maxReleasedChats = 1
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .answeringPrompts(sessionId: "sess-B"))
        let chC = Scripted(behavior: .answeringPrompts(sessionId: "sess-C"))
        _ = Registry.install([chA, chB, chC], on: vm)

        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Registry.startWithATurn(vm, chB, "sess-B"))
        let chatB = vm.focusedChat
        #expect(chatA.isReleased)
        chatA.composer.text = "draft in A"

        #expect(await Registry.startWithATurn(vm, chC, "sess-C"))
        #expect(chatB.isReleased)
        // A is the least recently used, but it has a draft: B goes.
        #expect(vm.chats.contains { $0 === chatA }, "the cap forgot the chat with a draft")
        #expect(!vm.chats.contains { $0 === chatB })
        #expect(chatA.composer.text == "draft in A", "releasing the chat lost its draft")
        vm.leaveChat()
    }

    // MARK: - Notification decisions

    /// Post unless the user is looking at the chat: app active AND focused
    /// chat AND its pane on screen AND its window in front. Spelled out.
    @Test func thePostDecision() {
        // (app active, focused chat, pane visible, window visible) → post
        let table: [(Bool, Bool, Bool, Bool, Bool)] = [
            (true, true, true, true, false),
            (true, true, true, false, true),
            (true, true, false, true, true),
            (true, true, false, false, true),
            (true, false, true, true, true),
            (true, false, true, false, true),
            (true, false, false, true, true),
            (true, false, false, false, true),
            (false, true, true, true, true),
            (false, true, true, false, true),
            (false, true, false, true, true),
            (false, true, false, false, true),
            (false, false, true, true, true),
            (false, false, true, false, true),
            (false, false, false, true, true),
            (false, false, false, false, true),
        ]
        for (active, focused, pane, window, expected) in table {
            #expect(ChatNotificationPolicy.shouldPost(
                appIsActive: active, isFocusedChat: focused,
                isChatPaneVisible: pane, isWindowVisible: window) == expected,
                "active \(active), focused \(focused), pane \(pane), window \(window)")
        }
    }

    /// Bot Chat (`.single`) notifies with no route: a click only activates
    /// the app, never opens the bot's conversation in a main window.
    @Test @MainActor func botChatNotifiesWithNoRoute() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let notifier = RecordingNotifier()
        let vm = Self.makeVM(home, notifier, mode: .single)
        vm.appIsActive = { false }
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-bot"))
        _ = Registry.install([chA], on: vm)

        #expect(await Registry.startWithATurn(vm, chA, "sess-bot"))
        let note = try #require(notifier.posted.last, "Bot Chat's finished reply didn't notify")
        #expect(note.kind == .turnFinished)
        #expect(note.route == nil, "a Bot Chat notification carried a main-window route")
        vm.leaveChat()
    }

    @Test func aRouteRoundTripsThroughUserInfo() {
        let route = ChatNotificationRoute(serverID: UUID(), hermesHome: "/h/1", sessionId: "sess-1")
        let info: [AnyHashable: Any] = route.userInfo.reduce(into: [:]) { $0[$1.key] = $1.value }
        #expect(ChatNotificationRoute(userInfo: info) == route)
        #expect(ChatNotificationRoute(userInfo: [:]) == nil)
    }

    // MARK: - Click routing

    /// Two windows on the server: the click goes to the one with a live
    /// chat on the session (not the newest window), switches it to Chat,
    /// focuses that chat and brings the window forward.
    @Test @MainActor func aClickFocusesTheWindowWithTheLiveChat() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let w1 = Self.makeVM(home, RecordingNotifier())
        let w2 = Self.makeVM(home, RecordingNotifier())
        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .answeringPrompts(sessionId: "sess-B"))
        _ = Registry.install([chA, chB], on: w1)
        #expect(await Registry.startWithATurn(w1, chA, "sess-A"))
        let chatA = w1.focusedChat
        #expect(await Registry.startWithATurn(w1, chB, "sess-B"))

        let directory = ChatWindowDirectory()
        let c1 = AppCoordinator(usageTracker: NoopUsageTracker())
        let c2 = AppCoordinator(usageTracker: NoopUsageTracker())
        var opened1: [ServerID] = []
        var opened2: [ServerID] = []
        directory.register(chat: w1, coordinator: c1, serverID: home.context.id, hermesHome: home.context.paths.home) { opened1.append($0) }
        directory.register(chat: w2, coordinator: c2, serverID: home.context.id, hermesHome: home.context.paths.home) { opened2.append($0) }

        let outcome = directory.route(ChatNotificationRoute(serverID: home.context.id, hermesHome: home.context.paths.home, sessionId: "sess-A"))
        #expect(outcome == .focusedLiveChat)
        #expect(w1.focusedChat === chatA, "the click didn't focus the chat")
        #expect(c1.selectedSection == .chat)
        #expect(opened1 == [home.context.id], "the window wasn't brought forward")
        #expect(c2.selectedSessionId == nil && opened2.isEmpty, "the other window was routed too")
        w1.leaveChat()
        w2.leaveChat()
    }

    /// No live chat on the session: the newest window on the server gets
    /// the resume handoff ChatView consumes (focus-or-open).
    @Test @MainActor func aClickWithNoLiveChatUsesTheResumeHandoff() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let w1 = Self.makeVM(home, RecordingNotifier())
        let directory = ChatWindowDirectory()
        let c1 = AppCoordinator(usageTracker: NoopUsageTracker())
        var opened: [ServerID] = []
        directory.register(chat: w1, coordinator: c1, serverID: home.context.id, hermesHome: home.context.paths.home) { opened.append($0) }

        let outcome = directory.route(ChatNotificationRoute(serverID: home.context.id, hermesHome: home.context.paths.home, sessionId: "sess-Z"))
        #expect(outcome == .handedOff)
        #expect(c1.selectedSection == .chat)
        #expect(c1.selectedSessionId == "sess-Z")
        #expect(opened == [home.context.id])
    }

    /// No window on the server: the click is staged, a window for it is
    /// asked for, and the root that registers for that server takes it.
    @Test @MainActor func aClickForAServerWithNoWindowIsStagedForTheNextOne() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let other = Self.makeVM(home, RecordingNotifier())
        let directory = ChatWindowDirectory()
        let cOther = AppCoordinator(usageTracker: NoopUsageTracker())
        var opened: [ServerID] = []
        directory.register(chat: other, coordinator: cOther, serverID: home.context.id, hermesHome: home.context.paths.home) { opened.append($0) }

        let server = UUID()
        let route = ChatNotificationRoute(serverID: server, hermesHome: "/h/y", sessionId: "sess-Y")
        #expect(directory.route(route) == .staged)
        #expect(directory.pendingRoute == route)
        #expect(opened == [server], "no window was asked for the route's server")
        #expect(cOther.selectedSessionId == nil)

        let fresh = Self.makeVM(home, RecordingNotifier())
        let cFresh = AppCoordinator(usageTracker: NoopUsageTracker())
        directory.register(chat: fresh, coordinator: cFresh, serverID: server, hermesHome: "/h/y") { _ in }
        #expect(cFresh.selectedSection == .chat)
        #expect(cFresh.selectedSessionId == "sess-Y", "the new window didn't take the staged route")
        #expect(directory.pendingRoute == nil)
    }

    // MARK: - Budget dialog fixes

    /// SwiftUI may write the dialog's binding before running the Stop
    /// button: that write must not be read as a Wait (whose "Not sent"
    /// would put the message back while Stop sends it).
    @Test @MainActor func aStopIsNeverAlsoAWait() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 1)
        let w1 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let w2 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let busy = ControlledChannel(sessionId: "sess-busy")
        Self.install([busy], on: w1)
        let next = ControlledChannel(sessionId: "sess-next")
        Self.install([next], on: w2)
        #expect(await Self.startWorking(w1, busy, "busy"))
        let busyChat = w1.focusedChat

        w2.sendText("queued words")
        let block = try #require(w2.budgetBlocked, "a full budget didn't ask")
        // The binding's write first, then the button's action.
        w2.budgetDialogDismissed(blockID: block.id)
        w2.stopChatForBudget(block, chatID: busyChat.id)
        #expect(await Lifecycle.waitUntil { await next.hasHeldPrompt }, "Stop didn't send the message")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(w2.focusedChat.composer.text.isEmpty, "the Stop was also taken as a Wait")
        #expect(w2.richChatViewModel.transientHint?.hasPrefix("Not sent") != true)
        w1.leaveChat()
        w2.leaveChat()
    }

    /// A dismissal with no button (Esc) is a Wait: the message is put back
    /// in the composer, with the "Not sent" hint.
    @Test @MainActor func aDismissalAloneWaitsAndKeepsTheMessage() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 1)
        let w1 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let w2 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let busy = ControlledChannel(sessionId: "sess-busy")
        Self.install([busy], on: w1)
        #expect(await Self.startWorking(w1, busy, "busy"))

        w2.sendText("queued words")
        #expect(w2.budgetBlocked != nil)
        w2.budgetDialogDismissed(blockID: w2.budgetBlocked?.id)
        #expect(await Lifecycle.waitUntil { w2.budgetBlocked == nil })
        #expect(w2.focusedChat.composer.text == "queued words", "the dropped message was lost")
        #expect(w2.richChatViewModel.transientHint?.hasPrefix("Not sent") == true)
        w1.leaveChat()
        w2.leaveChat()
    }

    /// Stop on a chat whose typed first message is still starting (shown in
    /// another window): the message goes back in that chat's composer, its
    /// echo goes, and the chat says it wasn't sent.
    @Test @MainActor func stopOnATypedAutostartPutsTheMessageBack() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 1)
        let w1 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let w2 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let wedged = Scripted(behavior: .happy(sessionId: "sess-K"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        w1.acpClientFactory = { ctx, _ in
            _ = calls.next()
            return ACPClient(context: ctx) { _ in
                for await _ in gate { break }
                return wedged
            }
        }
        let next = Scripted(behavior: .answeringPrompts(sessionId: "sess-N"))
        _ = Registry.install([next], on: w2)

        w1.sendText("hello there")
        let starting = w1.focusedChat
        #expect(await Lifecycle.waitUntil { calls.count == 1 })
        #expect(starting.richChatViewModel.messages.contains { $0.isUser && $0.content == "hello there" })

        w2.startNewSession()
        let block = try #require(w2.budgetBlocked)
        w2.stopChatForBudget(block, chatID: starting.id)

        #expect(starting.composer.text == "hello there", "the stopped message was lost")
        #expect(!starting.richChatViewModel.messages.contains { $0.isUser },
                "the unsent message still shows as sent")
        #expect(starting.richChatViewModel.isAgentWorking == false)
        #expect(starting.richChatViewModel.transientHint?.hasPrefix("Not sent") == true)
        #expect(w1.focusedChat === starting)
        #expect(await Registry.readyOn(w2, "sess-N"))
        gateCont.yield(())
        gateCont.finish()
        #expect(await Lifecycle.waitUntil { await wedged.closed })
        w1.leaveChat()
        w2.leaveChat()
    }

    // MARK: - Step 3 audit fixes

    /// Stop first, then the binding's write naming the block the dialog
    /// showed: still not a Wait.
    @Test @MainActor func aStopThenTheDismissalIsNotAWait() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 1)
        let w1 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let w2 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let busy = ControlledChannel(sessionId: "sess-busy")
        Self.install([busy], on: w1)
        let next = ControlledChannel(sessionId: "sess-next")
        Self.install([next], on: w2)
        #expect(await Self.startWorking(w1, busy, "busy"))
        let busyChat = w1.focusedChat

        w2.sendText("queued words")
        let block = try #require(w2.budgetBlocked)
        w2.stopChatForBudget(block, chatID: busyChat.id)
        w2.budgetDialogDismissed(blockID: block.id)
        #expect(await Lifecycle.waitUntil { await next.hasHeldPrompt }, "Stop didn't send the message")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(w2.focusedChat.composer.text.isEmpty, "the Stop was also taken as a Wait")
        #expect(w2.richChatViewModel.transientHint?.hasPrefix("Not sent") != true)
        w1.leaveChat()
        w2.leaveChat()
    }

    /// Two windows on one server viewing different profiles: the click goes
    /// to the window on the route's profile, never to the other one (even
    /// the newer one).
    @Test @MainActor func aClickLandsOnlyInAWindowOnItsProfile() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let wB = Self.makeVM(home, RecordingNotifier())
        let wA = Self.makeVM(home, RecordingNotifier())
        let directory = ChatWindowDirectory()
        let cB = AppCoordinator(usageTracker: NoopUsageTracker())
        let cA = AppCoordinator(usageTracker: NoopUsageTracker())
        let server = home.context.id
        directory.register(chat: wB, coordinator: cB, serverID: server, hermesHome: "/home/b") { _ in }
        directory.register(chat: wA, coordinator: cA, serverID: server, hermesHome: "/home/a") { _ in }

        let outcome = directory.route(ChatNotificationRoute(serverID: server, hermesHome: "/home/b", sessionId: "sess-Q"))
        #expect(outcome == .handedOff)
        #expect(cB.selectedSessionId == "sess-Q")
        #expect(cA.selectedSessionId == nil, "the click opened the session in another profile's window")
    }

    /// The only window on the server views another profile: the click is
    /// staged (that window is brought forward, not handed the session), and
    /// switching the window to the route's profile — a new root — takes it.
    @Test @MainActor func aClickForAnotherProfileWaitsForThatProfile() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let wA = Self.makeVM(home, RecordingNotifier())
        let directory = ChatWindowDirectory()
        let cA = AppCoordinator(usageTracker: NoopUsageTracker())
        let server = home.context.id
        var opened: [ServerID] = []
        directory.register(chat: wA, coordinator: cA, serverID: server, hermesHome: "/home/a") { opened.append($0) }

        let route = ChatNotificationRoute(serverID: server, hermesHome: "/home/b", sessionId: "sess-Q")
        #expect(directory.route(route) == .staged)
        #expect(cA.selectedSessionId == nil, "the session was handed to a window on another profile")
        #expect(opened == [server])

        // The profile switch: the old root goes, a new one registers.
        directory.unregister(chat: wA)
        let wB = Self.makeVM(home, RecordingNotifier())
        let cB = AppCoordinator(usageTracker: NoopUsageTracker())
        directory.register(chat: wB, coordinator: cB, serverID: server, hermesHome: "/home/b") { _ in }
        #expect(cB.selectedSessionId == "sess-Q")
        #expect(directory.pendingRoute == nil)
    }

    /// A staged click expires: a window opening a minute later doesn't jump
    /// to a session the user clicked long ago.
    @Test @MainActor func aStagedClickExpires() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let directory = ChatWindowDirectory()
        var clock = Date()
        directory.now = { clock }
        let route = ChatNotificationRoute(serverID: home.context.id, hermesHome: "/home/a", sessionId: "sess-Q")
        #expect(directory.route(route) == .staged)
        clock = clock.addingTimeInterval(ChatWindowDirectory.stagedRouteLifetime + 1)
        let w = Self.makeVM(home, RecordingNotifier())
        let c = AppCoordinator(usageTracker: NoopUsageTracker())
        directory.register(chat: w, coordinator: c, serverID: home.context.id, hermesHome: "/home/a") { _ in }
        #expect(c.selectedSessionId == nil, "an expired click was still taken")
        #expect(directory.pendingRoute == nil)
    }

    /// The window's root going (window close, or a profile switch) withdraws
    /// what its chats posted — the shown chat's "finished" note included.
    @Test @MainActor func leavingTheWindowWithdrawsItsNotes() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let notifier = RecordingNotifier()
        let vm = Self.makeVM(home, notifier)
        vm.isChatPaneVisible = false
        let chA = ControlledChannel(sessionId: "sess-A")
        Self.install([chA], on: vm)
        #expect(await Self.startWorking(vm, chA, "work"))
        await chA.completePrompts()
        #expect(await Lifecycle.waitUntil { notifier.posted.count == 1 })
        let identifier = try #require(notifier.posted.first).identifier
        #expect(identifier.contains(vm.focusedChat.id.uuidString), "the note's id doesn't name its chat")

        vm.leaveChat()
        #expect(notifier.removed.contains(identifier), "the shown chat's note outlived its window")
    }

    /// Stop from the dialog on a chat whose typed first message is still
    /// starting, when the open then moves focus off it (and the window drops
    /// it): the message lands in the chat the user is in.
    @Test @MainActor func aStoppedTypedStartThatIsDroppedHandsItsMessageOn() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, RecordingNotifier(), budget: LiveChatBudget(localLimit: 1))
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
        vm.sendText("hello there")
        let starting = vm.focusedChat
        #expect(await Lifecycle.waitUntil { calls.count == 1 })

        vm.startNewSession()
        let block = try #require(vm.budgetBlocked)
        vm.stopChatForBudget(block, chatID: starting.id)
        #expect(await Registry.readyOn(vm, "sess-N"))
        // The stopped chat is either dropped or (blank by then) reused for
        // the open; either way its own composer no longer holds the text.
        #expect(await Lifecycle.waitUntil { vm.focusedChat.composer.text == "hello there" },
                "the stopped chat's message was lost with it")
        #expect(vm.focusedChat.richChatViewModel.transientHint?.hasPrefix("Not sent — you stopped that chat") == true)
        gateCont.yield(())
        gateCont.finish()
        vm.leaveChat()
    }

    /// The same hand-over into a chat with a draft of its own: the draft is
    /// kept and the hint quotes the message instead.
    @Test @MainActor func aHandedOnMessageNeverOverwritesADraft() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 2)
        let w1 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let w2 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let wedged = Scripted(behavior: .happy(sessionId: "sess-K"))
        let shown = Scripted(behavior: .answeringPrompts(sessionId: "sess-S"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        w1.acpClientFactory = { ctx, _ in
            if calls.next() == 1 {
                return ACPClient(context: ctx) { _ in
                    for await _ in gate { break }
                    return wedged
                }
            }
            return ACPClient(context: ctx) { _ in shown }
        }
        let w2Channel = ControlledChannel(sessionId: "sess-W2")
        Self.install([w2Channel], on: w2)

        w1.sendText("a long first message that will be quoted back")
        let starting = w1.focusedChat
        #expect(await Lifecycle.waitUntil { calls.count == 1 })
        w1.startNewSession() // the typed start keeps running in the background
        #expect(await Registry.readyOn(w1, "sess-S"))

        w2.focusedChat.composer.text = "my own draft"
        w2.sendText("go")
        let block = try #require(w2.budgetBlocked)
        w2.stopChatForBudget(block, chatID: starting.id)
        #expect(await Lifecycle.waitUntil { await w2Channel.hasHeldPrompt })
        #expect(await Lifecycle.waitUntil {
            w2.richChatViewModel.transientHint?.contains("“a long first message that will be quoted…”") == true
        }, "the stopped message wasn't quoted")
        #expect(w2.focusedChat.composer.text == "my own draft", "the hand-over overwrote a draft")
        gateCont.yield(())
        gateCont.finish()
        w1.leaveChat()
        w2.leaveChat()
    }

    /// Stop on a typed start resuming a session: the echo must stay (it is
    /// in that session's pending-echo cache), so the text is NOT also put
    /// back in the composer — sending it again would duplicate it.
    @Test @MainActor func aStoppedTypedStartOnASessionIsNotRestoredTwice() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let budget = LiveChatBudget(localLimit: 1)
        let w1 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let w2 = Self.makeVM(home, RecordingNotifier(), budget: budget)
        let first = Scripted(behavior: .happy(sessionId: "sess-A"))
        let wedged = Scripted(behavior: .happy(sessionId: "sess-A"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        w1.acpClientFactory = { ctx, _ in
            if calls.next() == 1 { return ACPClient(context: ctx) { _ in first } }
            return ACPClient(context: ctx) { _ in
                for await _ in gate { break }
                return wedged
            }
        }
        let next = Scripted(behavior: .answeringPrompts(sessionId: "sess-N"))
        _ = Registry.install([next], on: w2)

        w1.resumeSession("sess-A")
        #expect(await Registry.readyOn(w1, "sess-A"))
        let chat = w1.focusedChat
        w1.stopACP()
        w1.sendText("again") // autostart back into sess-A
        #expect(await Lifecycle.waitUntil { calls.count == 2 })

        w2.startNewSession()
        let block = try #require(w2.budgetBlocked)
        w2.stopChatForBudget(block, chatID: chat.id)
        #expect(chat.composer.text.isEmpty, "the text was put back beside its sent-looking echo")
        #expect(chat.richChatViewModel.messages.contains { $0.isUser && $0.content == "again" })
        #expect(chat.richChatViewModel.transientHint?.hasPrefix("Not sent") == true)
        #expect(await Registry.readyOn(w2, "sess-N"))
        gateCont.yield(())
        gateCont.finish()
        w1.leaveChat()
        w2.leaveChat()
    }

    /// The shown chat's start failed (no client: not "live"): its row still
    /// reads that chat and shows the error.
    @Test @MainActor func theShownChatsFailureShowsOnItsRow() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, RecordingNotifier())
        _ = Registry.install([Scripted(behavior: .loadRPCError(sessionId: "sess-F"))], on: vm)
        vm.resumeSession("sess-F")
        #expect(await Lifecycle.waitUntil { vm.acpError != nil && !vm.isPreparingSession })
        #expect(vm.liveChat(covering: "sess-F") == nil)
        let row = Registry.stubSession(id: "sess-F")
        #expect(vm.rowChat(for: row) === vm.focusedChat)
        #expect(vm.rowChat(for: row)?.rowState == .error, "the failed chat's row didn't show the error")
        #expect(vm.rowChat(for: Registry.stubSession(id: "sess-other")) == nil)
        vm.leaveChat()
    }

    /// An image still encoding when the draft is thrown away (the chat moved
    /// to another conversation) lands nowhere, and the slot count is clean.
    @Test @MainActor func anEncodeFromAClearedDraftLandsNowhere() {
        let draft = ComposerDraft(capacity: 5)
        #expect(draft.slots.reserve(upTo: 2) == 2)
        let generation = draft.slots.generation
        draft.text = "old"
        draft.clear()
        #expect(draft.slots.reserved == 0)
        draft.slots.commit(Self.image(), generation: generation)
        draft.slots.release(generation: generation)
        #expect(draft.slots.attachments.isEmpty, "an old conversation's image landed in the new draft")
        #expect(draft.slots.reserved == 0)
        // The new draft's own encodes still land.
        #expect(draft.slots.reserve(upTo: 1) == 1)
        draft.slots.commit(Self.image(), generation: draft.slots.generation)
        #expect(draft.slots.attachments.count == 1)
    }

    static func image() -> ChatImageAttachment {
        ChatImageAttachment(mimeType: "image/png", base64Data: "AAAA", thumbnailBase64: nil,
                            filename: "img.png", approximateByteCount: 4)
    }

    // MARK: - The notification service

    @MainActor
    final class AuthorizationGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var waiting: Int { waiters.count }
        func wait() async { await withCheckedContinuation { waiters.append($0) } }
        func open() {
            let all = waiters
            waiters = []
            for waiter in all { waiter.resume() }
        }
    }

    @MainActor
    final class CenterRecorder {
        var delivered: [String] = []
        var withdrawn: [String] = []
        var authorizations = 0
    }

    @MainActor
    static func service(_ gate: AuthorizationGate, _ center: CenterRecorder, toggleOn: Bool = true) -> ChatNotificationService {
        let defaults = UserDefaults(suiteName: "p1-notify-\(UUID().uuidString)")!
        defaults.set(toggleOn, forKey: ChatNotificationService.toggleKey)
        return ChatNotificationService(
            isSyntheticHost: false,
            defaults: defaults,
            authorize: {
                center.authorizations += 1
                await gate.wait()
                return true
            },
            deliver: { center.delivered.append($0.identifier) },
            withdraw: { center.withdrawn += $0 }
        )
    }

    static func note(_ id: String, _ kind: ChatNotification.Kind = .needsAnswer) -> ChatNotification {
        ChatNotification(kind: kind, identifier: id, title: "t", body: "b", route: nil)
    }

    /// A needs-answer note withdrawn while its post still waits for
    /// authorization is never delivered; the others are.
    @Test @MainActor func aNoteWithdrawnBeforeAuthorizationIsNeverDelivered() async {
        let gate = AuthorizationGate()
        let center = CenterRecorder()
        let service = Self.service(gate, center)
        service.post(Self.note("answered"))
        service.post(Self.note("still-open"))
        #expect(await Lifecycle.waitUntil { gate.waiting == 2 })
        service.remove(identifiers: ["answered"])
        gate.open()
        #expect(await Lifecycle.waitUntil { center.delivered == ["still-open"] })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(center.delivered == ["still-open"], "a withdrawn note was delivered after authorization")
        #expect(center.withdrawn == ["answered"])
    }

    /// With "Notify when Hermes finishes" off, neither kind posts.
    @Test @MainActor func theToggleSilencesBothKinds() async {
        let gate = AuthorizationGate()
        let center = CenterRecorder()
        let service = Self.service(gate, center, toggleOn: false)
        service.post(Self.note("done", .turnFinished))
        service.post(Self.note("question", .needsAnswer))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(center.authorizations == 0, "a note was posted with notifications turned off")
        #expect(service.wanted.isEmpty)
    }
}
