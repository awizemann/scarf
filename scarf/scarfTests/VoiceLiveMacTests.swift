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
                heldPromptIds.append(id)
            case "session/cancel":
                for held in heldPromptIds {
                    reply(["jsonrpc": "2.0", "id": held, "result": ["stopReason": "cancelled"]])
                }
                heldPromptIds = []
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

    /// A chat VM whose Live Voice controller builds `FakeEngine`s.
    @MainActor
    static func chat(context: ServerContext, engines: @escaping (FakeEngine) -> Void = { _ in }) -> ChatViewModel {
        let controller = VoiceLiveController { _, _ in
            let engine = FakeEngine()
            engines(engine)
            return VoiceLiveController.Session(engine: engine, bridge: nil)
        }
        return ChatViewModel(context: context, voiceLive: controller)
    }

    /// A chat attached to a live scripted ACP session.
    @MainActor
    static func connectedChat(
        home: TempHermesHome,
        channel: VoiceScriptedChannel,
        engines: @escaping (FakeEngine) -> Void = { _ in }
    ) async -> ChatViewModel {
        let vm = chat(context: home.context, engines: engines)
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.startNewSession()
        _ = await waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.ready }
        return vm
    }

    // MARK: - Readiness gate

    @Test @MainActor func gateNeedsBothTheVersionFloorAndGPTLiveMode() {
        let vm = ChatViewModel(context: .local)
        let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")

        // Config not read yet: hidden (reads as Hermes's chained default).
        #expect(vm.voiceLiveAvailability(capabilities: v0213) == .hidden(.chainedMode))
        vm.voiceChatModeRaw = "chained"
        #expect(vm.voiceLiveAvailability(capabilities: v0213) == .hidden(.chainedMode))
        // Hermes's own alternate spelling counts.
        vm.voiceChatModeRaw = "gpt_live"
        #expect(vm.voiceLiveAvailability(capabilities: v0213) == .ready)
        // Below the floor nothing shows, whatever the config says (C1).
        #expect(vm.voiceLiveAvailability(capabilities: v0212) == .hidden(.hermesTooOld))
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
        vm.startVoiceLive()
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

        vm.sendText("a long typed turn")
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

        vm.startVoiceLive()
        let started = await Self.waitUntil { engines.first?.starts == 1 }
        #expect(started)
        #expect(vm.voiceLive.isSessionActive)
        // A second start while one runs is a no-op.
        vm.startVoiceLive()
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
        vm.startVoiceLive()
        _ = await Self.waitUntil { engines.first?.phase == .connecting }

        vm.stopACP()
        #expect(engines.first?.immediateEnds == [.userEnded])
    }

    @Test @MainActor func controllerEndIsGracefulAndDismissClears() async {
        let engine = FakeEngine()
        let controller = VoiceLiveController { _, _ in .init(engine: engine, bridge: nil) }
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
        #expect(vendor.detail == "upstream")
        #expect(VoiceLivePresentation.failure(.host(.vendor(status: 401, detail: ""))).detail == nil)
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
