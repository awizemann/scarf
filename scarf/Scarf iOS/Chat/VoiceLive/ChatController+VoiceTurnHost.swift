import Foundation
import ScarfCore

#if canImport(SQLite3)

/// Why ScarfGo couldn't hand a Live Voice turn to Hermes. The engine speaks
/// its own "couldn't reach Hermes" line on any throw, so this is never shown.
enum VoiceTurnSubmitError: Error, Equatable {
    /// No live ACP session: connecting, reconnecting, failed, or offline.
    case chatNotReady
}

extension ChatController.State {
    /// Whether a Live Voice session must end now that the chat is in this
    /// state. Only `.ready` has a live ACP session to hand spoken turns to;
    /// in every other state `submitVoiceTurn` throws ``VoiceTurnSubmitError``
    /// while the GPT-Live session keeps streaming to OpenAI at $0.05/min.
    /// A reconnect counts: it lands on a NEW ACP session, which the voice
    /// session's seeded context and pending turns do not belong to.
    var endsLiveVoice: Bool {
        self != .ready
    }
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
/// 5. Voice cancels only VOICE turns (Alan, t-2140ec98). While a typed
///    request runs — or is queued inside a running voice turn — a spoken
///    request is not sent: `isVoiceTurnBusy` doesn't count the typed turn,
///    `cancelActiveVoiceTurn` leaves it alone, and `submitVoiceTurn`
///    answers with `voiceBusyReply`, which the voice speaks. A voice
///    request never silently kills something typed.
extension ChatController: VoiceTurnHost {

    /// A voice turn this controller started is still running and nothing
    /// typed is mixed into its run. The engine cancels whatever reads busy,
    /// and voice cancels only its own turns, so a typed request (running,
    /// or queued inside the voice turn's run) makes this false; the next
    /// spoken request is then answered "busy" by `submitVoiceTurn`.
    var isVoiceTurnBusy: Bool {
        promptsInFlight > 0
            && busyTurnOrigins.contains(.voice)
            && !busyTurnOrigins.contains(.typed)
    }

    /// Hermes is busy with something that isn't a voice turn: a typed
    /// prompt this controller sent (running, or queued behind a voice
    /// turn), or a turn the transcript shows running that Scarf didn't
    /// start here.
    var isBusyWithNonVoiceTurn: Bool {
        if promptsInFlight > 0 { return busyTurnOrigins.contains(.typed) }
        return vm.isAgentWorking
    }

    /// What the voice says when a spoken request arrives while Hermes works
    /// on a typed one. Model input, not UI copy (the voice speaks it in the
    /// conversation's language), so English like the engine's own lines.
    static let voiceBusyReply = "Hermes is busy with another request in this chat, so I didn't send that. Ask me again when it's finished."

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

    /// While Hermes works on a typed request, nothing is sent: the request
    /// is answered with `voiceBusyReply` (through `voiceTurnReply`) and the
    /// composer notice says why. Returning normally rather than throwing is
    /// deliberate — a throw makes the engine speak its "could not reach
    /// Hermes" line instead of the real reason.
    func submitVoiceTurn(_ request: VoiceTurnRequest) async throws {
        guard state == .ready, let client = activeClient,
              let sessionId = vm.sessionId, !sessionId.isEmpty else {
            throw VoiceTurnSubmitError.chatNotReady
        }
        if isBusyWithNonVoiceTurn {
            busyVoiceRequestIDs.append(request.id)
            if busyVoiceRequestIDs.count > 8 {
                busyVoiceRequestIDs.removeFirst(busyVoiceRequestIDs.count - 8)
            }
            voiceComposerNotices?.showComposerNotice(.busyWithTypedTurn)
            return
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
            restoreDraftText: nil,
            origin: .voice
        )
    }

    /// Only turns Live Voice STARTED are cancelled. With a typed request
    /// running or queued inside a voice turn's run this does nothing: the
    /// submit that follows answers "busy" instead. The wait stays bounded
    /// (charter C10) — a wedged host must not freeze the voice session.
    func cancelActiveVoiceTurn() async {
        guard let client = activeClient, let sessionId = vm.sessionId, !sessionId.isEmpty else { return }
        guard !isBusyWithNonVoiceTurn, isVoiceTurnBusy else { return }
        // The cancel RPC has its own 60 s watchdog in ACPClient; don't await
        // it — the turn is over when its `sendPrompt` returns, not when the
        // cancel is acknowledged.
        Task { try? await client.cancel(sessionId: sessionId) }
        await waitForPromptsToReturn(timeout: voiceCancelTimeout)
    }

    func voiceTurnReply(for requestID: String) -> VoiceTurnReply? {
        if busyVoiceRequestIDs.contains(requestID) {
            return VoiceTurnReply(text: Self.voiceBusyReply, isStreaming: false)
        }
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
