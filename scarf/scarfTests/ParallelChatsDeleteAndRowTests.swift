import Testing
import Foundation
import ScarfCore
@testable import scarf

/// The temporary row for a chat Hermes hasn't stored, stop-before-delete on
/// both delete surfaces, and a reply's last chunks at the end of a turn
/// (parallel chats P3, each found by the live tests or their audit).
@Suite struct ParallelChatsDeleteAndRowTests {
    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias Registry = ParallelChatsRegistryTests
    typealias Rows = ParallelChatsRowsNotificationsTests
    typealias Controlled = Rows.ControlledChannel

    @MainActor private static func makeVM(_ home: TempHermesHome) -> ChatViewModel {
        Rows.makeVM(home, Rows.RecordingNotifier())
    }

    private static let missing = "No session 'x'. Run: hermes sessions list to find the id."

    // MARK: - The temporary row

    @Test @MainActor func aFreshChatGetsARowOnceAPromptHasGoneOut() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        #expect(!vm.sessionsForList.contains { $0.id == "sess-A" }, "a blank chat has no row")

        vm.sendText("hello")
        #expect(await Lifecycle.waitUntil { await ch.hasHeldPrompt })
        #expect(vm.sessionsForList.first?.id == "sess-A")
        vm.leaveChat()
    }

    /// `/help` reaches ACP, and v0.21.5 answers it without saving a session.
    @Test @MainActor func aSlashCommandEarnsNoRow() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        vm.focusedChat.richChatViewModel.seedACPCommands([
            HermesSlashCommand(name: "hermeshelp", description: "", argumentHint: nil, source: .acp)
        ])
        vm.sendText("/hermeshelp")
        #expect(await Lifecycle.waitUntil { await ch.hasHeldPrompt }, "the command must reach ACP or this proves nothing")
        #expect(!vm.sessionsForList.contains { $0.id == "sess-A" })

        // The first real prompt does.
        await ch.completePrompts()
        #expect(await Lifecycle.waitUntil { !vm.focusedChat.hasTurnInFlight })
        vm.sendText("hello")
        #expect(await Lifecycle.waitUntil { vm.sessionsForList.contains { $0.id == "sess-A" } })
        vm.leaveChat()
    }

    /// A resumed session outside the newest 50 isn't unstored: no invented row.
    @Test @MainActor func aResumedChatNeverGetsARow() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "old-session")
        Rows.install([ch], on: vm)
        vm.resumeSession("old-session")
        #expect(await Registry.readyOn(vm, "old-session"))
        vm.sendText("hello again")
        #expect(await Lifecycle.waitUntil { await ch.hasHeldPrompt })
        #expect(!vm.sessionsForList.contains { $0.id == "old-session" })
        vm.leaveChat()
    }

    /// Deleting the temporary row: Hermes has nothing to delete, which is no
    /// failure. The chat and row go, and no error shows.
    @Test @MainActor func deletingAnUnstoredChatDropsItWithoutAnError() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        Rows.install([chA, chB], on: vm)
        #expect(await Rows.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(await Rows.startWorking(vm, chB, "work in B"))
        vm.sessionDeleteRunner = { _, _ in (1, Self.missing) }

        await vm.deleteConversation(try #require(vm.sessionsForList.first { $0.id == "sess-A" }))

        #expect(!vm.chats.contains { $0 === chatA })
        #expect(!vm.sessionsForList.contains { $0.id == "sess-A" })
        #expect(vm.richChatViewModel.transientHint?.contains("Couldn't delete") != true)
        vm.leaveChat()
    }

    // MARK: - Stop before delete

    /// The sidebar stops the working chat first, and only that chat.
    @Test @MainActor func deletingAWorkingChatStopsOnlyItBeforeTheDelete() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        Rows.install([chA, chB], on: vm)
        #expect(await Rows.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(await Rows.startWorking(vm, chB, "work in B"))
        let chatB = vm.focusedChat

        nonisolated(unsafe) var workingAtDelete: Bool?
        vm.sessionDeleteRunner = { _, _ in
            workingAtDelete = DispatchQueue.main.sync { MainActor.assumeIsolated { chatA.hasTurnInFlight } }
            return (0, "")
        }
        await vm.deleteSession("sess-A")

        #expect(workingAtDelete == false, "chat A was still working when Hermes was asked")
        #expect(!vm.chats.contains { $0 === chatA })
        #expect(vm.focusedChat === chatB)
        #expect(chatB.hasTurnInFlight, "the other chat stopped too")
        vm.leaveChat()
    }

    /// Hermes refusing a focused chat's delete: the turn stopped, but the
    /// transcript stays, nothing says "deleted", and Hermes's reason shows.
    @Test @MainActor func aRefusedDeleteKeepsTheTranscriptAndShowsWhy() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)
        #expect(await Rows.startWorking(vm, ch, "work in A"))
        let lost = "Cannot delete session 'sess-A': a turn was lost across a gateway restart."
        let calls = Lifecycle.CallCounter()
        nonisolated(unsafe) var hintWhileAsking: String?
        vm.sessionDeleteRunner = { _, _ in
            hintWhileAsking = DispatchQueue.main.sync { MainActor.assumeIsolated { vm.richChatViewModel.transientHint } }
            _ = calls.next()
            return (1, lost)
        }

        await vm.deleteSession("sess-A")

        #expect(calls.next() == 2, "that refusal isn't retried")
        #expect(hintWhileAsking == "Turn cancelled.", "nothing is deleted yet: \(hintWhileAsking ?? "nil")")
        #expect(vm.richChatViewModel.transientHint?.contains("lost across a gateway restart") == true)
        #expect(vm.richChatViewModel.transientHint?.contains("session deleted") != true)
        #expect(vm.richChatViewModel.messages.contains { $0.isUser && $0.content == "work in A" })
        vm.leaveChat()
    }

    /// After a confirmed delete the focused chat says so.
    @Test @MainActor func aConfirmedDeleteSaysTheSessionIsGone() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)
        #expect(await Rows.startWorking(vm, ch, "work in A"))
        vm.sessionDeleteRunner = { _, _ in (0, "") }
        await vm.deleteSession("sess-A")
        #expect(vm.richChatViewModel.transientHint == "Turn cancelled — session deleted.")
        vm.leaveChat()
    }

    /// The Sessions tab reaches chats through the window directory: stop, then
    /// delete, retrying the refusal of the turn still unwinding, on the
    /// output-reporting runner; and a final refusal is shown.
    @Test @MainActor func theSessionsTabStopsTheChatThenDeletesAndReports() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let coordinator = AppCoordinator(usageTracker: NoopUsageTracker())
        let ch = Controlled(sessionId: "sess-tab")
        Rows.install([ch], on: vm)
        #expect(await Rows.startWorking(vm, ch, "work"))
        let chat = vm.focusedChat
        ChatWindowDirectory.shared.register(
            chat: vm, coordinator: coordinator, serverID: home.context.id,
            hermesHome: home.context.paths.home, openWindow: { _ in })
        defer { ChatWindowDirectory.shared.unregister(chat: vm) }

        let svm = SessionsViewModel(context: home.context)
        let calls = Lifecycle.CallCounter()
        nonisolated(unsafe) var workingAtDelete: Bool?
        svm.sessionDeleteRunner = { _, _ in
            workingAtDelete = DispatchQueue.main.sync { MainActor.assumeIsolated { chat.hasTurnInFlight } }
            return calls.next() == 1
                ? (1, "Cannot delete active session: it has an active turn lease")
                : (0, "")
        }
        svm.deleteSessionId = "sess-tab"
        svm.confirmDelete()
        await svm.inFlightDelete?.value

        #expect(workingAtDelete == false)
        #expect(calls.next() == 3, "one refusal, one retry")
        #expect(svm.deleteError == nil)
        vm.leaveChat()

        let refusing = SessionsViewModel(context: home.context)
        refusing.sessionDeleteRunner = { _, _ in (1, "Cannot delete session 'x': a turn was lost across a gateway restart.") }
        refusing.deleteSessionId = "x"
        refusing.confirmDelete()
        await refusing.inFlightDelete?.value
        #expect(refusing.deleteError?.contains("lost across a gateway restart") == true)
    }

    // MARK: - A reply's last chunks

    /// The answer to `session/prompt` overtakes chunks still in the event loop:
    /// the turn must not close without them.
    @Test @MainActor func aTurnDoesNotCloseBeforeItsLastChunks() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)
        #expect(await Rows.startWorking(vm, ch, "go"))
        let chunks = (0..<400).map { "w\($0) " }
        for chunk in chunks { await ch.emitReply(chunk) }
        await ch.completePrompts()
        #expect(await Lifecycle.waitUntil { !vm.focusedChat.hasTurnInFlight })
        let reply = vm.richChatViewModel.messages.filter(\.isAssistant).map(\.content)
        #expect(reply == [chunks.joined()], "\(reply.map(\.count))")
        vm.leaveChat()
    }
}
