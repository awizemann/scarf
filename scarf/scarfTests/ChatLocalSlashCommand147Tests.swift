import Testing
import Foundation
import SQLite3
@testable import scarf
import ScarfCore

/// gh#147 on the Mac, through the real `ChatViewModel.sendText`: `/retry`,
/// `/undo` and `/title` are answered client-side and never reach the ACP
/// wire. Removing the send-path intercept makes each of these fail — the
/// text would go out as `session/prompt`.
@Suite(.serialized) struct ChatLocalSlashCommand147Tests {

    typealias Scripted = ChatViewModelStartLifecycleTests.ScriptedACPChannel

    /// Records every `sessions rename` the view model runs.
    final class RenameLog: @unchecked Sendable {
        private var calls: [(String, String)] = []
        private let lock = NSLock()
        func add(_ id: String, _ title: String) { lock.lock(); calls.append((id, title)); lock.unlock() }
        var all: [(String, String)] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    /// Answers everything like `happy`, but HOLDS `session/prompt` until
    /// `completePrompt()` — so a test can store the session row first,
    /// as Hermes does during the turn.
    actor PromptGateChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let sessionId: String
        private var heldPromptIds: [Int] = []
        private(set) var sentMethods: [String] = []
        var diagnosticID: String? { "147-mac-channel" }

        init(sessionId: String) {
            self.sessionId = sessionId
            let (i, ic) = AsyncThrowingStream<String, Error>.makeStream()
            let (e, ec) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = i; incomingCont = ic; stderr = e; stderrCont = ec
        }

        func send(_ line: String) async throws {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            sentMethods.append(method)
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/new", "session/load":
                reply(["jsonrpc": "2.0", "id": id,
                       "result": ["sessionId": sessionId, "modes": ["currentModeId": "default"]]])
            case "session/prompt":
                heldPromptIds.append(id)
            default:
                reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        func completePrompt() {
            for id in heldPromptIds {
                reply(["jsonrpc": "2.0", "id": id, "result": ["stopReason": "end_turn"]])
            }
            heldPromptIds = []
        }

        func close() async { incomingCont.finish(); stderrCont.finish() }

        private func reply(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }
    }

    @MainActor
    private static func waitReady(_ vm: ChatViewModel) async -> Bool {
        await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
    }

    @Test(arguments: ["retry", "undo"]) @MainActor
    func cliOnlyCommandsNeverReachTheWire(name: String) async throws {
        let home = try ChatResumeFallback146Tests.home(sessions: [])
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = Scripted(behavior: .happy(sessionId: "acp-1"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }
        vm.startNewSession()
        #expect(await Self.waitReady(vm))

        vm.sendText("/\(name)")
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(!(await ch.sentMethods).contains("session/prompt"))
        #expect(vm.richChatViewModel.transientHint == RichChatViewModel.cliOnlySlashNotice(name: name))
        #expect(!vm.richChatViewModel.messages.contains { $0.content == "/\(name)" })
    }

    /// With no client at all, the intercept still answers first — the
    /// no-client branch would otherwise auto-start a session to send it.
    @Test @MainActor func cliOnlyCommandDoesNotAutoStartASession() async throws {
        let home = try ChatResumeFallback146Tests.home(sessions: [])
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let spawned = ChatViewModelStartLifecycleTests.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            _ = spawned.next()
            return ACPClient(context: ctx) { _ in Scripted(behavior: .happy(sessionId: "x")) }
        }
        vm.sendText("/undo")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(spawned.count == 0)
        #expect(vm.richChatViewModel.transientHint == RichChatViewModel.cliOnlySlashNotice(name: "undo"))
    }

    @Test @MainActor func titleOnAnUnsavedChatAppliesAfterTheFirstTurn() async throws {
        let home = try ChatResumeFallback146Tests.home(sessions: [])
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let log = RenameLog()
        vm.sessionRenameRunner = { _, id, title in log.add(id, title); return ("", 0) }
        let ch = PromptGateChannel(sessionId: "acp-t")
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }
        vm.startNewSession()
        #expect(await Self.waitReady(vm))

        vm.sendText("/title Trip plans")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!(await ch.sentMethods).contains("session/prompt"))
        #expect(vm.pendingSessionTitle == "Trip plans")
        #expect(vm.richChatViewModel.transientHint == RichChatViewModel.titlePendingNotice("Trip plans"))
        #expect(log.all.isEmpty, "renamed a chat Hermes hasn't stored yet")

        // The first turn: Hermes stores the session during it.
        vm.sendText("hello")
        #expect(await ChatViewModelStartLifecycleTests.waitUntil {
            await ch.sentMethods.contains("session/prompt")
        })
        try HermesV0215R18bMacTests.exec(
            "INSERT INTO sessions (id, source, title, started_at, message_count) VALUES ('acp-t', 'acp', NULL, 9.0, 1);",
            dbAt: home.url)
        await ch.completePrompt()

        #expect(await ChatViewModelStartLifecycleTests.waitUntil { !log.all.isEmpty })
        #expect(log.all.map(\.0) == ["acp-t"])
        #expect(log.all.map(\.1) == ["Trip plans"])
        #expect(vm.pendingSessionTitle == nil)
    }

    @Test @MainActor func titleOnASavedChatRenamesNow() async throws {
        let home = try ChatResumeFallback146Tests.home(sessions: [("acp-s", "acp")])
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let log = RenameLog()
        vm.sessionRenameRunner = { _, id, title in log.add(id, title); return ("", 0) }
        let ch = Scripted(behavior: .happy(sessionId: "acp-s"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }
        vm.resumeSession("acp-s")
        #expect(await Self.waitReady(vm))
        #expect(await ChatViewModelStartLifecycleTests.waitUntil {
            vm.richChatViewModel.currentSession?.id == "acp-s"
        })

        vm.sendText("/title Named now")

        #expect(await ChatViewModelStartLifecycleTests.waitUntil {
            vm.richChatViewModel.transientHint == RichChatViewModel.titleAppliedNotice("Named now")
        })
        #expect(log.all.map(\.0) == ["acp-s"])
        #expect(log.all.map(\.1) == ["Named now"])
        #expect(!(await ch.sentMethods).contains("session/prompt"))
        #expect(vm.pendingSessionTitle == nil)
    }

    /// Moving to another chat while the rename runs: its outcome is not
    /// that chat's news.
    @Test @MainActor func titleOutcomeIsDroppedAfterTheChatChanged() async throws {
        let home = try ChatResumeFallback146Tests.home(sessions: [("acp-s", "acp")])
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let started = RenameLog()
        vm.sessionRenameRunner = { _, id, title in
            started.add(id, title)
            let sem = DispatchSemaphore(value: 0)
            Task { for await _ in gate { break }; sem.signal() }
            sem.wait()
            return ("boom", 1)
        }
        let ch = Scripted(behavior: .happy(sessionId: "acp-s"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }
        vm.resumeSession("acp-s")
        #expect(await Self.waitReady(vm))
        #expect(await ChatViewModelStartLifecycleTests.waitUntil {
            vm.richChatViewModel.currentSession?.id == "acp-s"
        })

        vm.sendText("/title Late")
        #expect(await ChatViewModelStartLifecycleTests.waitUntil { !started.all.isEmpty })
        // The user moves to a new chat before the rename answers.
        let other = Scripted(behavior: .happy(sessionId: "acp-other"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in other } }
        vm.startNewSession()
        #expect(await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
                && vm.richChatViewModel.sessionId == "acp-other"
        })
        vm.richChatViewModel.transientHint = nil
        gateCont.yield()
        gateCont.finish()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(vm.richChatViewModel.transientHint == nil,
                "the old chat's rename failure landed on the new chat: \(vm.richChatViewModel.transientHint ?? "")")
    }
}
