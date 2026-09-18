import Foundation
import ScarfCore

#if canImport(SQLite3)

/// Why ScarfGo couldn't hand a Live Voice turn to Hermes. The engine speaks
/// its own "couldn't reach Hermes" line on any throw, so this is never shown.
enum VoiceTurnSubmitError: Error, Equatable {
    /// No live ACP session: connecting, reconnecting, failed, or offline.
    case chatNotReady
}

/// ScarfGo's chat as the Live Voice engine's `VoiceTurnHost` (P4 contract,
/// `ScarfCore/VoiceLive/VoiceConversationEngine.swift`). The Mac twin is
/// `ChatViewModel`'s conformance (P5a); both follow the same four rules:
///
/// 1. The user bubble is appended BEFORE the first `await` in
///    `submitVoiceTurn`, so `VoiceTurnReply.latest` can never match an older
///    turn with the same words.
/// 2. `submitVoiceTurn` returns once the prompt is handed off; the turn
///    itself runs through `startPrompt`, which synthesizes `.promptComplete`
///    from `sendPrompt`'s return exactly as a typed turn does (gh#124).
/// 3. `cancelActiveVoiceTurn` cancels, then waits for the running
///    `sendPrompt` to RETURN (bounded), because Hermes queues a prompt that
///    arrives mid-turn as text only and drops the voice note.
/// 4. Replies come from `VoiceTurnReply.latest(in:forPrompt:isStreaming:)`.
extension ChatController: VoiceTurnHost {

    var isVoiceTurnBusy: Bool {
        promptsInFlight > 0 || vm.isAgentWorking
    }

    var activeVoiceToolName: String? {
        if case .runningTool(let name) = vm.liveActivityStatus { return name }
        return nil
    }

    /// The ACP session: Hermes keeps a cancelled turn's text per session,
    /// so the engine's "next voice turn goes text-only" debt is keyed by it
    /// and survives into the next voice session (`VoiceTextOnlyTurnLedger`).
    var voiceChatID: String? {
        guard let sessionId = vm.sessionId, !sessionId.isEmpty else { return nil }
        return sessionId
    }

    func submitVoiceTurn(_ request: VoiceTurnRequest) async throws {
        guard state == .ready, let client = activeClient,
              let sessionId = vm.sessionId, !sessionId.isEmpty else {
            throw VoiceTurnSubmitError.chatNotReady
        }
        // Rule 1: the bubble exists before anything can suspend.
        vm.addUserMessage(text: request.prompt)
        rememberVoicePrompt(request)
        // Rule 2: hand off and return. `startPrompt` counts the turn in
        // `promptsInFlight` before it returns, so a cancel racing this
        // hand-off still waits for the prompt.
        startPrompt(
            client: client,
            sessionId: sessionId,
            wireText: request.prompt,
            images: [],
            contextNotes: request.contextNotes,
            restoreDraftText: nil
        )
    }

    func cancelActiveVoiceTurn() async {
        guard let client = activeClient, let sessionId = vm.sessionId, !sessionId.isEmpty else { return }
        guard isVoiceTurnBusy else { return }
        // The cancel RPC has its own 60 s watchdog in ACPClient; don't await
        // it — the turn is over when its `sendPrompt` returns, not when the
        // cancel is acknowledged.
        Task { try? await client.cancel(sessionId: sessionId) }
        await waitForPromptsToReturn(timeout: voiceCancelTimeout)
    }

    func voiceTurnReply(for requestID: String) -> VoiceTurnReply? {
        guard let prompt = voiceTurnPrompts.last(where: { $0.id == requestID })?.prompt else { return nil }
        return VoiceTurnReply.latest(in: vm.messages, forPrompt: prompt, isStreaming: isVoiceTurnBusy)
    }

    func voiceSeedTurns() -> [VoiceLiveText.SeedTurn] {
        vm.messages.compactMap { message in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case "user": return VoiceLiveText.SeedTurn(role: .user, text: text)
            case "assistant": return VoiceLiveText.SeedTurn(role: .assistant, text: text)
            default: return nil   // tool rows, system notes
            }
        }
    }

    // MARK: - Helpers

    private func rememberVoicePrompt(_ request: VoiceTurnRequest) {
        voiceTurnPrompts.append((id: request.id, prompt: request.prompt))
        if voiceTurnPrompts.count > 8 { voiceTurnPrompts.removeFirst(voiceTurnPrompts.count - 8) }
    }

    /// Poll (50 ms) until every sent prompt has returned or `timeout`
    /// passes. Polling rather than a continuation keeps the bounded wait
    /// trivially cancellation-safe.
    func waitForPromptsToReturn(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while promptsInFlight > 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

#endif
