import Testing
import Foundation
@testable import ScarfCore

/// R10 (Hermes v0.21.5 audit remediation) — the ScarfCore halves of the
/// chat-controller fixes:
///
/// - S02-F3: `closeReplayGate()` shuts the gate the echo opened, so a
///   `session/load` replay after an autostart echo is dropped.
/// - S01-F2: `ACPStallPolicy` — ScarfGo's stall detector must not tear a
///   turn down while a permission prompt waits or a tool call runs.
/// - S11-F3: `ProjectModelPresetApplier` — the shared path both the Mac and
///   ScarfGo use to apply a project's bound model preset.
@Suite struct ChatControllersR10Tests {

    // MARK: - S02-F3 replay gate

    /// The autostart order: echo (opens the gate), close it again, then
    /// the load replay streams in. Nothing may paint until the prompt is
    /// marked sent; after that live chunks flow.
    @Test @MainActor func closeReplayGateDropsReplayAfterAnEcho() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "new question")
        vm.closeReplayGate()

        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "REPLAYED reply"))
        vm.handleACPEvent(.toolCallStart(
            sessionId: "s",
            call: ACPToolCallEvent(
                toolCallId: "old-1", title: "terminal: ls",
                kind: "execute", status: "pending", content: "", rawInput: nil
            )
        ))
        #expect(!vm.messages.contains { $0.content.contains("REPLAYED") })
        #expect(!vm.messages.contains { $0.toolCalls.contains { $0.callId == "old-1" } })
        // The echo itself survives the gate change.
        #expect(vm.messages.filter(\.isUser).map(\.content) == ["new question"])

        vm.markPromptSent()
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "live answer"))
        #expect(vm.messages.contains { $0.isAssistant && $0.content == "live answer" })
    }

    // MARK: - S01-F2 open tool calls

    @Test @MainActor func hasToolCallInFlightTracksStartAndCompletion() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.markPromptSent()
        #expect(!vm.hasToolCallInFlight)
        vm.handleACPEvent(.toolCallStart(
            sessionId: "s",
            call: ACPToolCallEvent(
                toolCallId: "t1", title: "terminal: npm install",
                kind: "execute", status: "in_progress", content: "", rawInput: nil
            )
        ))
        #expect(vm.hasToolCallInFlight)
        vm.handleACPEvent(.toolCallUpdate(
            sessionId: "s",
            update: ACPToolCallUpdateEvent(
                toolCallId: "t1", kind: "execute",
                status: "completed", content: "done", rawOutput: nil
            )
        ))
        #expect(!vm.hasToolCallInFlight)
    }

    // MARK: - S01-F2 stall policy

    @Test func streamingSilencePastThresholdIsAStall() {
        #expect(ACPStallPolicy.isStalled(
            idleSeconds: 80, isAgentWorking: true,
            permissionPending: false, toolCallInFlight: false))
        #expect(!ACPStallPolicy.isStalled(
            idleSeconds: 60, isAgentWorking: true,
            permissionPending: false, toolCallInFlight: false))
    }

    @Test func idleAgentIsNeverAStall() {
        #expect(!ACPStallPolicy.isStalled(
            idleSeconds: 10_000, isAgentWorking: false,
            permissionPending: false, toolCallInFlight: false))
    }

    /// The audit's scenario: the user hesitates 80 s over an approval.
    /// Hermes is blocked on the answer and sends nothing.
    @Test func pendingPermissionIsNeverAStall() {
        #expect(!ACPStallPolicy.isStalled(
            idleSeconds: 80, isAgentWorking: true,
            permissionPending: true, toolCallInFlight: false))
        #expect(!ACPStallPolicy.isStalled(
            idleSeconds: 10_000, isAgentWorking: true,
            permissionPending: true, toolCallInFlight: true))
    }

    /// A two-minute build is silent but alive; a socket that died mid-tool
    /// is still caught once the tool ceiling passes.
    @Test func runningToolGetsTheLongCeilingNotAnExemption() {
        #expect(!ACPStallPolicy.isStalled(
            idleSeconds: 120, isAgentWorking: true,
            permissionPending: false, toolCallInFlight: true))
        #expect(!ACPStallPolicy.isStalled(
            idleSeconds: 610, isAgentWorking: true,
            permissionPending: false, toolCallInFlight: true))
        #expect(ACPStallPolicy.isStalled(
            idleSeconds: ACPStallPolicy.toolCallSeconds + 1, isAgentWorking: true,
            permissionPending: false, toolCallInFlight: true))
    }

    /// The minutes spent on the approval sheet don't count once it is
    /// answered: the clock restarts at the answer.
    @Test func silenceClockRestartsWhenThePermissionIsAnswered() {
        #expect(!ACPStallPolicy.isStalled(
            idleSeconds: 200, secondsSincePermissionAnswered: 5,
            isAgentWorking: true, permissionPending: false, toolCallInFlight: false))
        #expect(ACPStallPolicy.isStalled(
            idleSeconds: 200, secondsSincePermissionAnswered: 90,
            isAgentWorking: true, permissionPending: false, toolCallInFlight: false))
    }

    // MARK: - S11-F3 model preset

    /// Answers `initialize`, records every request, and answers
    /// `session/set_model` with success or the JSON-RPC error Hermes
    /// raises for a model no provider can serve (-32602,
    /// `acp_adapter/server.py:1035-1041` @ v2026.9.24).
    actor PresetChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let rejectSetModel: Bool
        private(set) var setModelParams: [[String: Any]] = []

        var diagnosticID: String? { "preset-channel" }

        init(rejectSetModel: Bool) {
            self.rejectSetModel = rejectSetModel
            (incoming, incomingCont) = AsyncThrowingStream<String, Error>.makeStream()
            (stderr, stderrCont) = AsyncThrowingStream<String, Error>.makeStream()
        }

        func send(_ line: String) async throws {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String,
                  let id = obj["id"] as? Int else { return }
            if method == "session/set_model" {
                setModelParams.append(obj["params"] as? [String: Any] ?? [:])
                if rejectSetModel {
                    reply(["jsonrpc": "2.0", "id": id,
                           "error": ["code": -32602, "message": "Invalid params",
                                     "data": ["details": "model not available"]] as [String: Any]])
                    return
                }
            }
            reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
        }

        var setModelCount: Int { setModelParams.count }
        var lastModelId: String? { setModelParams.last?["modelId"] as? String }

        func close() async {
            incomingCont.finish()
            stderrCont.finish()
        }

        private func reply(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }
    }

    /// A temp Hermes home plus a temp project dir, removed afterwards.
    static func withProject(
        manifest: String?,
        presets: [ModelPreset],
        _ body: (ServerContext, String) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r10-preset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("hermes", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".scarf"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let manifest {
            try manifest.write(
                to: project.appendingPathComponent(".scarf/manifest.json"),
                atomically: true, encoding: .utf8)
        }
        let ctx = ServerContext.local(home: home)
        // Written through Scarf's own service, then read back by the applier.
        let service = ModelPresetService(context: ctx)
        for preset in presets { try await service.upsert(preset) }
        try await body(ctx, project.path)
    }

    static func startedClient(_ channel: PresetChannel, context: ServerContext) async throws -> ACPClient {
        let client = ACPClient(context: context) { _ in channel }
        try await client.start()
        return client
    }

    @Test func appliesTheBoundPresetWithProviderEncodedModel() async throws {
        let preset = ModelPreset(name: "Opus-fast", modelID: "claude-opus-4", providerID: "anthropic")
        try await Self.withProject(
            manifest: #"{"modelPresetID": "\#(preset.id.uuidString)"}"#,
            presets: [preset]
        ) { ctx, path in
            let channel = PresetChannel(rejectSetModel: false)
            let client = try await Self.startedClient(channel, context: ctx)
            defer { Task { await client.stop() } }
            let outcome = await ProjectModelPresetApplier.apply(
                client: client, sessionId: "s1", projectPath: path, context: ctx)
            // By id: the store round-trips dates through JSON, so the read
            // preset isn't bit-identical to the one written.
            #expect(outcome.appliedPreset?.id == preset.id)
            #expect(outcome.appliedPreset?.modelID == "claude-opus-4")
            #expect(await channel.setModelCount == 1)
            #expect(await channel.lastModelId == "anthropic:claude-opus-4")
        }
    }

    /// Hermes refuses: the outcome says so and no preset is reported as
    /// applied — nothing may claim the session runs on it.
    @Test func rejectedSetModelIsNotReportedAsApplied() async throws {
        let preset = ModelPreset(name: "Gone", modelID: "no-such-model", providerID: "")
        try await Self.withProject(
            manifest: #"{"modelPresetID": "\#(preset.id.uuidString)"}"#,
            presets: [preset]
        ) { ctx, path in
            let channel = PresetChannel(rejectSetModel: true)
            let client = try await Self.startedClient(channel, context: ctx)
            defer { Task { await client.stop() } }
            let outcome = await ProjectModelPresetApplier.apply(
                client: client, sessionId: "s1", projectPath: path, context: ctx)
            guard case .rejected(let rejected, _) = outcome else {
                Issue.record("expected .rejected, got \(outcome)")
                return
            }
            #expect(rejected.id == preset.id)
            #expect(outcome.appliedPreset == nil)
            // Empty providerID → bare model id on the wire.
            #expect(await channel.lastModelId == "no-such-model")
        }
    }

    @Test func noBindingSendsNoRPC() async throws {
        try await Self.withProject(manifest: #"{"name": "p"}"#, presets: []) { ctx, path in
            let channel = PresetChannel(rejectSetModel: false)
            let client = try await Self.startedClient(channel, context: ctx)
            defer { Task { await client.stop() } }
            let outcome = await ProjectModelPresetApplier.apply(
                client: client, sessionId: "s1", projectPath: path, context: ctx)
            #expect(outcome == .noBinding)
            #expect(await channel.setModelCount == 0)
        }
    }

    @Test func deletedPresetSendsNoRPC() async throws {
        let dangling = UUID().uuidString
        try await Self.withProject(
            manifest: #"{"modelPresetID": "\#(dangling)"}"#, presets: []
        ) { ctx, path in
            let channel = PresetChannel(rejectSetModel: false)
            let client = try await Self.startedClient(channel, context: ctx)
            defer { Task { await client.stop() } }
            let outcome = await ProjectModelPresetApplier.apply(
                client: client, sessionId: "s1", projectPath: path, context: ctx)
            #expect(outcome == .presetMissing(id: dangling))
            #expect(await channel.setModelCount == 0)
        }
    }

    // MARK: - S11-F3 project context block

    /// The block no longer tells the agent the preset "already applied" —
    /// it may not have been.
    @Test func contextBlockDoesNotClaimThePresetIsApplied() {
        let block = ProjectContextBlock.renderManagedBlock(.init(
            projectName: "P", projectPath: "/tmp/p", configFieldsLine: "(none)"
        ))
        #expect(block.contains("Per-project model preset"))
        #expect(!block.contains("already applied"))
    }
}
