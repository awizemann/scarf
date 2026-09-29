import Testing
import Foundation
import ScarfCore
@testable import scarf_mobile

/// gh#147 on ScarfGo, through the real `ChatController.send()`: `/retry`,
/// `/undo` and `/title` are answered client-side and never reach the ACP
/// wire. Removing the send-path intercept makes each of these fail
/// (the text would go out as `session/prompt`).
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ChatControllerSlash147Tests {

    typealias Channel = ChatControllerResume146Tests.Channel

    private static func readyController(
        _ ctx: ServerContext, channel: Channel
    ) async -> ChatController {
        let controller = ChatController(context: ctx)
        controller.clientFactory = { _ in ACPClient(context: ctx) { _ in channel } }
        await controller.start()
        return controller
    }

    @Test(arguments: ["retry", "undo"])
    func cliOnlyCommandsNeverReachTheWire(name: String) async throws {
        try await ChatControllerResume146Tests.withFakeRemote { ctx in
            let ch = Channel(load: .restores)
            let controller = await Self.readyController(ctx, channel: ch)
            #expect(ChatControllerResume146Tests.isReady(controller))

            controller.draft = "/\(name)"
            await controller.send()

            #expect(!(await ch.sentMethods).contains("session/prompt"))
            #expect(controller.vm.transientHint == RichChatViewModel.cliOnlySlashNotice(name: name))
            #expect(!controller.vm.messages.contains { $0.content == "/\(name)" })
            #expect(controller.draft.isEmpty)
        }
    }

    @Test func titleOnAnUnsavedChatWaitsForTheFirstTurn() async throws {
        try await ChatControllerResume146Tests.withFakeRemote { ctx in
            let ch = Channel(load: .restores)
            let controller = await Self.readyController(ctx, channel: ch)
            #expect(controller.vm.sessionId == "acp-new")

            controller.draft = "/title Trip plans"
            await controller.send()

            #expect(!(await ch.sentMethods).contains("session/prompt"))
            #expect(controller.vm.transientHint == RichChatViewModel.titlePendingNotice("Trip plans"))
            #expect(!controller.vm.messages.contains { $0.content.hasPrefix("/title") })
        }
    }

    @Test func titleWithoutANameShowsUsage() async throws {
        try await ChatControllerResume146Tests.withFakeRemote { ctx in
            let ch = Channel(load: .restores)
            let controller = await Self.readyController(ctx, channel: ch)

            controller.draft = "/title"
            await controller.send()

            #expect(!(await ch.sentMethods).contains("session/prompt"))
            #expect(controller.vm.transientHint == RichChatViewModel.titleUsageNotice)
        }
    }
}
