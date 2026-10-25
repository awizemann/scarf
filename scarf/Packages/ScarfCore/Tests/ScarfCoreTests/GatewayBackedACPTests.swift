import Testing
import Foundation
@testable import ScarfCore

/// Hermes v0.22.5 parity, slice S4 — `hermes acp` as a viewer of the profile
/// gateway (`HermesCapabilities.hasGatewayBackedACP`, 0.22.1 and 0.22.3+).
/// Every behaviour change is gated; each test pins the pre-gateway answer
/// next to the gateway one.
@Suite struct GatewayBackedACPTests {

    static let gateway = HermesCapabilities.parseLine(HermesCapabilitiesTests.v0225Line)
    static let inProcess = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")

    /// What gateway-backed ACP sends for a refused `session/load`: the acp
    /// lib's `-32603 Internal error` wrapping `GatewayRPCError("not_found")`.
    static let gatewayNotFound = ACPClientError.rpcError(code: -32603, message: "Internal error", details: "not_found")

    // MARK: - Resume

    @Test func gatewayLoadsLocalAndLegacyLocalSources() {
        #expect(Self.gateway.hasGatewayBackedACP)
        for source in ["local", "acp", "cli", "tui", "gui", "desktop", "oneshot", "tool"] {
            #expect(SessionResume.unloadableSource(source, gatewayBacked: true) == nil, "\(source)")
        }
        // Rows that need their own authority still continue as new.
        for source in ["webui", "cron", "telegram", "api_server"] {
            #expect(SessionResume.unloadableSource(source, gatewayBacked: true) == source, "\(source)")
        }
        // Pre-gateway hosts: unchanged, only `acp` loads.
        #expect(SessionResume.unloadableSource("local") == "local")
        #expect(SessionResume.unloadableSource("cli") == "cli")
    }

    @Test func onlyTheGatewayNotFoundIsNotRestorable() {
        #expect(SessionResume.isNotRestorable(Self.gatewayNotFound, gatewayBacked: true))
        #expect(!SessionResume.isNotRestorable(Self.gatewayNotFound))
        // Any other -32603 is real and surfaces.
        #expect(!SessionResume.isNotRestorable(
            ACPClientError.rpcError(code: -32603, message: "Internal error", details: "permission_denied"),
            gatewayBacked: true))
        #expect(!SessionResume.isNotRestorable(
            ACPClientError.rpcError(code: -32603, message: "Internal error"), gatewayBacked: true))
        #expect(!SessionResume.isNotRestorable(
            ACPClientError.rpcError(code: -32602, message: "not_found", details: "not_found"), gatewayBacked: true))
        #expect(SessionResume.isNotRestorable(ACPClientError.sessionNotRestorable(sessionId: "x"), gatewayBacked: true))
    }

    @Test func gatewayResumeLoadsALocalSessionAndFallsBackOnNotFound() async throws {
        let loaded = try await SessionResume.resolve(
            sessionId: "s1", source: "local", gatewayBacked: true,
            load: { id in (id, nil) },
            newSession: { Issue.record("must not create"); return "new" }
        )
        #expect(loaded == .loaded(sessionId: "s1", head: nil))

        let fellBack = try await SessionResume.resolve(
            sessionId: "s1", source: "local", gatewayBacked: true,
            load: { _ in throw Self.gatewayNotFound },
            newSession: { "new" }
        )
        #expect(fellBack == .continuedAsNew(sessionId: "new", reason: .notRestorable))

        // Pre-gateway: `local` is never loaded.
        let skipped = try await SessionResume.resolve(
            sessionId: "s1", source: "local",
            load: { _ in Issue.record("must not load"); return ("s1", nil) },
            newSession: { "new" }
        )
        #expect(skipped == .continuedAsNew(sessionId: "new", reason: .nonACPSource("local")))
    }

    // MARK: - Errors

    @Test func gatewayRefusalMatchesTheExactCode() {
        #expect(ACPClientError.isGatewayRefusal(
            ACPClientError.rpcError(code: -32603, message: "Internal error", details: "model_switch_cancelled"),
            reason: "model_switch_cancelled"))
        #expect(!ACPClientError.isGatewayRefusal(Self.gatewayNotFound, reason: "model_switch_cancelled"))
        #expect(!ACPClientError.isGatewayRefusal(CancellationError(), reason: "not_found"))
    }

    @Test func daemonStartFailuresGetReadableHints() {
        let policy = ACPClientError.rpcError(code: -32603, message: "Internal error", details: "acp_policy_unavailable")
        let hint = ACPErrorHint.classify(errorMessage: policy.localizedDescription, stderrTail: "")
        #expect(hint?.hint.contains("hermes gateway restart") == true)

        let profile = ACPClientError.rpcError(code: -32603, message: "Internal error", details: "profile_mismatch")
        #expect(ACPErrorHint.classify(errorMessage: profile.localizedDescription, stderrTail: "")?
            .hint.contains("different profile") == true)
    }

    // MARK: - Permission cards (clarify, model confirmation)

    static let clarifyRequest = #"""
    {"jsonrpc": "2.0", "id": 9, "method": "session/request_permission", "params": {
      "sessionId": "s",
      "toolCall": {"toolCallId": "clarify-p1", "title": "Which branch?", "kind": "other", "status": "pending"},
      "options": [{"optionId": "choice-0", "kind": "allow_once", "name": "main"},
                  {"optionId": "choice-1", "kind": "allow_once", "name": "dev"},
                  {"optionId": "skip", "kind": "reject_once", "name": "Skip"}]}}
    """#

    @Test func optionKindDecidesAllowOrDeny() throws {
        let event = try #require(ACPEventParser.parsePermissionRequest(try HermesV0215R18bTests.raw(Self.clarifyRequest)))
        guard case let .permissionRequest(_, _, request) = event else {
            Issue.record("not a permission request"); return
        }
        #expect(request.optionKinds == ["choice-0": "allow_once", "choice-1": "allow_once", "skip": "reject_once"])
        // By id alone `skip` reads as an allow; its kind says it is not.
        #expect(RichChatViewModel.permissionOptionAllows("skip"))
        #expect(!RichChatViewModel.permissionOptionAllows("skip", kind: "reject_once"))
        #expect(RichChatViewModel.permissionOptionAllows("choice-0", kind: "allow_once"))
        // Hermes's tool-approval ids agree with their kinds.
        #expect(!RichChatViewModel.permissionOptionAllows("deny", kind: "reject_once"))
        #expect(!RichChatViewModel.permissionOptionAllows("deny_always", kind: "reject_always"))
        #expect(RichChatViewModel.permissionOptionAllows("allow_session", kind: "allow_always"))
    }

    @MainActor
    @Test func gatewayCardsGetTheirOwnPromptKind() throws {
        let vm = RichChatViewModel(context: .local)
        vm.publishCapabilities(Self.gateway)
        vm.setSessionId("s")
        vm.handleACPEvent(try #require(ACPEventParser.parsePermissionRequest(try HermesV0215R18bTests.raw(Self.clarifyRequest))))
        let card = try #require(vm.pendingPermission)
        #expect(card.prompt == .clarify)
        #expect(card.prompt.heading != nil)
        #expect(card.title == "Which branch?")
        #expect(!card.optionAllows("skip"))
        #expect(card.optionAllows("choice-1"))

        #expect(RichChatViewModel.PermissionPrompt(toolCallId: "model-confirm-abc", gatewayBacked: true) == .modelConfirmation)
        #expect(RichChatViewModel.PermissionPrompt(toolCallId: "perm-check-1", gatewayBacked: true) == .toolApproval)
        // Pre-gateway hosts: every card stays a tool approval.
        #expect(RichChatViewModel.PermissionPrompt(toolCallId: "clarify-p1", gatewayBacked: false) == .toolApproval)
        #expect(RichChatViewModel.PermissionPrompt.toolApproval.heading == nil)
    }

    // MARK: - current_mode_update

    static let modeUpdate = #"""
    {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s",
      "update": {"sessionUpdate": "current_mode_update", "currentModeId": "accept_edits"}}}
    """#

    @MainActor
    @Test func currentModeUpdateMovesTheChipOnGatewayHosts() throws {
        let event = try #require(ACPEventParser.parse(notification: try HermesV0215R18bTests.raw(Self.modeUpdate)))
        guard case let .currentModeUpdate(sid, modeId) = event else {
            Issue.record("not parsed as current_mode_update"); return
        }
        #expect(sid == "s")
        #expect(modeId == "accept_edits")

        let vm = RichChatViewModel(context: .local)
        vm.publishCapabilities(Self.gateway)
        vm.setSessionId("s")
        vm.handleACPEvent(event)
        #expect(vm.activeApprovalMode == .acceptEdits)

        let old = RichChatViewModel(context: .local)
        old.publishCapabilities(Self.inProcess)
        old.setSessionId("s")
        old.handleACPEvent(event)
        #expect(old.activeApprovalMode == .default)
    }

    // MARK: - Usage is a running total

    @MainActor
    @Test func promptUsageReplacesRatherThanAccumulates() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "one")
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn", inputTokens: 100, outputTokens: 10, thoughtTokens: 1, cachedReadTokens: 50)))
        vm.addUserMessage(text: "two")
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn", inputTokens: 250, outputTokens: 30, thoughtTokens: 2, cachedReadTokens: 120)))
        #expect(vm.acpInputTokens == 250)
        #expect(vm.acpOutputTokens == 30)
        #expect(vm.acpThoughtTokens == 2)
        #expect(vm.acpCachedReadTokens == 120)
        // A synthesized failure (all zeros) keeps the running total.
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "error", inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0)))
        #expect(vm.acpInputTokens == 250)
    }

    // MARK: - Connection loss

    @Test func connectionLostNoteNeverSaysTheGatewayTurnStopped() {
        let old = RichChatViewModel.connectionLostNote(reason: "x", gatewayBacked: false)
        #expect(old == "Connection lost: x. Use the Session menu to start or resume a session.")
        let gateway = RichChatViewModel.connectionLostNote(reason: "x", gatewayBacked: true)
        #expect(gateway.contains("keeps running"))
    }

    // MARK: - Compression tip without provenance

    #if canImport(SQLite3)
    @MainActor
    @Test func followsAnUnannouncedRotationFromStateDB() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: """
            INSERT INTO sessions (id, source, parent_session_id, started_at, ended_at, end_reason)
            VALUES ('root', 'local', NULL, 1, 2, 'compression'),
                   ('mid', 'local', 'root', 2, 3, 'compression'),
                   ('tip', 'local', 'mid', 3, NULL, NULL);
            """)
        defer { try? FileManager.default.removeItem(at: home) }

        let vm = RichChatViewModel(context: .local(home: home))
        vm.publishCapabilities(Self.gateway)
        vm.setSessionId("root")
        #expect(await vm.followCompressionTipFromDB())
        #expect(vm.transcriptSessionIds == ["root", "mid", "tip"])
        // Nothing new: no growth.
        #expect(!(await vm.followCompressionTipFromDB()))

        // Pre-gateway hosts follow provenance only.
        let old = RichChatViewModel(context: .local(home: home))
        old.publishCapabilities(Self.inProcess)
        old.setSessionId("root")
        #expect(!(await old.followCompressionTipFromDB()))
        #expect(old.transcriptSessionIds == ["root"])
    }
    #endif
}
