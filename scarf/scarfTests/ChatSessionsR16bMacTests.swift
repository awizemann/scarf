import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R16b (Hermes v0.21.5 audit follow-ups, t-25209c91) — the Mac halves:
///
/// - R14-3: deleting a compression-chain row deletes every segment, tip
///   first, from both the chat sidebar and the Sessions tab; a chat
///   attached to any segment is torn down.
/// - R14-2: the sidebar matches the live chat by lineage.
/// - R14-1: the note shown for a search hit the list doesn't include.
/// - R10 carry-overs: a second send during the autostart replay window is
///   held until the replay drained; a late rename failure only shows in its
///   own sheet.
/// - Bot Chat: a send after the ACP connection is gone re-resolves and
///   re-verifies the canonical binding instead of auto-starting blind.
@Suite struct ChatSessionsR16bMacTests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests

    private static let chain = ["chainRoot", "chainMid", "chainTip"]

    private static func row(_ id: String, lineage: [String] = []) -> HermesSession {
        HermesSession(
            id: id, source: "acp", userId: nil, model: nil, title: nil, parentSessionId: nil,
            startedAt: nil, endedAt: nil, endReason: nil, messageCount: 0, toolCallCount: 0,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
            estimatedCostUSD: nil, reasoningTokens: 0, actualCostUSD: nil, costStatus: nil,
            billingProvider: nil, lineageIds: lineage
        )
    }

    /// A chat attached (ready) to `sessionId` over a happy scripted channel.
    @MainActor
    private static func attachedChat(
        home: TempHermesHome, channel: Lifecycle.ScriptedACPChannel, sessionId: String
    ) async -> ChatViewModel {
        let vm = ChatViewModel(context: home.context)
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.startNewSession()
        let ready = await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.richChatViewModel.sessionId == sessionId
        }
        #expect(ready)
        return vm
    }

    // MARK: - R14-3 chain delete (chat sidebar)

    /// The chat is attached to the chain's ROOT (its ACP id after a mid-chat
    /// rotation) while the sidebar lists the chain under its tip. Deleting
    /// the row deletes all three segments, tip first, and tears the chat
    /// down. Pre-fix only the tip was deleted and the attached chat kept
    /// running against a conversation the user had deleted.
    @Test @MainActor func sidebarDeleteRemovesTheWholeChainAndTearsDownTheChat() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let ch = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "chainRoot"))
        let vm = await Self.attachedChat(home: home, channel: ch, sessionId: "chainRoot")
        let deletes = Lifecycle.DeleteRecorder()
        vm.sessionDeleteRunner = { _, id in deletes.record(id); return 0 }

        let chainRow = Self.row("chainTip", lineage: Self.chain)
        #expect(vm.isAttached(to: chainRow), "the tip row must match a chat attached to the root")
        #expect(!vm.isAttached(to: Self.row("other")))

        await vm.deleteConversation(chainRow)
        #expect(deletes.recorded == ["chainTip", "chainMid", "chainRoot"])
        let closed = await Lifecycle.waitUntil { await ch.closed }
        #expect(closed, "the chat attached to a deleted segment kept its client")
        #expect(vm.richChatViewModel.sessionId == nil)
    }

    /// A failure part-way stops the run (the root is never attempted) and
    /// says what happened.
    @Test @MainActor func sidebarChainDeleteStopsAtAFailureAndSaysSo() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let deletes = Lifecycle.DeleteRecorder()
        vm.sessionDeleteRunner = { _, id in deletes.record(id); return id == "chainMid" ? 1 : 0 }

        await vm.deleteConversation(Self.row("chainTip", lineage: Self.chain))
        #expect(deletes.recorded == ["chainTip", "chainMid"])
        #expect(vm.richChatViewModel.transientHint?.contains("1 of 3") == true)
    }

    /// An ordinary row still deletes exactly one session.
    @Test @MainActor func ordinaryRowDeletesOneSession() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let deletes = Lifecycle.DeleteRecorder()
        vm.sessionDeleteRunner = { _, id in deletes.record(id); return 0 }
        await vm.deleteConversation(Self.row("solo"))
        #expect(deletes.recorded == ["solo"])
    }

    // MARK: - R14-3 chain delete (Sessions tab)

    @Test @MainActor func sessionsTabDeleteRemovesTheWholeChain() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let svm = SessionsViewModel(context: home.context)
        let deletes = Lifecycle.DeleteRecorder()
        svm.sessionDeleteRunner = { _, id in deletes.record(id); return 0 }

        svm.beginDelete(Self.row("chainTip", lineage: Self.chain))
        #expect(svm.deleteSegmentCount == 3)
        svm.confirmDelete()
        await svm.inFlightDelete?.value
        #expect(deletes.recorded == ["chainTip", "chainMid", "chainRoot"])
        #expect(svm.deleteError == nil)
        #expect(svm.deleteLineageIds.isEmpty)

        // Partial failure: reported, not silent.
        let partial = Lifecycle.DeleteRecorder()
        svm.sessionDeleteRunner = { _, id in partial.record(id); return id == "chainMid" ? 2 : 0 }
        svm.beginDelete(Self.row("chainTip", lineage: Self.chain))
        svm.confirmDelete()
        await svm.inFlightDelete?.value
        #expect(partial.recorded == ["chainTip", "chainMid"])
        #expect(svm.deleteError?.contains("1 of 3") == true)

        // An ordinary session is one segment.
        svm.beginDelete(Self.row("solo"))
        #expect(svm.deleteSegmentCount == 1)
    }

    // MARK: - R14-1 search hits outside the list

    @Test func listingNoteExplainsWhyTheListOmitsTheSession() {
        #expect(SessionsViewModel.listingNote(isArchived: true, isListed: false)?.contains("Archived") == true)
        #expect(SessionsViewModel.listingNote(isArchived: false, isListed: false)?.contains("subagent") == true)
        // Listed but older than the loaded rows: nothing to explain.
        #expect(SessionsViewModel.listingNote(isArchived: false, isListed: true) == nil)
    }

    // MARK: - R10 carry-over: late rename failure

    /// A rename that fails after its sheet was replaced by another
    /// session's sheet must not show its error there.
    @Test @MainActor func renameFailureOnlyShowsInItsOwnSheet() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        vm.sessionRenameRunner = { _, _, _ in ("Error: nope", 1) }
        let ok = await vm.renameSession("sess-A", to: "New")
        #expect(!ok)
        #expect(vm.renameError(for: "sess-A") != nil)
        #expect(vm.renameError(for: "sess-B") == nil)
    }

    // MARK: - R10 carry-over: second send during the autostart replay

    /// `replayOnLoad`, but the `session/load` replay and response are held
    /// until `releaseLoad()` — so a second send can land deterministically
    /// while autostart's client is installed and its replay not handled.
    actor GatedReplayChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private var pendingLoad: (id: Int, sessionId: String)?
        private(set) var closed = false
        private(set) var sentMethods: [String] = []
        private(set) var promptTexts: [String] = []
        var diagnosticID: String? { "gated-replay-channel" }

        init() {
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
            if method == "session/prompt",
               let prompt = (obj["params"] as? [String: Any])?["prompt"] as? [[String: Any]] {
                promptTexts.append(prompt.compactMap { $0["text"] as? String }.joined())
            }
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/load":
                let sid = (obj["params"] as? [String: Any])?["sessionId"] as? String ?? "s"
                pendingLoad = (id, sid)
            case "session/prompt":
                break
            default:
                reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        func releaseLoad() {
            guard let load = pendingLoad else { return }
            pendingLoad = nil
            for update in Lifecycle.ScriptedACPChannel.replayUpdates {
                reply(["jsonrpc": "2.0", "method": "session/update",
                       "params": ["sessionId": load.sessionId, "update": update] as [String: Any]])
            }
            reply(["jsonrpc": "2.0", "id": load.id,
                   "result": ["sessionId": load.sessionId, "modes": ["currentModeId": "default"]]])
        }

        var hasPendingLoad: Bool { pendingLoad != nil }

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

    /// Pre-fix the second send went straight out: `markPromptSent` opened
    /// the replay gate while the load's replay was still streaming, and the
    /// old history painted as new content (and the prompt raced the load).
    @Test @MainActor func secondSendDuringAutostartWaitsForTheReplayToDrain() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = GatedReplayChannel()
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }
        // After an exhausted reconnect: a session id, no client.
        vm.richChatViewModel.setSessionId("sess-old")

        vm.sendText("first")
        let loading = await Lifecycle.waitUntil { await ch.hasPendingLoad }
        #expect(loading)
        vm.sendText("second") // the client is installed; its load is not done
        #expect(await ch.sentMethods.contains("session/prompt") == false,
                "the second send went out before the load finished")

        await ch.releaseLoad()
        let bothSent = await Lifecycle.waitUntil {
            await ch.sentMethods.filter { $0 == "session/prompt" }.count == 2
        }
        #expect(bothSent)
        #expect(await ch.promptTexts == ["first", "second"])
        try? await Task.sleep(nanoseconds: 300_000_000)
        let rich = vm.richChatViewModel
        let leaked = rich.messages.filter {
            $0.content.contains("REPLAYED")
                || ($0.reasoning ?? "").contains("REPLAYED")
                || $0.toolCalls.contains { $0.callId == "replayed-tool-1" }
        }
        #expect(leaked.isEmpty, "load replay painted as new content: \(leaked.map(\.content))")
        #expect(rich.messages.filter(\.isUser).map(\.content) == ["first", "second"])
    }

    // MARK: - Bot Chat: no blind autostart

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    private static func configuredBotHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-r16b-bot-\(UUID().uuidString)")
        let profileHome = home.appendingPathComponent("profiles/scout")
        try FileManager.default.createDirectory(at: profileHome, withIntermediateDirectories: true)
        let config = "model:\n  default: anthropic/claude-x\n  provider: anthropic\n"
        try config.write(to: home.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try config.write(to: profileHome.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        return home
    }

    /// The live ACP Bot Chat lost its client (reconnect exhausted). The next
    /// send used to auto-start: `session/load` of the bot's id, and on
    /// failure `session/new` + the prompt — into a stray session nothing
    /// verified. Now it re-resolves the canonical chat, resumes it, and the
    /// verifier refuses the fallback before anything is sent.
    @Test @MainActor func sendWithNoClientReverifiesTheBotChatInsteadOfAutostarting() async throws {
        let home = try Self.configuredBotHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lookups = Box<Int>()
        let channels = Box<Lifecycle.ScriptedACPChannel>()
        let vm = BotConversationViewModel(
            profileName: "scout",
            context: .local(home: home),
            locator: { _ in
                lookups.append(1)
                return HermesDataService.CanonicalBotChat(registryId: "bot-chat-1", liveId: "bot-chat-1", liveSource: "acp")
            },
            creator: { _, _, _ in nil },
            acpClientMaker: { ctx, _, _ in
                // First process restores the Bot Chat; later ones can't.
                let ch = channels.all.isEmpty
                    ? Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "bot-chat-1"))
                    : Lifecycle.ScriptedACPChannel(behavior: .loadNotRestorable(sessionId: "stray"))
                channels.append(ch)
                return ACPClient(context: ctx) { _ in ch }
            }
        )
        vm.open()
        let live = await Lifecycle.waitUntil {
            vm.phase == .live && vm.chat.richChatViewModel.sessionId == "bot-chat-1" && vm.chat.isACPConnected
        }
        #expect(live)
        #expect(vm.chat.autoStartInterceptor != nil)

        vm.chat.stopACP() // the state an exhausted reconnect leaves: no client
        let down = await Lifecycle.waitUntil { !vm.chat.isACPConnected }
        #expect(down)

        vm.chat.sendText("hello bot")
        let failed = await Lifecycle.waitUntil(timeoutSeconds: 15) {
            if case .failed = vm.phase { return true }
            return false
        }
        #expect(failed, "expected the verifier to refuse the fallback session (phase \(vm.phase))")
        // R17: the refused message is kept and shown, not dropped.
        #expect(vm.unsentMessage == "hello bot")
        #expect(lookups.all.count == 2, "the send did not re-resolve the canonical Bot Chat")
        for ch in channels.all {
            #expect(await ch.sentMethods.contains("session/prompt") == false,
                    "a prompt was sent into a session that isn't the Bot Chat")
        }
    }

    /// Same, when the Bot Chat is still restorable: the send goes out after
    /// the binding is re-verified.
    @Test @MainActor func sendWithNoClientReachesTheReverifiedBotChat() async throws {
        let home = try Self.configuredBotHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lookups = Box<Int>()
        let channels = Box<Lifecycle.ScriptedACPChannel>()
        let vm = BotConversationViewModel(
            profileName: "scout",
            context: .local(home: home),
            locator: { _ in
                lookups.append(1)
                return HermesDataService.CanonicalBotChat(registryId: "bot-chat-1", liveId: "bot-chat-1", liveSource: "acp")
            },
            creator: { _, _, _ in nil },
            acpClientMaker: { ctx, _, _ in
                let ch = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "bot-chat-1"))
                channels.append(ch)
                return ACPClient(context: ctx) { _ in ch }
            }
        )
        vm.open()
        let live = await Lifecycle.waitUntil {
            vm.phase == .live && vm.chat.richChatViewModel.sessionId == "bot-chat-1" && vm.chat.isACPConnected
        }
        #expect(live)
        vm.chat.stopACP()
        _ = await Lifecycle.waitUntil { !vm.chat.isACPConnected }

        vm.chat.sendText("hello bot")
        let sent = await Lifecycle.waitUntil(timeoutSeconds: 15) {
            guard let last = channels.all.last else { return false }
            return await last.sentMethods.contains("session/prompt")
        }
        #expect(sent)
        #expect(lookups.all.count == 2)
        #expect(vm.phase == .live)
        #expect(await channels.all.last?.sentMethods.contains("session/new") == false)
    }
}
