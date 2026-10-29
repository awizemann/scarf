import Testing
import Foundation
import ScarfCore
@testable import scarf_mobile

/// Opening another chat while the open one is still replying asks first
/// ("This chat is still replying"), and "Stop and Switch" cancels the turn
/// with `session/cancel`, bounded so a wedged host can't hang the switch.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ChatControllerSwitchMidTurnTests {

    typealias Channel = ChatControllerResume146Tests.Channel
    typealias Request = ChatController.ChatSwitchRequest

    @Test func idleChatSwitchesWithoutAsking() {
        let requests: [Request] = [.newChat(), .newChat(name: "Trip"), .projectPath("/p"), .resume(sessionID: "a"), .resume(sessionID: "open")]
        for request in requests {
            #expect(ChatController.switchDecision(request, turnRunning: false, openSessionID: "open") == .proceed)
        }
    }

    @Test func switchingAwayFromAReplyingChatAsks() {
        let requests: [Request] = [
            .newChat(),
            .newChat(name: "Trip"),
            .project(ProjectEntry(name: "P", path: "/p")),
            .projectPath("/p"),
            .resume(sessionID: "other"),
        ]
        for request in requests {
            #expect(ChatController.switchDecision(request, turnRunning: true, openSessionID: "open") == .confirm)
        }
        // No chat open yet: any resume is a switch.
        #expect(ChatController.switchDecision(.resume(sessionID: "x"), turnRunning: true, openSessionID: nil) == .confirm)
    }

    @Test func reopeningTheReplyingChatLeavesItAlone() {
        #expect(ChatController.switchDecision(.resume(sessionID: "open"), turnRunning: true, openSessionID: "open") == .ignore)
    }

    /// The fake host never answers `session/prompt` — a wedged turn. The
    /// stop still sends `session/cancel` and returns within its bound.
    @Test func stopBeforeSwitchCancelsAndIsBounded() async throws {
        try await ChatControllerResume146Tests.withFakeRemote { ctx in
            let ch = Channel(load: .restores)
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in ACPClient(context: ctx) { _ in ch } }
            await controller.start()
            #expect(ChatControllerResume146Tests.isReady(controller))
            #expect(!controller.isTurnRunning)

            controller.draft = "hello"
            let sendTask = Task { await controller.send() }
            for _ in 0..<200 where controller.promptsInFlight == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(controller.isTurnRunning)
            #expect(ChatController.switchDecision(
                .newChat(), turnRunning: controller.isTurnRunning, openSessionID: controller.vm.sessionId
            ) == .confirm)

            controller.switchCancelTimeout = .milliseconds(200)
            let clock = ContinuousClock()
            let started = clock.now
            await controller.stopTurnBeforeSwitch()
            #expect(clock.now - started < .seconds(2))
            #expect((await ch.sentMethods).contains("session/cancel"))

            await controller.stop()
            sendTask.cancel()
        }
    }

    /// Typed `/new <name>` mid-reply goes to the confirm path instead of
    /// tearing the chat down; idle, it starts the new chat as before.
    @Test func typedNewMidReplyAsksAndIdleNewSwitches() async throws {
        try await ChatControllerResume146Tests.withFakeRemote { ctx in
            // A fresh fake channel per client: `/new` stops the old one.
            var channels: [Channel] = []
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in
                let ch = Channel(load: .restores)
                channels.append(ch)
                return ACPClient(context: ctx) { _ in ch }
            }
            var handed: [Request] = []
            controller.switchRequestHandler = { handed.append($0) }
            await controller.start()

            // Idle: no hand-off, a fresh session starts on a new client.
            controller.draft = "/new"
            await controller.send()
            #expect(handed.isEmpty)
            #expect(channels.count == 2)
            #expect(ChatControllerResume146Tests.isReady(controller))

            controller.draft = "hello"
            let sendTask = Task { await controller.send() }
            for _ in 0..<200 where controller.promptsInFlight == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(controller.isTurnRunning)

            // Mid-reply: handed to the confirm path, chat left running.
            controller.draft = "/new Trip"
            await controller.send()
            #expect(handed == [.newChat(name: "Trip")])
            #expect(channels.count == 2)
            #expect(ChatControllerResume146Tests.isReady(controller))
            #expect(controller.isTurnRunning)

            await controller.stop()
            sendTask.cancel()
        }
    }

    /// A host that answers a running `session/prompt` with `cancelled` once
    /// `session/cancel` arrives — the normal, healthy stop.
    actor CancellingChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private var promptIds: [Int] = []
        private(set) var sentMethods: [String] = []

        var diagnosticID: String? { "switch-cancel-channel" }

        init() {
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = inStream
            incomingCont = inCont
            stderr = errStream
            stderrCont = errCont
        }

        func send(_ line: String) async throws {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            sentMethods.append(method)
            if method == "session/cancel" {
                for id in promptIds {
                    yield(["jsonrpc": "2.0", "id": id, "result": ["stopReason": "cancelled"]])
                }
                promptIds = []
                return
            }
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/new":
                yield(["jsonrpc": "2.0", "id": id,
                       "result": ["sessionId": "acp-new", "modes": ["currentModeId": "default"]]])
            case "session/prompt":
                promptIds.append(id)
            default:
                yield(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        func close() async {
            incomingCont.finish()
            stderrCont.finish()
        }

        private func yield(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }
    }

    private static func startTurn(_ controller: ChatController) async throws -> Task<Void, Never> {
        controller.draft = "hello"
        let task = Task { await controller.send() }
        for _ in 0..<200 where controller.promptsInFlight == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        return task
    }

    /// Healthy host: the cancelled turn returns, so the stop ends well
    /// before its bound.
    @Test func stopBeforeSwitchEndsWhenTheTurnReturns() async throws {
        try await ChatControllerResume146Tests.withFakeRemote { ctx in
            let ch = CancellingChannel()
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in ACPClient(context: ctx) { _ in ch } }
            await controller.start()
            let sendTask = try await Self.startTurn(controller)
            #expect(controller.isTurnRunning)

            controller.switchCancelTimeout = .seconds(30)
            let clock = ContinuousClock()
            let started = clock.now
            await controller.stopTurnBeforeSwitch()
            #expect(clock.now - started < .seconds(2))
            #expect(controller.promptsInFlight == 0)
            #expect((await ch.sentMethods).contains("session/cancel"))
            await sendTask.value
        }
    }

    /// `/new Trip` mid-reply: "Keep Waiting" puts the text back; "Stop and
    /// Switch" opens the new chat and keeps the name for its first turn.
    @Test func typedNewKeepsTextOnKeepWaitingAndNameOnConfirm() async throws {
        try await ChatControllerResume146Tests.withFakeRemote { ctx in
            var channels: [CancellingChannel] = []
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in
                let ch = CancellingChannel()
                channels.append(ch)
                return ACPClient(context: ctx) { _ in ch }
            }
            var handed: [Request] = []
            controller.switchRequestHandler = { handed.append($0) }
            await controller.start()
            let sendTask = try await Self.startTurn(controller)

            controller.draft = "/new Trip"
            await controller.send()
            #expect(handed == [.newChat(name: "Trip")])
            #expect(controller.draft.isEmpty)
            controller.cancelPendingSwitch()
            #expect(controller.draft == "/new Trip")

            controller.draft = "/new Trip"
            await controller.send()
            await controller.runSwitch(.newChat(name: "Trip"), stopTurnFirst: true)
            #expect(controller.draft.isEmpty)
            try #require(channels.count == 2)
            let oldChannel = try #require(channels.first)
            #expect((await oldChannel.sentMethods).contains("session/cancel"))
            #expect(controller.pendingSessionTitle?.title == "Trip")
            #expect(controller.pendingSessionTitle?.sessionId == controller.vm.sessionId)
            await sendTask.value
            await controller.stop()
        }
    }

    /// While a switch waits on a wedged host, Send is a no-op and a newer
    /// request replaces the queued one: only the latest switch runs.
    @Test func aSwitchInFlightBlocksSendAndTheLatestRequestWins() async throws {
        try await ChatControllerResume146Tests.withFakeRemote { ctx in
            var channels: [Channel] = []
            let controller = ChatController(context: ctx)
            controller.clientFactory = { _ in
                let ch = Channel(load: .restores)
                channels.append(ch)
                return ACPClient(context: ctx) { _ in ch }
            }
            await controller.start()
            let sendTask = try await Self.startTurn(controller)
            controller.switchCancelTimeout = .milliseconds(300)

            let first = Task { await controller.runSwitch(.newChat(name: "A"), stopTurnFirst: true) }
            for _ in 0..<100 where !controller.isSwitchingChats {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(controller.isSwitchingChats)

            controller.draft = "late"
            await controller.send()
            #expect(controller.draft == "late")
            let oldChannel = try #require(channels.first)
            #expect((await oldChannel.sentMethods).filter { $0 == "session/prompt" }.count == 1)

            await controller.runSwitch(.newChat(name: "B"), stopTurnFirst: false)
            await first.value
            #expect(!controller.isSwitchingChats)
            #expect(channels.count == 2)
            #expect(controller.pendingSessionTitle?.title == "B")

            await controller.stop()
            sendTask.cancel()
        }
    }
}
