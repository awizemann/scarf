import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Regression coverage for `ChatViewModel.sendViaACP`'s local-echo
/// handling — S2 of the 2026-07-13 chat diagnosis.
///
/// The old guard suppressed the user bubble whenever `messages.last`
/// was a user message with identical text. Built for the autoStart
/// path's optimistic echo, it string-matched against DB-hydrated
/// history too: a user deliberately re-sending earlier text got no
/// bubble, `addUserMessage` never ran, the engagement gate stayed
/// closed, and the whole turn streamed invisibly. The echo decision is
/// now the explicit `localEchoAlreadyAdded` caller flag (threaded from
/// `autoStartACPAndSend` and the project-wizard kickoff), and
/// `sendViaACP` opens the replay-suppression gate at the send point
/// via `markPromptSent()` regardless of echo.
@Suite struct ChatViewModelSendDedupTests {

    /// A never-started `ACPClient`. `sendViaACP`'s synchronous echo +
    /// gate logic is what's under test; the async prompt task just
    /// fails fast with `notConnected` (its error `.promptComplete`
    /// lands after the test's synchronous assertions).
    @MainActor
    static func deadClient() -> ACPClient {
        ACPClient(context: .local) { _ in
            throw CocoaError(.featureUnsupported)
        }
    }

    /// AutoStart pre-echoes the bubble before session setup, then
    /// sends with `localEchoAlreadyAdded: true`: exactly one bubble —
    /// and the gate reopens at the send point even though
    /// `setSessionId` (session resolution) reset it after the echo.
    @Test @MainActor func autoStartEchoIsNotDoubleAppended() {
        let chatVM = ChatViewModel(context: .local)
        let rich = chatVM.richChatViewModel
        // autoStartACPAndSend: optimistic echo first…
        rich.addUserMessage(text: "hello")
        // …then session resolution lands (resets the engagement gate)…
        rich.setSessionId("s")
        // …then the queued prompt is sent with the suppression flag.
        chatVM.sendViaACP(client: Self.deadClient(), text: "hello", localEchoAlreadyAdded: true)

        #expect(rich.messages.filter { $0.isUser && $0.content == "hello" }.count == 1)

        // The send opened the gate: the turn's live chunks are not
        // dropped as session/load replay (pre-fix this turn was deaf).
        rich.handleACPEvent(.messageChunk(sessionId: "s", text: "reply"))
        #expect(rich.messages.contains { $0.isAssistant && $0.content == "reply" })
    }

    /// A deliberate re-send of text identical to the last history row
    /// (e.g. retrying after a failed turn) must always append a fresh
    /// bubble — the pre-fix content-matching guard swallowed it.
    @Test @MainActor func deliberateResendOfIdenticalTextIsAppended() {
        let chatVM = ChatViewModel(context: .local)
        let rich = chatVM.richChatViewModel
        rich.setSessionId("s")
        // History ends with the user's earlier identical text (the
        // prior turn produced no assistant reply).
        rich.addUserMessage(text: "retry me")

        // Interactive send path: no pre-echo, default flag.
        chatVM.sendViaACP(client: Self.deadClient(), text: "retry me")

        #expect(rich.messages.filter { $0.isUser && $0.content == "retry me" }.count == 2)
    }
}
