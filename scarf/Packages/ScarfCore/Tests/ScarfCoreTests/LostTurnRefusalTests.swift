import Testing
@testable import ScarfCore

/// `ACPClientError.lostTurnRefusal` against the text gateway-backed ACP sends
/// (`_unknown_recovery`, acp_adapter/gateway_server.py:847-850 @ v0.22.5).
@Suite struct LostTurnRefusalTests {
    private func refusal(ids: [String], state: String = "nothing was submitted") -> ACPClientError {
        let commands = ids.map { "`/discard \($0)`" }.joined(separator: " and ")
        return .rpcError(code: -32603, message: "Internal error", details:
            "unknown_execution: do not resend accepted input; a turn in this session was lost when the gateway restarted and its outcome is unknown (\(state)). Send \(commands) here (or `hermes -p work sessions discard s1` in a terminal), then continue.")
    }

    @Test func readsEveryLostTurnAndSaysTheMessageWasNotSent() throws {
        let lost = try #require(ACPClientError.lostTurnRefusal(refusal(ids: ["a-1", "b_2"])))
        #expect(lost.discardIDs == ["a-1", "b_2"])
        #expect(lost.hint.contains("/discard a-1 and /discard b_2"))
        #expect(lost.hint.contains("wasn't sent"))
    }

    @Test func acceptedInputIsNotCalledUnsent() throws {
        let lost = try #require(ACPClientError.lostTurnRefusal(refusal(ids: ["a"], state: "your input is accepted and kept")))
        #expect(!lost.hint.contains("wasn't sent"))
    }

    /// Hosts that never send the text take no new path.
    @Test func anythingElseIsNotARefusal() {
        #expect(ACPClientError.lostTurnRefusal(ACPClientError.rpcError(code: -32603, message: "Internal error", details: nil)) == nil)
        #expect(ACPClientError.lostTurnRefusal(ACPClientError.rpcError(code: -32603, message: "Internal error", details: "not_found")) == nil)
        #expect(ACPClientError.lostTurnRefusal(ACPClientError.rpcError(code: -32000, message: "x", details: "unknown_execution: Send `/discard a`")) == nil)
        #expect(ACPClientError.lostTurnRefusal(ACPClientError.notConnected) == nil)
    }

    @Test func aGatewayDeathLeadsWithHermesTextAndAHint() {
        let error = ACPClientError.rpcError(code: -32603, message: "Internal error", details:
            "Gateway disconnected; turn outcome is unknown. Resume the printed session ID to check whether it completed or was interrupted; do not resend the work.")
        let shown = error.localizedDescription
        #expect(shown.contains("turn outcome is unknown"))
        #expect(!shown.contains("Internal error"))
        #expect(ACPErrorHint.classify(errorMessage: shown, stderrTail: "")?.hint.contains("didn't resend") == true)
    }

    /// The offer belongs to the failure that set it.
    @MainActor @Test func anotherErrorClearsTheOffer() async {
        let vm = RichChatViewModel(context: .local)
        await vm.recordACPFailure(refusal(ids: ["a"]), client: nil)
        #expect(vm.acpErrorDiscardIDs == ["a"])
        vm.acpError = "Something else"
        #expect(vm.acpErrorDiscardIDs.isEmpty)
        await vm.recordACPFailure(refusal(ids: ["a"]), client: nil)
        vm.clearACPErrorState()
        #expect(vm.acpErrorDiscardIDs.isEmpty)
    }
}

/// Mac and iOS both record the failure, then synthesize an `error` stop.
@Suite struct PromptFailureHintTests {
    private func failAndStop(_ error: Error, _ vm: RichChatViewModel) async {
        vm.setSessionId("s")
        await vm.recordACPFailure(error, client: nil)
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "error", inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0)))
        await Task.yield()
    }

    @MainActor @Test func noServerTextGetsTheFallbackHint() async {
        for error in [ACPClientError.rpcError(code: -32603, message: "Internal error", details: nil),
                      ACPClientError.requestTimeout(method: "session/prompt")] {
            let vm = RichChatViewModel(context: .local)
            await failAndStop(error, vm)
            #expect(vm.acpError == error.localizedDescription)
            #expect(vm.acpErrorHint?.contains("The provider returned an error") == true)
        }
    }

    @MainActor @Test func serverTextIsKeptWithNoGuess() async {
        let vm = RichChatViewModel(context: .local)
        await failAndStop(ACPClientError.rpcError(code: -32603, message: "Internal error", details: "session is wedged"), vm)
        #expect(vm.acpError?.contains("session is wedged") == true)
        #expect(vm.acpErrorHint == nil)
    }
}
