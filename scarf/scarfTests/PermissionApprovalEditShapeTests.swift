import Testing
import Foundation
import ScarfCore
@testable import scarf

/// The "Allow edits for this session" button on the tool-approval
/// dialog: WHEN it is offered, and what it answers with.
///
/// The button flips the whole session's approval posture off one click,
/// so the interesting assertions are the negatives — it must not appear
/// on a shell command, a delete, a host that can't be told, or a request
/// whose options don't contain an unambiguous single allow.
@Suite struct PermissionApprovalEditShapeTests {

    private func view(
        kind: String,
        options: [(optionId: String, name: String)],
        allowForSession: Bool = true
    ) -> PermissionApprovalView {
        PermissionApprovalView(
            title: "Approve edit: /p/one/src/main.swift",
            kind: kind,
            options: options,
            onRespond: { _ in },
            onAllowForSession: allowForSession ? { _ in } : nil
        )
    }

    /// Hermes's real edit-approval shape — `acp_adapter/edit_approval.py`
    /// builds `kind="edit"` with exactly `allow_once` + `deny`.
    private var hermesEditOptions: [(optionId: String, name: String)] {
        [(optionId: "allow_once", name: "Allow edit"), (optionId: "deny", name: "Deny")]
    }

    @Test func editRequestOffersTheButtonAndAnswersWithTheAllowOption() {
        let v = view(kind: "edit", options: hermesEditOptions)
        #expect(v.sessionAllowOptionId == "allow_once")
    }

    /// A shell command is not an edit. `accept_edits` wouldn't even
    /// silence it, so offering the button there would be a lie about
    /// what the click does.
    @Test func executeRequestDoesNotOfferTheButton() {
        #expect(view(kind: "execute", options: hermesEditOptions).sessionAllowOptionId == nil)
    }

    @Test func deleteAndUnknownKindsDoNotOfferTheButton() {
        #expect(view(kind: "delete", options: hermesEditOptions).sessionAllowOptionId == nil)
        #expect(view(kind: "other", options: hermesEditOptions).sessionAllowOptionId == nil)
        #expect(view(kind: "", options: hermesEditOptions).sessionAllowOptionId == nil)
    }

    /// C1: pre-v0.15 the caller passes no handler, because there is no
    /// `session/set_mode` to send — the dialog renders as it always did.
    @Test func hostWithoutSetModeDoesNotOfferTheButton() {
        #expect(
            view(kind: "edit", options: hermesEditOptions, allowForSession: false)
                .sessionAllowOptionId == nil
        )
    }

    /// Hermes owns the option list (v0.20 parses reduced sets
    /// generically). A request with nothing affirmative in it must not
    /// grow an approve button Hermes didn't offer — the only thing the
    /// user could legitimately do here is deny.
    @Test func denyOnlyRequestDoesNotOfferTheButton() {
        let v = view(kind: "edit", options: [(optionId: "deny", name: "Deny")])
        #expect(v.sessionAllowOptionId == nil)
        #expect(view(kind: "edit", options: []).sessionAllowOptionId == nil)
    }

    /// Two allows means Scarf would have to GUESS which one the button
    /// sends — an allow-once and an allow-always are very different
    /// answers. It declines to guess.
    @Test func ambiguousMultipleAllowsDoNotOfferTheButton() {
        let v = view(kind: "edit", options: [
            (optionId: "allow_once", name: "Allow edit"),
            (optionId: "allow_always", name: "Always allow"),
            (optionId: "deny", name: "Deny"),
        ])
        #expect(v.sessionAllowOptionId == nil)
    }
}

/// The other half of the button: pressing it must both answer the
/// pending request AND flip the live session's mode — and if the host
/// refuses the mode change, the chip must not keep claiming a posture
/// the session isn't in.
@Suite struct AllowEditsForSessionActionTests {

    /// Scripted channel that boots a session and can be told to REFUSE
    /// `session/set_mode`, which is the revert path.
    actor ModeChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let sessionId: String
        private let rejectSetMode: Bool

        private(set) var requestedModeIds: [String] = []
        private(set) var permissionResponses: [String] = []

        var diagnosticID: String? { "mode-channel" }

        init(sessionId: String, rejectSetMode: Bool = false) {
            self.sessionId = sessionId
            self.rejectSetMode = rejectSetMode
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            self.incoming = inStream
            self.incomingCont = inCont
            self.stderr = errStream
            self.stderrCont = errCont
        }

        func send(_ line: String) async throws {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            // A response to the agent's session/request_permission carries
            // no method — it's a JSON-RPC result keyed by the request id.
            guard let method = obj["method"] as? String else {
                if let result = obj["result"] as? [String: Any],
                   let outcome = result["outcome"] as? [String: Any],
                   let optionId = outcome["optionId"] as? String {
                    permissionResponses.append(optionId)
                }
                return
            }

            if method == "session/set_mode",
               let params = obj["params"] as? [String: Any],
               let modeId = params["modeId"] as? String {
                requestedModeIds.append(modeId)
            }
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/new", "session/load":
                reply(["jsonrpc": "2.0", "id": id,
                       "result": ["sessionId": sessionId,
                                  "modes": ["currentModeId": "default"]]])
            case "session/set_mode" where rejectSetMode:
                reply(["jsonrpc": "2.0", "id": id,
                       "error": ["code": -32603, "message": "scripted set_mode refusal"]])
            case "session/prompt":
                break
            default:
                reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        private func reply(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            incomingCont.yield(line)
        }

        func close() async {
            incomingCont.finish()
            stderrCont.finish()
        }
    }

    @MainActor
    private func bootedViewModel(
        home: TempHermesHome, rejectSetMode: Bool = false
    ) async -> (ChatViewModel, ModeChannel) {
        let vm = ChatViewModel(context: home.context)
        let channel = ModeChannel(sessionId: "sess-BTN", rejectSetMode: rejectSetMode)
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.startNewSession()
        _ = await ChatViewModelAutoAcceptEditsTests.waitUntil {
            vm.richChatViewModel.sessionId == "sess-BTN"
        }
        return (vm, channel)
    }

    /// What the button's closure does, in order: answer the request with
    /// the allow option, then set the mode.
    @Test @MainActor func pressingItApprovesTheRequestAndFlipsTheMode() async throws {
        let home = try ChatViewModelAutoAcceptEditsTests.configuredHome()
        defer { home.cleanup() }
        let (vm, channel) = await bootedViewModel(home: home)

        vm.respondToPermission(requestId: 7, optionId: "allow_once")
        vm.switchApprovalMode(.acceptEdits)

        // The mirror is optimistic — it flips before the RPC lands.
        #expect(vm.richChatViewModel.activeApprovalMode == .acceptEdits)
        let approved = await ChatViewModelAutoAcceptEditsTests.waitUntil {
            await channel.permissionResponses.contains("allow_once")
        }
        #expect(approved, "the pending permission was never answered")
        let moded = await ChatViewModelAutoAcceptEditsTests.waitUntil {
            await channel.requestedModeIds.contains("accept_edits")
        }
        #expect(moded, "session/set_mode accept_edits was never sent")
        #expect(vm.richChatViewModel.activeApprovalMode == .acceptEdits)
    }

    /// If the host refuses the mode change, the chip reverts — otherwise
    /// it would read "Accept Edits" on a session that is still asking.
    @Test @MainActor func refusedSetModeRevertsTheChip() async throws {
        let home = try ChatViewModelAutoAcceptEditsTests.configuredHome()
        defer { home.cleanup() }
        let (vm, _) = await bootedViewModel(home: home, rejectSetMode: true)

        vm.switchApprovalMode(.acceptEdits)
        #expect(vm.richChatViewModel.activeApprovalMode == .acceptEdits)

        let reverted = await ChatViewModelAutoAcceptEditsTests.waitUntil {
            vm.richChatViewModel.activeApprovalMode == .default
        }
        #expect(reverted, "a refused session/set_mode left the chip claiming accept_edits")
    }
}
