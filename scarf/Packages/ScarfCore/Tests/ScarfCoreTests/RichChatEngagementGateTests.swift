import Testing
import Foundation
@testable import ScarfCore

/// Regression coverage for the pre-engagement (replay-suppression) gate
/// in `RichChatViewModel.handleACPEvent` — S2 of the 2026-07-13 chat
/// diagnosis ("deaf transcript").
///
/// The gate exists to drop Hermes' post-`session/load` replay (the ACP
/// adapter re-streams recent transcript state as agent events; Scarf
/// hydrates history from `state.db` instead) until a prompt is actually
/// sent in the attached session. Two invariants were broken before the
/// fix:
///
/// 1. `.promptComplete` was gate-dropped. It is never part of the
///    replay — `ACPEventParser` never emits it; the send path
///    synthesizes it from `sendPrompt`'s return — and it carries the
///    turn's token accounting, the `isAgentWorking` clear, and the
///    no-output failure bubble. Dropping it left a turn whose gate
///    bookkeeping slipped stuck on "Agent working…" forever.
/// 2. The gate only opened inside `addUserMessage`. Send paths whose
///    optimistic echo preceded `setSessionId` (autoStart resolution
///    resets the gate) — or whose echo was deduped — streamed the whole
///    turn into a closed gate. `markPromptSent()` now opens the gate at
///    the actual send point.
@Suite struct RichChatEngagementGateTests {

    /// The S2 wedge, distilled: the echo opened the gate, session
    /// resolution (`setSessionId`) closed it again with the turn still
    /// in flight (`isAgentWorking == true`), then the synthesized
    /// `.promptComplete` arrived at the closed gate. It must be
    /// processed anyway: turn accounting lands, `isAgentWorking`
    /// clears, and the refusal failure bubble is built.
    @Test @MainActor func promptCompleteIsProcessedWithGateClosed() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "hi")
        // AutoStart resolves the session AFTER the optimistic echo —
        // this resets the gate while the turn is still running.
        vm.setSessionId("s")
        #expect(vm.isAgentWorking)

        let refusal = ACPPromptResult(
            stopReason: "refusal",
            inputTokens: 7, outputTokens: 0,
            thoughtTokens: 3, cachedReadTokens: 5
        )
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: refusal))

        // Turn accounting was applied, not gate-dropped.
        #expect(vm.acpInputTokens == 7)
        #expect(vm.acpThoughtTokens == 3)
        #expect(vm.acpCachedReadTokens == 5)
        // The working indicator cleared — no eternal spinner.
        #expect(vm.isAgentWorking == false)
        // The no-output refusal produced its system failure bubble.
        #expect(vm.messages.contains {
            $0.role == "system" && $0.content.contains("refused")
        })
    }

    /// The gate's original purpose is intact: with no prompt sent in
    /// the attached session, Hermes' post-`session/load` replay
    /// (chunks, thoughts, tool events) must NOT paint bubbles — the
    /// DB-hydrated history is authoritative.
    @Test @MainActor func replaySuppressionStillDropsHistoryEventsBeforeEngagement() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")

        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "replayed reply"))
        vm.handleACPEvent(.thoughtChunk(sessionId: "s", text: "replayed thought"))
        vm.handleACPEvent(.toolCallStart(
            sessionId: "s",
            call: ACPToolCallEvent(
                toolCallId: "t1", title: "read_file: foo",
                kind: "read", status: "in_progress",
                content: "", rawInput: nil
            )
        ))
        vm.handleACPEvent(.toolCallUpdate(
            sessionId: "s",
            update: ACPToolCallUpdateEvent(
                toolCallId: "t1", kind: "read",
                status: "completed", content: "file body", rawOutput: nil
            )
        ))

        // Nothing painted: chunks/thoughts upsert the streaming bubble
        // into `messages`, tool updates append tool-result rows — all
        // of it must have been dropped as replay.
        #expect(vm.messages.isEmpty)
        #expect(vm.messageGroups.isEmpty)
    }

    /// `markPromptSent()` — the send-site gate opener — lets live
    /// chunks flow even when no local echo re-opened the gate (the
    /// deduped-echo / post-`setSessionId` send case).
    @Test @MainActor func chunksFlowAfterSendOpensGateViaMarkPromptSent() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        // Sanity: gate starts closed for the freshly-attached session.
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "replayed"))
        #expect(vm.messages.isEmpty)

        vm.markPromptSent()
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "live "))
        #expect(vm.messages.contains { $0.isAssistant && $0.content == "live " })
    }
}
