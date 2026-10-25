import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Mac chat send-path decisions for gateway-backed ACP
/// (`HermesCapabilities.hasGatewayBackedACP`, Hermes 0.22.1 and 0.22.3+).
@Suite struct GatewayBackedACPChatTests {

    static let v0225 = HermesCapabilities.parseLine("Hermes Agent v0.22.5 (2026.9.24)")
    static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")

    /// A mid-turn `/queue` holds the chat's busy period on gateway hosts,
    /// where its `session/prompt` returns only when the queued prompt ran.
    @Test func midTurnQueueHoldsTheTurnOnlyOnGatewayHosts() {
        #expect(ChatViewModel.queuedPromptHoldsTurn(
            name: "queue", isNonInterruptive: true, wasAgentWorking: true, capabilities: Self.v0225))
        // In-process adapter: the running turn drains the queue itself.
        #expect(!ChatViewModel.queuedPromptHoldsTurn(
            name: "queue", isNonInterruptive: true, wasAgentWorking: true, capabilities: Self.v0215))
        // An idle `/queue` is an ordinary prompt; `/steer` never holds.
        #expect(!ChatViewModel.queuedPromptHoldsTurn(
            name: "queue", isNonInterruptive: false, wasAgentWorking: false, capabilities: Self.v0225))
        #expect(!ChatViewModel.queuedPromptHoldsTurn(
            name: "queue", isNonInterruptive: true, wasAgentWorking: false, capabilities: Self.v0225))
        #expect(!ChatViewModel.queuedPromptHoldsTurn(
            name: "steer", isNonInterruptive: true, wasAgentWorking: true, capabilities: Self.v0225))
    }

    /// Declining gateway-backed ACP's guarded-model confirmation is not an
    /// error; every other failure keeps its banner.
    @Test func declinedModelSwitchShowsNoBanner() {
        let declined = ACPClientError.rpcError(code: -32603, message: "Internal error", details: "model_switch_cancelled")
        #expect(ChatViewModel.modelSwitchFailureBanner(declined) == nil)

        let failed = ACPClientError.rpcError(code: -32603, message: "Internal error", details: "unsupported_model_options")
        let banner = ChatViewModel.modelSwitchFailureBanner(failed)
        #expect(banner?.hasPrefix("Couldn't switch model: ") == true)
        #expect(ChatViewModel.modelSwitchFailureBanner(ACPClientError.requestTimeout(method: "session/set_model")) != nil)
    }
}
