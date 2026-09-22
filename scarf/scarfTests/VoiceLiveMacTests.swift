import Testing
import Foundation
import Observation
import ScarfCore
@testable import scarf

/// The macOS Live Voice UI (P5a, t-8c80d256): the readiness gate as the chat
/// reads it, the chat's `VoiceTurnHost` conformance over a scripted ACP
/// channel, the teardown paths, and the panel copy.
@Suite struct VoiceLiveMacTests {

    // MARK: - Fakes

    /// Records what the controller and chat ask of an engine.
    @MainActor
    @Observable
    final class FakeEngine: VoiceConversationEngine {
        var phase: VoiceConversationPhase = .idle
        var captions: [VoiceCaption] = []
        var micLevel: Double = 0
        var isMuted = false
        var elapsedSeconds: TimeInterval = 0
        var approximateCostUSD: Double = 0
        var notice: VoiceSessionNotice?

        var starts = 0
        var ends: [VoiceSessionEndReason] = []
        var immediateEnds: [VoiceSessionEndReason] = []

        func start() async {
            starts += 1
            phase = .connecting
        }
        func end(reason: VoiceSessionEndReason) {
            ends.append(reason)
            if phase.isActive { phase = .ending }
        }
        func endImmediately(reason: VoiceSessionEndReason) {
            immediateEnds.append(reason)
            if phase.isActive { phase = .ended(reason) }
        }
        func toggleMute() { isMuted.toggle() }
    }

    /// ACP channel that answers session setup, holds `session/prompt` until
    /// a `session/cancel` arrives (then answers the held prompt with
    /// `stopReason: cancelled`, as Hermes does), and records every request.
    actor VoiceScriptedChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let sessionId: String
        private(set) var sentMethods: [String] = []
        private(set) var promptPayloads: [[[String: Any]]] = []
        private var heldPromptIds: [Int] = []
        /// When set, a `session/cancel` doesn't answer the held prompts
        /// until `releaseHeld()` (a Hermes turn slow to wind down).
        var holdPromptsAfterCancel = false

        func setHoldPromptsAfterCancel(_ hold: Bool) { holdPromptsAfterCancel = hold }

        /// Answer every held prompt with `stopReason: cancelled`.
        func releaseHeld() {
            for held in heldPromptIds {
                reply(["jsonrpc": "2.0", "id": held, "result": ["stopReason": "cancelled"]])
            }
            heldPromptIds = []
        }

        var diagnosticID: String? { "voice-scripted-channel" }

        init(sessionId: String) {
            self.sessionId = sessionId
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
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/new", "session/load":
                reply(["jsonrpc": "2.0", "id": id,
                       "result": ["sessionId": sessionId, "modes": ["currentModeId": "default"]]])
            case "session/prompt":
                let params = obj["params"] as? [String: Any]
                promptPayloads.append(params?["prompt"] as? [[String: Any]] ?? [])
                if heldPromptIds.isEmpty {
                    heldPromptIds.append(id)
                } else {
                    // As Hermes does (`_claim_turn_or_queue`,
                    // acp_adapter/server.py:696-715): a prompt that arrives
                    // while a turn runs is queued and answered AT ONCE; the
                    // running prompt returns later.
                    reply(["jsonrpc": "2.0", "method": "session/update", "params": [
                        "sessionId": sessionId,
                        "update": ["sessionUpdate": "agent_message_chunk",
                                   "content": ["type": "text", "text": "Queued for the next turn. (1 queued)"]],
                    ]])
                    reply(["jsonrpc": "2.0", "id": id, "result": ["stopReason": "end_turn"]])
                }
            case "session/cancel":
                if !holdPromptsAfterCancel { releaseHeld() }
                reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
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
            incomingCont.finish()
            stderrCont.finish()
        }
    }

    // MARK: - Helpers

    /// A GPT-Live host, for the tests that exercise that engine's path.
    static let gptLiveCapabilities = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")

    /// Start Live Voice as a gpt-live host would: the chat reads the engine
    /// off the readiness verdict, so both halves have to say gpt-live.
    @MainActor
    static func startGPTLive(_ vm: ChatViewModel) {
        vm.voiceChatModeRaw = "gpt-live"
        vm.startVoiceLive(capabilities: gptLiveCapabilities)
    }

    @MainActor
    static func waitUntil(timeoutSeconds: Double = 5, _ condition: @MainActor @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    static func configuredHome(voiceChatMode: String? = nil) throws -> TempHermesHome {
        let home = try TempHermesHome()
        var yaml = "model:\n  default: test-model\n  provider: anthropic\n"
        if let voiceChatMode { yaml += "voice:\n  voice_chat_mode: \(voiceChatMode)\n" }
        try yaml.write(toFile: home.path + "/config.yaml", atomically: true, encoding: .utf8)
        return home
    }

    /// A consent store over a throwaway defaults suite (never the real
    /// one). `accepted` pre-records the OpenAI consent, so the lifecycle
    /// tests start sessions without the sheet.
    @MainActor
    static func consentStore(accepted: Bool = true) -> VoiceDataConsentStore {
        let suite = "scarf.tests.voiceLiveMac.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = VoiceDataConsentStore(defaults: defaults)
        if accepted { store.recordConsent(to: .openAI) }
        return store
    }

    /// A chat VM whose Live Voice controller builds `FakeEngine`s. Each test
    /// gets its own session registry, so no test sees another's session.
    @MainActor
    static func chat(
        context: ServerContext,
        registry: VoiceLiveSessionRegistry? = nil,
        consent: VoiceDataConsentStore? = nil,
        engines: @escaping (FakeEngine) -> Void = { _ in }
    ) -> ChatViewModel {
        let registry = registry ?? VoiceLiveSessionRegistry()
        let controller = VoiceLiveController(makeSession: { _, _ in
            let engine = FakeEngine()
            engines(engine)
            return VoiceLiveController.Session(engine: engine, bridge: nil)
        }, registry: registry, consent: consent ?? consentStore())
        return ChatViewModel(context: context, voiceLive: controller)
    }

    /// A controller over one fake engine.
    @MainActor
    static func controller(
        _ engine: FakeEngine,
        registry: VoiceLiveSessionRegistry? = nil,
        externalRecipient: VoiceDataRecipient? = .openAI,
        consent: VoiceDataConsentStore? = nil
    ) -> VoiceLiveController {
        VoiceLiveController(
            makeSession: { _, _ in .init(engine: engine, bridge: nil) },
            externalRecipient: externalRecipient,
            registry: registry ?? VoiceLiveSessionRegistry(),
            consent: consent ?? consentStore()
        )
    }

    /// A chat attached to a live scripted ACP session.
    @MainActor
    static func connectedChat(
        home: TempHermesHome,
        channel: VoiceScriptedChannel,
        consent: VoiceDataConsentStore? = nil,
        engines: @escaping (FakeEngine) -> Void = { _ in }
    ) async -> ChatViewModel {
        let vm = chat(context: home.context, consent: consent, engines: engines)
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.startNewSession()
        _ = await waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.ready }
        return vm
    }

    // MARK: - Readiness gate

    @Test @MainActor func gateSendsEachHostToItsEngine() {
        let vm = ChatViewModel(context: .local)
        let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
        let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.7.20)")

        // Config not read yet: Hermes's chained default, which since P7 has
        // an engine of its own, so the button shows.
        #expect(vm.voiceLiveAvailability(capabilities: v0213) == .chainedReady)
        vm.voiceChatModeRaw = "chained"
        #expect(vm.voiceLiveAvailability(capabilities: v0213) == .chainedReady)
        // Hermes's own alternate spelling counts.
        vm.voiceChatModeRaw = "gpt_live"
        #expect(vm.voiceLiveAvailability(capabilities: v0213) == .ready)
        // Asking for gpt-live on a host too old for it falls back to
        // chained, exactly as Hermes's own desktop does.
        #expect(vm.voiceLiveAvailability(capabilities: v0212) == .chainedReady)
        // Below the speech floor nothing shows, whatever the config says (C1).
        #expect(vm.voiceLiveAvailability(capabilities: v0200) == .hidden(.hermesTooOld))
        #expect(vm.voiceLiveAvailability(capabilities: .empty) == .hidden(.hermesTooOld))
    }

    @Test @MainActor func configRefreshReadsTheVoiceChatMode() async throws {
        let home = try Self.configuredHome(voiceChatMode: "gpt-live")
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        #expect(vm.voiceChatModeRaw == nil)
        vm.refreshConfigDiagnostics()
        let read = await Self.waitUntil { vm.voiceChatModeRaw == "gpt-live" }
        #expect(read)
    }

    // MARK: - VoiceTurnHost

    @Test @MainActor func noSessionMeansNoVoiceTurns() async {
        let vm = Self.chat(context: .local)
        #expect(!vm.canHostVoiceTurns)
        await #expect(throws: ChatViewModel.VoiceTurnSubmitError.noSession) {
            try await vm.submitVoiceTurn(VoiceTurnRequest(id: "d1", prompt: "hello", context: "User: hello"))
        }
        #expect(vm.richChatViewModel.messages.isEmpty)
        // And starting a session is refused, so no engine is built.
        Self.startGPTLive(vm)
        #expect(vm.voiceLive.engine == nil)
    }

    @Test @MainActor func submitShowsTheSpokenWordsAndSendsTheNoteBeforeTheText() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-v")
        let vm = await Self.connectedChat(home: home, channel: channel)
        #expect(vm.canHostVoiceTurns)

        let request = VoiceTurnRequest(id: "d1", prompt: "the dentist one, thursday not friday", context: "User: move the dentist")
        try await vm.submitVoiceTurn(request)

        // The bubble is the spoken words, and the turn is running.
        #expect(vm.richChatViewModel.messages.last?.isUser == true)
        #expect(vm.richChatViewModel.messages.last?.content == request.prompt)
        #expect(vm.isVoiceTurnBusy)
        #expect(vm.voiceTurnReply(for: "d1") == nil)     // no assistant text yet
        #expect(vm.voiceTurnReply(for: "other") == nil)

        let sent = await Self.waitUntil { await !channel.promptPayloads.isEmpty }
        #expect(sent)
        let blocks = await channel.promptPayloads.first ?? []
        #expect(blocks.count == 2)
        #expect(blocks.first?["type"] as? String == "resource")
        #expect(blocks.last?["type"] as? String == "text")
        #expect(blocks.last?["text"] as? String == request.prompt)

        // Streamed reply text is found by the request id.
        vm.richChatViewModel.handleACPEvent(.messageChunk(sessionId: "sess-v", text: "Moved it to Thursday. "))
        let replied = await Self.waitUntil { vm.voiceTurnReply(for: "d1") != nil }
        #expect(replied)
        #expect(vm.voiceTurnReply(for: "d1")?.isStreaming == true)
    }

    /// P4 follow-up (464c8ca2): a turn that superseded a cancelled one goes
    /// text-only, so Hermes consumes the interrupted prompt.
    @Test @MainActor func supersedingTurnIsSentTextOnly() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-x")
        let vm = await Self.connectedChat(home: home, channel: channel)
        try await vm.submitVoiceTurn(VoiceTurnRequest(
            id: "d2", prompt: "no, friday", context: "User: no, friday", supersedesCancelledTurn: true
        ))
        let sent = await Self.waitUntil { await !channel.promptPayloads.isEmpty }
        #expect(sent)
        let blocks = await channel.promptPayloads.first ?? []
        #expect(blocks.count == 1)
        #expect(blocks.first?["type"] as? String == "text")
        #expect(blocks.first?["text"] as? String == "no, friday")
    }

    @Test @MainActor func cancelReturnsOnlyAfterTheRunningTurnReturned() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-c")
        let vm = await Self.connectedChat(home: home, channel: channel)

        try await vm.submitVoiceTurn(VoiceTurnRequest(id: "d1", prompt: "a long spoken request", context: ""))
        let inFlight = await Self.waitUntil { await channel.sentMethods.contains("session/prompt") }
        #expect(inFlight)
        #expect(vm.isVoiceTurnBusy)

        await vm.cancelActiveVoiceTurn()

        // By the time cancel returns, Hermes was asked to cancel AND the
        // turn's sendPrompt came back (promptComplete synthesized), so a
        // superseding voice prompt won't be queued note-less.
        #expect(await channel.sentMethods.contains("session/cancel"))
        #expect(!vm.isVoiceTurnBusy)
        #expect(vm.acpStatus == ChatViewModel.ACPPhase.ready)
    }

    @Test @MainActor func cancelWithNothingRunningSendsNoCancel() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-i")
        let vm = await Self.connectedChat(home: home, channel: channel)
        await vm.cancelActiveVoiceTurn()
        #expect(await !channel.sentMethods.contains("session/cancel"))
    }

    @Test @MainActor func toolNameAndSeedTurnsComeFromTheTranscript() async {
        let vm = Self.chat(context: .local)
        let rich = vm.richChatViewModel
        rich.setSessionId("s")
        rich.addUserMessage(text: "  check thursday  ")
        rich.handleACPEvent(.toolCallStart(sessionId: "s", call: ACPToolCallEvent(
            toolCallId: "t1", title: "calendar_search: thursday", kind: "search",
            status: "in_progress", content: "", rawInput: nil
        )))
        #expect(vm.activeVoiceToolName == "calendar_search")
        rich.handleACPEvent(.messageChunk(sessionId: "s", text: "Dentist at 3."))
        rich.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn", inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0
        )))
        _ = await Self.waitUntil { rich.messages.contains { $0.isAssistant && !$0.content.isEmpty } }

        let turns = vm.voiceSeedTurns()
        #expect(turns.first == VoiceLiveText.SeedTurn(role: .user, text: "check thursday"))
        #expect(turns.last == VoiceLiveText.SeedTurn(role: .assistant, text: "Dentist at 3."))
        #expect(!turns.contains { $0.text.isEmpty })
    }

    // MARK: - Teardown

    @Test @MainActor func sessionChangesEndTheVoiceSessionImmediately() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-t")
        var engines: [FakeEngine] = []
        let vm = await Self.connectedChat(home: home, channel: channel) { engines.append($0) }

        Self.startGPTLive(vm)
        let started = await Self.waitUntil { engines.first?.starts == 1 }
        #expect(started)
        #expect(vm.voiceLive.isSessionActive)
        // A second start while one runs is a no-op.
        Self.startGPTLive(vm)
        #expect(engines.count == 1)

        vm.startNewSession()   // sidebar "New Chat"
        #expect(engines.first?.immediateEnds.first == .userEnded)
        #expect(!vm.voiceLive.isSessionActive)
    }

    @Test @MainActor func stopACPEndsTheVoiceSession() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-s")
        var engines: [FakeEngine] = []
        let vm = await Self.connectedChat(home: home, channel: channel) { engines.append($0) }
        Self.startGPTLive(vm)
        _ = await Self.waitUntil { engines.first?.phase == .connecting }

        vm.stopACP()
        #expect(engines.first?.immediateEnds == [.userEnded])
    }

    @Test @MainActor func controllerEndIsGracefulAndDismissClears() async {
        let engine = FakeEngine()
        let controller = Self.controller(engine)
        let host = ChatViewModel(context: .local)
        controller.start(context: .local, host: host)
        _ = await Self.waitUntil { engine.starts == 1 }

        controller.end()
        #expect(engine.ends == [.userEnded])
        #expect(engine.immediateEnds.isEmpty)
        #expect(controller.engine != nil)          // panel stays up for the result

        controller.dismiss()
        #expect(controller.engine == nil)
        #expect(controller.bridge == nil)
        // Nothing running: teardown calls are harmless.
        controller.endImmediately()
    }

    // MARK: - F2a (t-dd450d3a): one session app-wide

    @Test @MainActor func aSecondWindowCantStartWhileOneHoldsTheSession() async {
        let registry = VoiceLiveSessionRegistry()
        let engineA = FakeEngine()
        let engineB = FakeEngine()
        let windowA = Self.controller(engineA, registry: registry)
        let windowB = Self.controller(engineB, registry: registry)
        let host = ChatViewModel(context: .local)

        windowA.start(context: .local, host: host)
        // Even before A's start task ran (engine still idle), B is refused.
        #expect(windowB.isBlockedByAnotherWindow)
        windowB.start(context: .local, host: host)
        #expect(windowB.engine == nil)

        _ = await Self.waitUntil { engineA.starts == 1 }
        #expect(registry.isAnySessionActive)
        windowB.start(context: .local, host: host)
        #expect(windowB.engine == nil)
        #expect(engineB.starts == 0)
        // A keeps its session: refusing never cuts off the other window.
        #expect(windowA.isSessionActive)
        #expect(!windowA.isBlockedByAnotherWindow)

        // Once A's session ends, B can start.
        windowA.endImmediately()
        #expect(!windowB.isBlockedByAnotherWindow)
        #expect(!registry.isAnySessionActive)
        windowB.start(context: .local, host: host)
        let started = await Self.waitUntil { engineB.starts == 1 }
        #expect(started)
        #expect(windowA.isBlockedByAnotherWindow)
    }

    /// The consent sheet can sit open for minutes. If another
    /// window claims the app's one session meanwhile, accepting consent
    /// used to hit `start`'s `guard !isBlockedByAnotherWindow` and return
    /// in silence — the user pressed Continue and nothing whatsoever
    /// happened. The refusal must be surfaced.
    @Test @MainActor func acceptingConsentAfterAnotherWindowTookTheSessionSaysSo() async {
        let registry = VoiceLiveSessionRegistry()
        let consent = Self.consentStore(accepted: false)
        let engineA = FakeEngine()
        let engineB = FakeEngine()
        let windowA = Self.controller(engineA, registry: registry, consent: consent)
        let windowB = Self.controller(engineB, registry: registry, consent: consent)
        let host = ChatViewModel(context: .local)

        // A asks first and stops on the consent sheet.
        windowA.start(context: .local, host: host)
        #expect(windowA.pendingConsent == .openAI)
        #expect(windowA.engine == nil)

        // B takes the session while A's sheet is still up (B answers its
        // own consent sheet first).
        windowB.start(context: .local, host: host)
        windowB.acceptConsent()
        windowB.start(context: .local, host: host)
        let bStarted = await Self.waitUntil { engineB.starts == 1 }
        #expect(bStarted)

        // A now accepts: nothing starts, and A says why.
        windowA.acceptConsent()
        windowA.start(context: .local, host: host)
        #expect(windowA.engine == nil)
        #expect(engineA.starts == 0)
        #expect(windowA.pendingConsent == nil)
        #expect(windowA.startRefusal == .blockedByAnotherWindow)
        // Read once, then gone.
        #expect(windowA.consumeStartRefusal() == .blockedByAnotherWindow)
        #expect(windowA.startRefusal == nil)
    }

    /// Leaving Chat must drop the engine and its (dead) web view,
    /// not just end the session — otherwise the WKWebView bridge survives
    /// the trip out and back, and the panel re-renders a stale "session
    /// ended" strip for a session the user already left.
    @Test @MainActor func leavingChatDropsTheEngineAndItsWebView() async {
        let engine = FakeEngine()
        let controller = Self.controller(engine)
        let vm = ChatViewModel(context: .local, voiceLive: controller)
        controller.start(context: .local, host: vm)
        _ = await Self.waitUntil { engine.starts == 1 }

        vm.leaveChatVoiceLive()

        #expect(engine.immediateEnds == [.userEnded])
        #expect(controller.engine == nil, "the engine survived leaving Chat")
        #expect(controller.bridge == nil)
        #expect(controller.endNote == nil)
    }

    // MARK: - F2a: an end right after start

    @Test @MainActor func endBeforeTheStartTaskRanCancelsTheStart() async {
        let engine = FakeEngine()
        let controller = Self.controller(engine)
        controller.start(context: .local, host: ChatViewModel(context: .local))
        #expect(controller.holdsSession)
        controller.endImmediately()
        #expect(!controller.holdsSession)
        #expect(controller.engine == nil)
        // Give a leaked start task every chance to run.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(engine.starts == 0)
    }

    @Test @MainActor func gracefulEndBeforeTheStartTaskRanCancelsTheStart() async {
        let engine = FakeEngine()
        let controller = Self.controller(engine)
        controller.start(context: .local, host: ChatViewModel(context: .local))
        controller.end()
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(engine.starts == 0)
        #expect(!controller.holdsSession)
    }

    // MARK: - F2a: the ACP connection dies

    @Test @MainActor func aDeadACPConnectionEndsTheVoiceSession() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-d")
        var engines: [FakeEngine] = []
        let vm = await Self.connectedChat(home: home, channel: channel) { engines.append($0) }
        defer { vm.stopACP() }
        Self.startGPTLive(vm)
        _ = await Self.waitUntil { engines.first?.phase == .connecting }

        // The event stream ends → handleConnectionDied (not stopACP).
        await channel.close()
        let ended = await Self.waitUntil { engines.first?.immediateEnds == [.userEnded] }
        #expect(ended)
        #expect(vm.voiceLive.endNote == .hermesConnectionLost)
        #expect(VoiceLivePresentation.endedMessage(.userEnded, endNote: vm.voiceLive.endNote) != nil)
    }

    // MARK: - F2a: turn identity

    /// Hermes answers a prompt sent mid-turn at once and runs it inside the
    /// running turn, whose `sendPrompt` returns last. The newer return
    /// must not end the older turn: it is still in flight for `stopACP`.
    @Test @MainActor func aQueuedTurnsReturnDoesNotEndTheRunningTurn() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-q")
        let vm = await Self.connectedChat(home: home, channel: channel)

        vm.sendText("first, a long typed turn")
        _ = await Self.waitUntil { await channel.promptPayloads.count == 1 }
        vm.sendText("second, typed while it runs")
        let both = await Self.waitUntil { await channel.promptPayloads.count == 2 }
        #expect(both)
        // The queued turn has returned by now; the chat is still working.
        let clearedEarly = await Self.waitUntil(timeoutSeconds: 1) { vm.acpStatus == ChatViewModel.ACPPhase.ready }
        #expect(!clearedEarly, "the queued turn's return marked the chat ready while the first turn still ran")
        #expect(vm.richChatViewModel.isAgentWorking)

        // Tearing down still cancels the running turn on Hermes (S4).
        vm.stopACP()
        let cancelled = await Self.waitUntil { await channel.sentMethods.contains("session/cancel") }
        #expect(cancelled, "stopACP lost the running turn and sent no session/cancel")
    }

    /// A voice cancel waits for the turn Hermes is actually running, not the
    /// last prompt Scarf launched (which Hermes answered at once).
    @Test @MainActor func voiceCancelWaitsForTheRunningTurnNotTheLastLaunched() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-w")
        let vm = await Self.connectedChat(home: home, channel: channel)

        try await vm.submitVoiceTurn(VoiceTurnRequest(id: "d1", prompt: "first spoken request", context: ""))
        _ = await Self.waitUntil { await channel.promptPayloads.count == 1 }
        try await vm.submitVoiceTurn(VoiceTurnRequest(id: "d2", prompt: "second spoken request", context: ""))
        _ = await Self.waitUntil { await channel.promptPayloads.count == 2 }
        await channel.setHoldPromptsAfterCancel(true)

        var cancelReturned = false
        let cancel = Task { @MainActor in
            await vm.cancelActiveVoiceTurn()
            cancelReturned = true
        }
        let sentCancel = await Self.waitUntil { await channel.sentMethods.contains("session/cancel") }
        #expect(sentCancel)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(!cancelReturned, "cancel returned while the first voice turn was still running")

        await channel.releaseHeld()
        await cancel.value
        #expect(cancelReturned)
        #expect(!vm.isVoiceTurnBusy)
    }

    // MARK: - F2a: voice never cancels a typed turn

    @Test @MainActor func aTypedTurnIsNeverCancelledByVoice() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-b")
        let vm = await Self.connectedChat(home: home, channel: channel)

        vm.sendText("a long typed turn")
        _ = await Self.waitUntil { await channel.promptPayloads.count == 1 }
        // The engine cancels whatever reads busy: a typed turn must not.
        #expect(!vm.isVoiceTurnBusy)
        #expect(vm.isBusyWithNonVoiceTurn)

        await vm.cancelActiveVoiceTurn()
        let request = VoiceTurnRequest(id: "d9", prompt: "what's on thursday", context: "")
        try await vm.submitVoiceTurn(request)

        #expect(await !channel.sentMethods.contains("session/cancel"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await channel.promptPayloads.count == 1, "the spoken request was sent while the typed turn ran")
        #expect(!vm.richChatViewModel.messages.contains { $0.isUser && $0.content == request.prompt })
        // The voice says so instead, in full, and the composer shows why.
        #expect(vm.voiceTurnReply(for: "d9") == VoiceTurnReply(text: ChatViewModel.voiceBusyReply, isStreaming: false))
        #expect(vm.richChatViewModel.transientHint != nil)
    }

    /// A typed prompt queued inside a running VOICE turn makes Hermes busy
    /// with a typed request too: the voice doesn't cancel that run.
    @Test @MainActor func aTypedPromptQueuedBehindAVoiceTurnIsNotCancelled() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-m")
        let vm = await Self.connectedChat(home: home, channel: channel)

        try await vm.submitVoiceTurn(VoiceTurnRequest(id: "d1", prompt: "a spoken request", context: ""))
        _ = await Self.waitUntil { await channel.promptPayloads.count == 1 }
        #expect(vm.isVoiceTurnBusy)
        vm.sendText("typed while the voice turn runs")
        _ = await Self.waitUntil { await channel.promptPayloads.count == 2 }
        try? await Task.sleep(nanoseconds: 100_000_000)   // the queued prompt returns

        #expect(!vm.isVoiceTurnBusy)
        #expect(vm.isBusyWithNonVoiceTurn)
        await vm.cancelActiveVoiceTurn()
        #expect(await !channel.sentMethods.contains("session/cancel"))
        vm.stopACP()
    }

    // MARK: - F2a: the message speaker button

    @Test func speakerButtonStandsDownDuringLiveVoice() {
        let idle = SpeakMessageButtonState(isPlaying: false, isLoading: false, liveVoiceActive: false)
        #expect(idle.isEnabled)
        let duringVoice = SpeakMessageButtonState(isPlaying: false, isLoading: false, liveVoiceActive: true)
        #expect(!duringVoice.isEnabled)
        #expect(!duringVoice.accessibilityValue.isEmpty)
        // Whatever is playing can always be stopped.
        #expect(SpeakMessageButtonState(isPlaying: true, isLoading: false, liveVoiceActive: true).isEnabled)
    }

    @Test func speakerButtonReportsHermesVoiceSynthesis() {
        let loading = SpeakMessageButtonState(isPlaying: true, isLoading: true, liveVoiceActive: false)
        #expect(loading.isEnabled)
        #expect(loading.accessibilityValue != SpeakMessageButtonState(isPlaying: true, isLoading: false, liveVoiceActive: false).accessibilityValue)
        #expect(loading.help != SpeakMessageButtonState(isPlaying: true, isLoading: false, liveVoiceActive: false).help)
    }

    @Test @MainActor func registryReportsASessionForTheSpeakerButtons() async {
        let registry = VoiceLiveSessionRegistry()
        let engine = FakeEngine()
        let controller = Self.controller(engine, registry: registry)
        #expect(!registry.isAnySessionActive)
        controller.start(context: .local, host: ChatViewModel(context: .local))
        #expect(registry.isAnySessionActive)
        controller.dismiss()
        #expect(!registry.isAnySessionActive)
    }

    // MARK: - F2a: VoiceOver announcements

    @Test func phaseChangesAreAnnouncedButNotEverySpeakingFlip() {
        #expect(VoiceLivePresentation.announcement(from: .idle, to: .connecting) != nil)
        #expect(VoiceLivePresentation.announcement(from: .connecting, to: .listening) != nil)
        #expect(VoiceLivePresentation.announcement(from: .listening, to: .speaking) == nil)
        #expect(VoiceLivePresentation.announcement(from: .speaking, to: .listening) == nil)
        #expect(VoiceLivePresentation.announcement(from: .listening, to: .thinking) != nil)
        let failed = VoiceLivePresentation.announcement(from: .connecting, to: .failed(.microphoneDenied))
        #expect(failed == VoiceLivePresentation.failure(.microphoneDenied).message)
        let lost = VoiceLivePresentation.announcement(from: .listening, to: .ended(.userEnded), endNote: .hermesConnectionLost)
        #expect(lost?.contains(VoiceLivePresentation.endedMessage(.userEnded, endNote: .hermesConnectionLost) ?? "∅") == true)
        #expect(VoiceLivePresentation.announcement(from: .listening, to: .listening) == nil)
    }

    // MARK: - Panel copy

    @Test func everySetupHintFailureCarriesGuidance() {
        let setup: [VoiceSessionFailure] = [
            .host(.noKey), .host(.unsupported), .host(.interpreterNotFound(detail: "python3: not found")),
        ]
        for failure in setup {
            #expect(failure.setupHint)
            #expect(VoiceLivePresentation.failure(failure).guidance != nil, "\(failure)")
        }
        let noKey = VoiceLivePresentation.failure(.host(.noKey))
        #expect(noKey.guidance?.contains("OPENAI_API_KEY") == true)
        #expect(noKey.guidance?.contains("voice.gpt_live.api_key") == true)
    }

    @Test func failureCopyMapsTheActionableCases() {
        #expect(VoiceLivePresentation.failure(.microphoneDenied).offersMicrophoneSettings)
        #expect(!VoiceLivePresentation.failure(.connectionLost).offersMicrophoneSettings)
        let vendor = VoiceLivePresentation.failure(.host(.vendor(status: 500, detail: "upstream")))
        #expect(vendor.message.contains("500"))
    }

    /// F4: the vendor's (or host's) raw detail is logged, never shown. No
    /// field of the copy the panel renders may carry it.
    @Test func failureCopyNeverCarriesTheRawDetail() {
        let marker = "RAW-VENDOR-DETAIL"
        let failures: [VoiceSessionFailure] = [
            .host(.vendor(status: 500, detail: marker)), .host(.vendor(status: nil, detail: marker)),
            .host(.interpreterNotFound(detail: marker)), .host(.badRequest(detail: marker)),
            .host(.hostInternal(detail: marker)), .host(.malformedOutput(detail: marker)),
            .mediaUnavailable(detail: marker), .audioConnectFailed(detail: marker),
            .closedByVendor(reason: marker, usageSeconds: 12),
        ]
        for failure in failures {
            let copy = VoiceLivePresentation.failure(failure)
            let shown = Mirror(reflecting: copy).children.compactMap { child -> String? in
                if let text = child.value as? String { return text }
                if let text = child.value as? String? { return text }
                return nil
            }
            #expect(!shown.isEmpty)
            #expect(!shown.contains { $0.contains(marker) }, "\(failure) shows its raw detail")
        }
    }

    // MARK: - F4: consent before the first session

    @Test @MainActor func theFirstStartAsksForConsentAndStartsNothing() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let channel = VoiceScriptedChannel(sessionId: "sess-c1")
        var engines: [FakeEngine] = []
        let consent = Self.consentStore(accepted: false)
        let vm = await Self.connectedChat(home: home, channel: channel, consent: consent) { engines.append($0) }
        defer { vm.stopACP() }

        Self.startGPTLive(vm)
        #expect(vm.voiceLive.pendingConsent == .openAI)
        #expect(engines.isEmpty, "a session was built before consent")
        #expect(vm.voiceLive.engine == nil)
        #expect(!vm.voiceLive.holdsSession)

        // Continue: remembered, and the session starts.
        vm.acceptVoiceLiveConsent(capabilities: Self.gptLiveCapabilities)
        #expect(vm.voiceLive.pendingConsent == nil)
        #expect(consent.hasConsented(to: .openAI))
        let started = await Self.waitUntil { engines.first?.starts == 1 }
        #expect(started)
    }

    @Test @MainActor func cancelOnTheConsentStartsNothingAndAsksAgain() async {
        let engine = FakeEngine()
        let consent = Self.consentStore(accepted: false)
        let controller = Self.controller(engine, consent: consent)
        controller.start(context: .local, host: ChatViewModel(context: .local))
        #expect(controller.pendingConsent == .openAI)

        controller.declineConsent()
        #expect(controller.pendingConsent == nil)
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(engine.starts == 0)
        #expect(controller.engine == nil)
        #expect(!consent.hasConsented(to: .openAI))
        // Not remembered: the next start asks again.
        controller.start(context: .local, host: ChatViewModel(context: .local))
        #expect(controller.pendingConsent == .openAI)
        #expect(controller.engine == nil)
    }

    @Test @MainActor func consentIsRememberedUntilReset() async {
        let consent = Self.consentStore(accepted: false)
        let first = FakeEngine()
        let window = Self.controller(first, consent: consent)
        window.start(context: .local, host: ChatViewModel(context: .local))
        window.acceptConsent()

        // Another window (or a relaunch) over the same store: no sheet.
        let second = FakeEngine()
        let other = Self.controller(second, consent: consent)
        other.start(context: .local, host: ChatViewModel(context: .local))
        #expect(other.pendingConsent == nil)
        let started = await Self.waitUntil { second.starts == 1 }
        #expect(started)
        other.dismiss()

        // Settings › Reset: the next start asks again.
        consent.resetConsent(for: .openAI)
        let third = FakeEngine()
        let again = Self.controller(third, consent: consent)
        again.start(context: .local, host: ChatViewModel(context: .local))
        #expect(again.pendingConsent == .openAI)
        #expect(again.engine == nil)
    }

    /// Consent is per recipient: agreeing to OpenAI doesn't cover another.
    @Test @MainActor func consentIsPerRecipient() {
        let consent = Self.consentStore(accepted: true)
        let acme = VoiceDataRecipient(id: "acme", displayName: "Acme", disclosureVersion: 1)
        let controller = Self.controller(FakeEngine(), externalRecipient: acme, consent: consent)
        controller.start(context: .local, host: ChatViewModel(context: .local))
        #expect(controller.pendingConsent == acme)
        #expect(controller.engine == nil)
    }

    /// An engine that sends nothing to a third party starts without asking.
    @Test @MainActor func anEngineWithNoExternalRecipientNeverAsks() async {
        let engine = FakeEngine()
        let controller = Self.controller(engine, externalRecipient: nil, consent: Self.consentStore(accepted: false))
        controller.start(context: .local, host: ChatViewModel(context: .local))
        #expect(controller.pendingConsent == nil)
        let started = await Self.waitUntil { engine.starts == 1 }
        #expect(started)
    }

    /// Leaving the chat takes an unanswered consent sheet with it.
    @Test @MainActor func leavingTheChatDropsAPendingConsent() {
        let controller = Self.controller(FakeEngine(), consent: Self.consentStore(accepted: false))
        controller.start(context: .local, host: ChatViewModel(context: .local))
        controller.endImmediately()
        #expect(controller.pendingConsent == nil)
    }

    @Test func theConsentSaysWhatLeavesTheMac() {
        let points = VoiceLiveConsentCopy.points(.openAI).joined(separator: " ")
        #expect(points.contains("directly"))
        #expect(points.contains("network address"))
        #expect(points.contains("24"))
        #expect(points.contains("0.05"))
        #expect(points.contains("whole profile"))
        #expect(!points.contains("through the host"))
    }

    @Test func endedCopyExplainsTheAutomaticEnds() {
        #expect(VoiceLivePresentation.endedMessage(.userEnded) == nil)
        #expect(VoiceLivePresentation.endedMessage(.stopPhrase) != nil)
        #expect(VoiceLivePresentation.endedMessage(.idleTimeout)?.contains("3") == true)
    }

    @Test func readoutFormats() {
        #expect(VoiceLivePresentation.elapsed(65.9) == "1:05")
        #expect(VoiceLivePresentation.elapsed(0) == "0:00")
        #expect(VoiceLivePresentation.cost(0.05).contains("0.05"))
    }
}

/// The Mac binding for the FREE chained voice engine (P7b, t-7932eaee):
/// which engine the composer's one button mounts, what it asks the user
/// before starting, and the Settings section that explains the path.
///
/// Every fake here replaces real hardware: no microphone, no speech
/// recognizer and no synthesizer is ever touched.
@Suite struct ChainedVoiceMacTests {

    // MARK: - Fakes

    /// A `VoiceListener` that opens no microphone. `startError` makes
    /// `start()` throw, which is how a denied permission reaches the engine.
    @MainActor
    final class FakeListener: VoiceListener {
        let startError: VoiceListenerError?
        private(set) var starts = 0
        private(set) var stops = 0
        private var continuation: AsyncStream<VoiceListenerEvent>.Continuation?

        init(startError: VoiceListenerError? = nil) { self.startError = startError }

        func start() throws -> AsyncStream<VoiceListenerEvent> {
            starts += 1
            if let startError { throw startError }
            let (stream, continuation) = AsyncStream<VoiceListenerEvent>.makeStream()
            self.continuation = continuation
            return stream
        }

        func stop() {
            stops += 1
            continuation?.finish()
            continuation = nil
        }

        func setPaused(_ paused: Bool) {}

        /// Every playback transition the engine announced, in order.
        private(set) var playbackActive: [Bool] = []
        func setPlaybackActive(_ active: Bool) { playbackActive.append(active) }
    }

    /// A `VoiceSpeaker` that synthesizes nothing.
    @MainActor
    final class FakeSpeaker: VoiceSpeaker {
        private(set) var spoken: [String] = []
        private(set) var stops = 0
        var isSpeaking = false

        func speak(_ text: String) async throws { spoken.append(text) }
        func stop() { stops += 1 }
    }

    /// A permission verdict the test can flip BETWEEN starts, so one
    /// controller can run a session and then meet a refusal on the next
    /// start (the user revoked Speech Recognition in System Settings).
    @MainActor
    final class DenialBox {
        var denial: VoiceListenerError?
        init(_ denial: VoiceListenerError? = nil) { self.denial = denial }
    }

    /// A permission prompt the test holds open: `wait()` suspends the
    /// controller's start task exactly where the real TCC prompt does, and
    /// `release()` answers it whenever the test chooses.
    @MainActor
    final class AuthorizationGate {
        private var resume: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { self.resume = $0 }
        }

        func release() {
            isWaiting = false
            resume?.resume()
            resume = nil
        }
    }

    // MARK: - Helpers

    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    static let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
    static let v0201 = HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.1)")
    static let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.7.20)")

    /// Chained wiring over the fakes: the controller's real chained path
    /// minus the hardware.
    @MainActor
    static func chainedWiring(
        listener: FakeListener,
        speaker: FakeSpeaker,
        authorizationDenial: VoiceListenerError? = nil,
        denials: DenialBox? = nil
    ) -> VoiceLiveController.Wiring {
        // Built from the wiring THE APP SHIPS, so the consent contract
        // under test is production's and not this helper's own: only the
        // hardware is swapped out.
        VoiceLiveController.chainedProduction.replacingHardware(
            makeSession: { _, host in
                var configuration = ChainedVoiceEngine.Configuration()
                configuration.tickInterval = nil        // no background loop in tests
                return VoiceLiveController.Session(
                    engine: ChainedVoiceEngine(
                        listener: listener,
                        speaker: speaker,
                        turnHost: host,
                        configuration: configuration
                    ),
                    bridge: nil
                )
            },
            authorize: { denials?.denial ?? authorizationDenial }
        )
    }

    @MainActor
    static func chainedController(
        listener: FakeListener,
        speaker: FakeSpeaker,
        authorizationDenial: VoiceListenerError? = nil,
        denials: DenialBox? = nil,
        registry: VoiceLiveSessionRegistry? = nil
    ) -> VoiceLiveController {
        VoiceLiveController(
            chained: chainedWiring(
                listener: listener,
                speaker: speaker,
                authorizationDenial: authorizationDenial,
                denials: denials
            ),
            registry: registry ?? VoiceLiveSessionRegistry(),
            // Never accepted: a chained start must not want it anyway.
            consent: VoiceLiveMacTests.consentStore(accepted: false)
        )
    }

    // MARK: - Which engine the button mounts

    /// A chained host mounts `ChainedVoiceEngine` and asks for nothing: the
    /// audio is transcribed on this Mac, so there is no third party to
    /// consent to.
    @Test @MainActor func chainedHostMountsTheChainedEngineWithoutConsent() async {
        let listener = FakeListener()
        let controller = Self.chainedController(listener: listener, speaker: FakeSpeaker())

        controller.start(context: .local, host: ChatViewModel(context: .local), engineKind: .chained)

        #expect(controller.pendingConsent == nil)
        let started = await VoiceLiveMacTests.waitUntil { listener.starts == 1 }
        #expect(started)
        #expect(controller.engineKind == .chained)
        #expect(controller.engine is ChainedVoiceEngine)
        #expect(controller.engine?.approximateCostUSD == 0)
        // The rule the consent rests on, asserted against the wiring the
        // APP builds — `Self.chainedController` swaps only the hardware
        // into it, so a production recipient of `.openAI` would have
        // raised the consent sheet above and failed this test.
        #expect(ChainedVoiceEngine.externalRecipient == nil)
        #expect(VoiceLiveController.chainedProduction.externalRecipient == nil)
    }

    /// The GPT-Live half of the same button is unchanged: it still asks.
    @Test @MainActor func gptLiveHostStillAsksForConsent() {
        let engine = VoiceLiveMacTests.FakeEngine()
        let controller = VoiceLiveController(
            makeSession: { _, _ in .init(engine: engine, bridge: nil) },
            registry: VoiceLiveSessionRegistry(),
            consent: VoiceLiveMacTests.consentStore(accepted: false)
        )

        controller.start(context: .local, host: ChatViewModel(context: .local), engineKind: .gptLive)

        #expect(controller.pendingConsent == .openAI)
        #expect(controller.engine == nil)
        #expect(engine.starts == 0)
    }

    /// The chat picks the engine from the readiness verdict, so one button
    /// serves both hosts.
    @Test @MainActor func theChatPicksTheEngineFromTheVerdict() {
        let vm = ChatViewModel(context: .local)
        vm.voiceChatModeRaw = "chained"
        #expect(vm.voiceLiveAvailability(capabilities: Self.v0213).engineKind == .chained)
        vm.voiceChatModeRaw = "gpt-live"
        #expect(vm.voiceLiveAvailability(capabilities: Self.v0213).engineKind == .gptLive)
        // Too old for GPT-Live but able to speak: chained, as Hermes itself
        // falls back.
        #expect(vm.voiceLiveAvailability(capabilities: Self.v0212).engineKind == .chained)
        #expect(vm.voiceLiveAvailability(capabilities: Self.v0200).engineKind == nil)
    }

    // MARK: - Permissions

    /// Speech recognition denied at the permission prompt: nothing is
    /// started, and the panel has one sentence and a way to fix it.
    @Test @MainActor func deniedSpeechPermissionNeverOpensTheMicrophone() async {
        let listener = FakeListener()
        let controller = Self.chainedController(
            listener: listener, speaker: FakeSpeaker(),
            authorizationDenial: .speechRecognitionDenied
        )

        controller.start(context: .local, host: ChatViewModel(context: .local), engineKind: .chained)
        let failed = await VoiceLiveMacTests.waitUntil { controller.startFailure != nil }

        #expect(failed)
        #expect(controller.startFailure == .speechRecognitionDenied)
        #expect(listener.starts == 0)
        #expect(!controller.holdsSession)
        let copy = VoiceLivePresentation.failure(.speechRecognitionDenied)
        #expect(copy.guidance?.contains("Speech Recognition") == true)
        #expect(copy.offersSpeechRecognitionSettings)
    }

    /// A denial that only shows up when listening starts (the TCC state
    /// changed under us) reaches the engine's failed phase.
    @Test @MainActor func aListenerDenialEndsInTheFailedPhase() async {
        let listener = FakeListener(startError: .speechRecognitionDenied)
        let controller = Self.chainedController(listener: listener, speaker: FakeSpeaker())

        controller.start(context: .local, host: ChatViewModel(context: .local), engineKind: .chained)
        let failed = await VoiceLiveMacTests.waitUntil {
            controller.engine?.phase == .failed(.speechRecognitionDenied)
        }
        #expect(failed)
    }

    /// No on-device model for this language: a different sentence, pointing
    /// at where the language is downloaded.
    @Test func theUnsupportedLanguageFailureExplainsTheDownload() {
        let copy = VoiceLivePresentation.failure(.speechRecognitionUnavailable)
        #expect(!copy.message.isEmpty)
        #expect(copy.guidance?.contains("Dictation") == true)
        #expect(VoiceSessionFailure.speechRecognitionUnavailable.setupHint)
        #expect(VoiceSessionFailure.speechRecognitionDenied.setupHint)
    }

    // MARK: - The rest of the app stands down

    /// The message speaker button is disabled while a chained session runs,
    /// exactly as for GPT-Live — one Mac, one speaker.
    @Test @MainActor func messageSpeechStandsDownDuringAChainedSession() async {
        let registry = VoiceLiveSessionRegistry()
        let listener = FakeListener()
        let controller = Self.chainedController(listener: listener, speaker: FakeSpeaker(), registry: registry)

        #expect(!registry.isAnySessionActive)
        controller.start(context: .local, host: ChatViewModel(context: .local), engineKind: .chained)
        #expect(registry.isAnySessionActive)
        #expect(!SpeakMessageButtonState(isPlaying: false, isLoading: false, liveVoiceActive: registry.isAnySessionActive).isEnabled)

        controller.dismiss()
        #expect(!registry.isAnySessionActive)
    }

    /// Leaving the chat pane ends a chained session and releases the
    /// microphone — the listener is stopped, not merely dropped.
    @Test @MainActor func leavingTheChatEndsAChainedSession() async {
        let listener = FakeListener()
        let controller = Self.chainedController(listener: listener, speaker: FakeSpeaker())
        let vm = ChatViewModel(context: .local, voiceLive: controller)

        controller.start(context: .local, host: vm, engineKind: .chained)
        let live = await VoiceLiveMacTests.waitUntil { listener.starts == 1 }
        #expect(live)

        vm.leaveChatVoiceLive()
        #expect(listener.stops >= 1)
        #expect(controller.engine == nil)
        #expect(!controller.holdsSession)
    }

    // MARK: - Restarting after a finished session

    /// A finished session on the panel never survives the next start. The
    /// panel renders `engine` first and `startFailure` only when there is
    /// no engine, so a refused restart that left the ended engine in place
    /// made "Start Again" look dead: the user pressed it, a permission was
    /// refused, and the panel went on showing the session that already
    /// ended.
    @Test @MainActor func aRefusedRestartReplacesTheFinishedSessionWithTheFailure() async {
        let denials = DenialBox()
        let listener = FakeListener()
        let controller = Self.chainedController(
            listener: listener, speaker: FakeSpeaker(), denials: denials
        )
        let host = ChatViewModel(context: .local)

        controller.start(context: .local, host: host, engineKind: .chained)
        let started = await VoiceLiveMacTests.waitUntil { listener.starts == 1 }
        #expect(started)
        controller.end()
        let ended = await VoiceLiveMacTests.waitUntil { !controller.isSessionActive }
        #expect(ended)
        #expect(controller.engine != nil)   // the panel still shows how it ended

        // Speech Recognition revoked in System Settings between sessions.
        denials.denial = .speechRecognitionDenied
        controller.start(context: .local, host: host, engineKind: .chained)
        let refused = await VoiceLiveMacTests.waitUntil { controller.startFailure != nil }
        #expect(refused)

        // Exactly what `VoiceLivePanel` binds to: no engine left, so the
        // failure branch is the one that renders.
        #expect(controller.engine == nil)
        #expect(controller.bridge == nil)
        #expect(controller.startFailure == .speechRecognitionDenied)
    }

    /// A start blocked by another window clears the previous start's
    /// permission failure: the chat says why it refused, and no stale
    /// "Allow Scarf in Speech Recognition" is left on the panel.
    @Test @MainActor func aBlockedStartClearsAStalePermissionFailure() async {
        let registry = VoiceLiveSessionRegistry()
        let controller = Self.chainedController(
            listener: FakeListener(), speaker: FakeSpeaker(),
            authorizationDenial: .speechRecognitionDenied, registry: registry
        )
        let host = ChatViewModel(context: .local)
        controller.start(context: .local, host: host, engineKind: .chained)
        let refused = await VoiceLiveMacTests.waitUntil { controller.startFailure != nil }
        #expect(refused)

        let other = Self.chainedController(
            listener: FakeListener(), speaker: FakeSpeaker(), registry: registry
        )
        other.start(context: .local, host: ChatViewModel(context: .local), engineKind: .chained)
        #expect(other.holdsSession)

        controller.start(context: .local, host: host, engineKind: .chained)
        #expect(controller.startRefusal == .blockedByAnotherWindow)
        #expect(controller.startFailure == nil)
        other.endImmediately()
    }

    /// Same for a start that only raises the consent sheet: a stale
    /// permission failure must not show underneath it.
    @Test @MainActor func aConsentPendingStartClearsAStalePermissionFailure() async {
        let controller = Self.chainedController(
            listener: FakeListener(), speaker: FakeSpeaker(),
            authorizationDenial: .microphoneDenied
        )
        let host = ChatViewModel(context: .local)
        controller.start(context: .local, host: host, engineKind: .chained)
        let refused = await VoiceLiveMacTests.waitUntil { controller.startFailure != nil }
        #expect(refused)

        controller.start(context: .local, host: host, engineKind: .gptLive)
        #expect(controller.pendingConsent == .openAI)
        #expect(controller.startFailure == nil)
    }

    /// Ending while the permission prompt is still in front of the user
    /// mounts nothing: `AppleOnDeviceVoiceListener.authorize()` is not
    /// cancellation-aware, so the prompt stays up, but its late answer is
    /// dropped on the cancelled start task.
    @Test @MainActor func anEndDuringThePermissionPromptNeverMountsASession() async {
        let gate = AuthorizationGate()
        let listener = FakeListener()
        let speaker = FakeSpeaker()
        let controller = VoiceLiveController(
            chained: VoiceLiveController.Wiring(
                makeSession: { _, host in
                    var configuration = ChainedVoiceEngine.Configuration()
                    configuration.tickInterval = nil
                    return VoiceLiveController.Session(
                        engine: ChainedVoiceEngine(
                            listener: listener, speaker: speaker,
                            turnHost: host, configuration: configuration
                        ),
                        bridge: nil
                    )
                },
                externalRecipient: nil,
                authorize: { await gate.wait(); return nil }
            ),
            registry: VoiceLiveSessionRegistry(),
            consent: VoiceLiveMacTests.consentStore(accepted: false)
        )

        controller.start(context: .local, host: ChatViewModel(context: .local), engineKind: .chained)
        let waiting = await VoiceLiveMacTests.waitUntil { gate.isWaiting }
        #expect(waiting)
        #expect(controller.holdsSession)

        controller.endImmediately()
        #expect(!controller.holdsSession)
        gate.release()   // the user answers the prompt after the session is gone

        let mounted = await VoiceLiveMacTests.waitUntil(timeoutSeconds: 0.4) {
            controller.engine != nil || listener.starts > 0
        }
        #expect(!mounted)
        #expect(controller.engine == nil)
        #expect(listener.starts == 0)
    }

    // MARK: - Panel copy

    @Test func thePanelSaysTheVoiceStaysOnThisMac() {
        let hermes = VoiceLivePresentation.chainedPrivacyNote(
            ttsProvider: "edge", playbackPreference: "hermes"
        )
        #expect(hermes.contains("edge"))
        #expect(hermes.contains("this Mac"))
        // No provider resolved yet: say so rather than naming a provider
        // Scarf doesn't know.
        let unknown = VoiceLivePresentation.chainedPrivacyNote(
            ttsProvider: nil, playbackPreference: "hermes"
        )
        #expect(!unknown.contains("edge"))
        #expect(!unknown.isEmpty)
    }

    /// The privacy line and the chained factory read ONE preference. With
    /// System Voice chosen the factory builds a plain `SystemVoiceSpeaker`
    /// and the host's provider is never asked to speak anything, so the
    /// line must not name it (or claim the audio reaches the host).
    @Test func thePrivacyLineFollowsThePlaybackEnginePreference() {
        #expect(VoiceLiveController.chainedPlaybackEngine(preference: "hermes") == .hermes)
        for system in ["system", nil, "", "nonsense"] as [String?] {
            #expect(VoiceLiveController.chainedPlaybackEngine(preference: system) == .system, "\(system ?? "nil")")
        }

        let system = VoiceLivePresentation.chainedPrivacyNote(
            ttsProvider: "openai", playbackPreference: "system"
        )
        #expect(!system.contains("openai"))
        #expect(!system.contains("Hermes host"))
        #expect(system.contains("this Mac"))

        let hermes = VoiceLivePresentation.chainedPrivacyNote(
            ttsProvider: "openai", playbackPreference: "hermes"
        )
        #expect(hermes.contains("openai"))
        #expect(hermes.contains("Hermes host"))
    }

    /// The Settings row is the same rule: System Voice never bills a
    /// provider, so it must not print one or badge it Paid.
    @Test func theSettingsTTSRowFollowsThePlaybackEnginePreference() {
        let system = VoiceTab.chainedTextToSpeechLabel(provider: "openai", playbackPreference: "system")
        #expect(!system.lowercased().contains("openai"))
        #expect(system.contains("this Mac") || system.contains("This Mac"))
        #expect(VoiceTab.chainedTTSCost(provider: "openai", playbackPreference: "system") == .free)

        let hermes = VoiceTab.chainedTextToSpeechLabel(provider: "openai", playbackPreference: "hermes")
        #expect(hermes.contains("openai"))
        #expect(VoiceTab.chainedTTSCost(provider: "openai", playbackPreference: "hermes") == .paid)
        // An unset key still names Hermes's default when the host speaks.
        #expect(VoiceTab.chainedTextToSpeechLabel(provider: "", playbackPreference: "hermes").contains("edge"))
    }

    /// An absent `tts.provider` is Hermes's default, `edge` — resolved by
    /// NAME (the iOS twin's step) and then classified, so the two apps
    /// can't drift apart on what "" costs.
    @Test func anUnsetTTSProviderResolvesToEdgeByName() {
        #expect(VoiceTab.resolvedTTSProviderName("") == "edge")
        #expect(VoiceTab.resolvedTTSProviderName("  ") == "edge")
        #expect(VoiceTab.resolvedTTSProviderName(" OpenAI ") == "openai")
        #expect(VoiceTab.ttsCost(for: "") == VoiceTab.ttsCost(for: "edge"))
    }

    /// The chained panel never shows a cost: there is none.
    @Test func theChainedPanelShowsNoCost() {
        #expect(!VoiceLivePresentation.showsCost(for: .chained))
        #expect(VoiceLivePresentation.showsCost(for: .gptLive))
    }

    @Test func theFallbackToTheSystemVoiceIsExplained() {
        let line = VoiceLivePresentation.notice(.speechFallback)
        #expect(!line.isEmpty)
        #expect(line.contains("system voice"))
    }

    // MARK: - Settings › Voice

    /// C1: below v0.20.1 the whole "Voice conversation" section is gone, so
    /// the tab renders exactly as it did before P7.
    @Test func theVoiceConversationSectionIsHiddenBelowTheSpeechFloor() {
        #expect(!VoiceTab.showsVoiceConversationSection(capabilities: Self.v0200))
        #expect(!VoiceTab.showsVoiceConversationSection(capabilities: .empty))
        #expect(VoiceTab.showsVoiceConversationSection(capabilities: Self.v0201))
        #expect(VoiceTab.showsVoiceConversationSection(capabilities: Self.v0213))
    }

    /// The free/paid badge next to the resolved TTS provider.
    @Test func theTTSProviderBadgeSeparatesFreeFromPaid() {
        for free in ["edge", "piper", "kittentts", "neutts", ""] {
            #expect(VoiceTab.ttsCost(for: free) == .free, "\(free)")
        }
        for paid in ["openai", "elevenlabs", "xai", "deepinfra", "gemini", "mistral", "minimax"] {
            #expect(VoiceTab.ttsCost(for: paid) == .paid, "\(paid)")
        }
        // A plugin-registered provider Scarf can't classify claims nothing.
        #expect(VoiceTab.ttsCost(for: "acme-labs") == .unknown)
    }

    /// The chained rows say where each half of the loop runs.
    @Test func theChainedRowsNameBothHalvesOfTheLoop() {
        #expect(VoiceTab.chainedSpeechToTextLabel().contains("this Mac"))
        #expect(VoiceTab.chainedTextToSpeechLabel(provider: "edge", playbackPreference: "hermes").contains("edge"))
        #expect(!VoiceTab.chainedPrivacyNote().isEmpty)
    }
}
