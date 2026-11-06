import Testing
import Foundation
@testable import ScarfCore

/// S4 — gateway-backed ACP `configOptions` (Hermes v0.22.6 / v0.23.0):
/// decode, `session/set_config_option` round-trip, gating, `/model reset`
/// gating and the `ultrafast` service tier.
@Suite struct ACPConfigOptionTests {

    static func caps(_ line: String) -> HermesCapabilities { HermesCapabilities.parseLine(line) }
    static let v0230 = caps("Hermes Agent v0.23.0 (2026.9.24) · stable · local 90d6b98fd86d")
    static let v0227 = caps("Hermes Agent v0.22.7 (2026.9.24) · stable · local abc1234def56")
    static let v0226 = caps("Hermes Agent v0.22.6 (2026.9.24) · stable · local abc1234def56")
    static let v0225 = caps("Hermes Agent v0.22.5 (2026.9.24) · stable · local abc1234def56")
    static let v0216 = caps("Hermes Agent v0.21.6 (2026.9.24) · stable · local abc1234def56")
    static let v0215 = caps("Hermes Agent v0.21.5 (2026.9.24) · stable · local abc1234def56")

    /// Shape of `_session_fields` / `config_options` @ v0.23.0 with an unset
    /// effort (`default` listed) and an unavailable current tier row.
    static let optionsJSON = #"""
    [
      {"id":"edit_approval_policy","name":"Edits","category":"mode","type":"select","currentValue":"ask",
       "options":[{"value":"ask","name":"Ask"},{"value":"workspace_session","name":"Workspace"},{"value":"session","name":"Session"}]},
      {"id":"model","name":"Model","category":"model","type":"select","currentValue":"openai:gpt-5",
       "options":[{"value":"openai:gpt-5","name":"GPT-5"}]},
      {"id":"reasoning_effort","name":"Reasoning effort","category":"thought_level","type":"select","currentValue":"default",
       "options":[{"value":"default","name":"default"},{"value":"none","name":"none"},{"value":"minimal","name":"minimal"},
                  {"value":"low","name":"low"},{"value":"medium","name":"medium"},{"value":"high","name":"high"},
                  {"value":"xhigh","name":"xhigh"},{"value":"max","name":"max"},{"value":"ultra","name":"ultra"}]},
      {"id":"service_tier","name":"Service tier","category":"other","type":"select","currentValue":"ultrafast",
       "options":[{"value":"normal","name":"Normal"},{"value":"fast","name":"Fast"},
                  {"value":"ultrafast","name":"Ultrafast (unavailable on this route)"}]},
      {"id":"future_knob","name":"Future","category":"other","type":"boolean","currentValue":true,"options":[]},
      {"name":"no id"}
    ]
    """#

    static func parsed() throws -> [ACPConfigOption] {
        let any = try JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))
        return try #require(ACPConfigOption.parseList(any))
    }

    // MARK: decode

    @Test func decodesReplyListKeepingUnknownIds() throws {
        let opts = try Self.parsed()
        #expect(opts.map(\.id) == ["edit_approval_policy", "model", "reasoning_effort", "service_tier", "future_knob"])
        let effort = try #require(opts.first { $0.id == "reasoning_effort" })
        #expect(effort.currentValue == "default")
        #expect(effort.choices.first?.value == "default")
        #expect(effort.choices.count == 9)
        let tier = try #require(opts.first { $0.id == "service_tier" })
        #expect(tier.currentChoice?.name == "Ultrafast (unavailable on this route)")
        let future = try #require(opts.first { $0.id == "future_knob" })
        #expect(future.currentValue == "true")
        #expect(future.type == "boolean")
    }

    @Test func sessionStateReadsConfigOptions() throws {
        let any = try JSONSerialization.jsonObject(with: Data(Self.optionsJSON.utf8))
        let state = ACPSessionState(response: ["configOptions": any, "models": ["currentModelId": "openai:gpt-5"]])
        #expect(state.configOptions?.count == 5)
        #expect(ACPSessionState(response: [:]).configOptions == nil)
    }

    @Test func parsesConfigOptionUpdateNotification() throws {
        // Effort now set: `default` no longer offered (only while unset).
        let line = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{
          "sessionUpdate":"config_option_update","configOptions":[
            {"id":"reasoning_effort","name":"Reasoning effort","category":"thought_level","type":"select","currentValue":"high",
             "options":[{"value":"none","name":"none"},{"value":"high","name":"high"}]}]}}}
        """#
        let raw = try JSONDecoder().decode(ACPRawMessage.self, from: Data(line.utf8))
        guard case let .configOptionUpdate(sid, options)? = ACPEventParser.parse(notification: raw) else {
            Issue.record("expected configOptionUpdate"); return
        }
        #expect(sid == "s1")
        #expect(options.first?.currentValue == "high")
        #expect(!(options.first?.choices.contains { $0.value == "default" } ?? true))
    }

    @Test func malformedUpdateFallsThroughToUnknown() throws {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"config_option_update"}}}"#
        let raw = try JSONDecoder().decode(ACPRawMessage.self, from: Data(line.utf8))
        guard case .unknown(_, "config_option_update")? = ACPEventParser.parse(notification: raw) else {
            Issue.record("expected unknown"); return
        }
    }

    // MARK: gating

    @Test func gatingPerHost() throws {
        let opts = try Self.parsed()
        #expect(ACPConfigOption.visiblePickers(opts, capabilities: .empty).isEmpty)
        #expect(ACPConfigOption.visiblePickers(opts, capabilities: Self.v0225).isEmpty, "pre-v0.22.6")
        #expect(ACPConfigOption.visiblePickers(opts, capabilities: Self.v0226).map(\.id) == ["reasoning_effort"])
        #expect(ACPConfigOption.visiblePickers(opts, capabilities: Self.v0230).map(\.id) == ["reasoning_effort", "service_tier"])
        // In-process ACP (pre-gateway host) never builds pickers, even from a list.
        let inProcess = Self.caps("Hermes Agent v0.22.0 (2026.9.24)")
        #expect(!inProcess.hasGatewayBackedACP)
        #expect(ACPConfigOption.visiblePickers(opts, capabilities: inProcess).isEmpty)
    }

    @Test @MainActor func richChatIgnoresOptionsOffGateway() throws {
        let vm = RichChatViewModel()
        vm.capabilitiesGate = Self.v0225
        vm.applyConfigOptions(try Self.parsed())
        #expect(vm.acpConfigOptions.isEmpty)
        #expect(vm.configPickers.isEmpty)
        vm.capabilitiesGate = Self.v0230
        vm.applyConfigOptions(try Self.parsed())
        #expect(vm.configPickers.map(\.id) == ["reasoning_effort", "service_tier"])
    }

    @Test func modelResetGating() {
        #expect(!Self.v0225.hasModelReset)
        #expect(Self.v0226.hasModelReset && Self.v0226.hasGatewayBackedACP)
        #expect(Self.v0230.hasModelReset)
    }

    // MARK: refusal text

    @Test func busyRefusalShowsHermesText() {
        let text = "Reasoning effort changes apply when the session is idle; try again after this turn."
        #expect(ACPConfigOption.refusalText(for: ACPClientError.rpcError(code: -32603, message: text)) == text)
        #expect(ACPConfigOption.refusalText(for: ACPClientError.rpcError(
            code: -32603, message: "Internal error", details: "invalid_params")) == "invalid_params")
    }

    // MARK: ultrafast

    @Test func ultrafastServiceTierGated() {
        #expect(HermesServiceTier.normalize("ultrafast") == .off)
        #expect(HermesServiceTier.normalize("ultrafast", capabilities: Self.v0215) == .off)
        #expect(HermesServiceTier.normalize("ultra", capabilities: Self.v0216) == .ultrafast)
        #expect(HermesServiceTier.normalize("ultrafast", capabilities: Self.v0226) == .ultrafast)
        #expect(HermesServiceTier.ultrafast.configValue == "ultrafast")
        #expect(!HermesServiceTier.options(capabilities: Self.v0215, current: .off).contains(.ultrafast))
        #expect(HermesServiceTier.options(capabilities: Self.v0216, current: .off).contains(.ultrafast))
        #expect(HermesServiceTier.options(capabilities: Self.v0230, current: .off) == [.off, .always, .auto, .cold, .ultrafast])
    }
}

/// `session/set_config_option` over a scripted channel.
@Suite struct ACPSetConfigOptionRoundTripTests {
    actor Channel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let inCont: AsyncThrowingStream<String, Error>.Continuation
        private let errCont: AsyncThrowingStream<String, Error>.Continuation
        private(set) var sent: [String] = []
        var diagnosticID: String? { "s4-mock" }
        init() {
            (incoming, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            (stderr, errCont) = AsyncThrowingStream<String, Error>.makeStream()
        }
        func send(_ line: String) async throws { sent.append(line) }
        func close() async { inCont.finish(); errCont.finish() }
        func reply(_ line: String) { inCont.yield(line) }
        func lastId() -> Int? {
            guard let l = sent.last,
                  let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] else { return nil }
            return o["id"] as? Int
        }
        func lastLine() -> String? { sent.last }
    }

    private func poll(_ cond: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await cond() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out")
    }

    private func started() async throws -> (ACPClient, Channel) {
        let ch = Channel()
        let client = ACPClient(context: .local) { _ in ch }
        let start = Task { try await client.start() }
        try await poll { await ch.sent.count >= 1 }
        let id = await ch.lastId() ?? 1
        await ch.reply(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        try await start.value
        return (client, ch)
    }

    @Test func roundTripReturnsRefreshedList() async throws {
        let (client, ch) = try await started()
        let call = Task { try await client.setConfigOption(sessionId: "s1", configId: "service_tier", value: "fast") }
        try await poll { await ch.sent.count >= 2 }
        let line = try #require(await ch.lastLine())
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["method"] as? String == "session/set_config_option")
        let params = try #require(obj["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "s1")
        #expect(params["configId"] as? String == "service_tier")
        #expect(params["value"] as? String == "fast")
        let id = try #require(obj["id"] as? Int)
        await ch.reply(#"{"jsonrpc":"2.0","id":\#(id),"result":{"configOptions":[{"id":"service_tier","name":"Service tier","type":"select","currentValue":"fast","options":[{"value":"normal","name":"Normal"},{"value":"fast","name":"Fast"}]}]}}"#)
        let options = try await call.value
        #expect(options.first?.currentValue == "fast")
        await client.stop()
    }

    @Test func busyRefusalThrowsWithHermesText() async throws {
        let (client, ch) = try await started()
        let call = Task { try await client.setConfigOption(sessionId: "s1", configId: "reasoning_effort", value: "high") }
        try await poll { await ch.sent.count >= 2 }
        let id = try #require(await ch.lastId())
        await ch.reply(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"Reasoning effort changes apply when the session is idle; try again after this turn."}}"#)
        do {
            _ = try await call.value
            Issue.record("expected throw")
        } catch {
            #expect(ACPConfigOption.refusalText(for: error).hasPrefix("Reasoning effort changes apply"))
        }
        await client.stop()
    }
}
