import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Blind re-audit S13-F3. From 0.21.4 `hermes kanban complete` refuses a
/// completion with no result, summary or stored result from any status but
/// `review` (`_gate_empty_completion`, `hermes_cli/kanban_db.py:2860-2891` @
/// `v2026.9.24`; verified live: exit 1 "completion blocked: … has no result
/// or summary evidence"). The board used to drop Up Next / Blocked / Scheduled
/// cards on Done with no result, and for Blocked / Scheduled the unblock step
/// landed before the complete failed, leaving the card in Up Next.
///
/// Like `KanbanDispatchConfirmP56Tests`, these observe the synchronous half
/// of `attemptMove`: a refused move sets `lastError` and applies NO
/// optimistic override, and the override is applied on the same path that
/// starts the CLI steps, so no override means no step (unblock included) ran.
/// Only REFUSED moves are driven: a move that proceeds would spawn the real
/// `hermes` binary, and a `.local(home:)` context does not pin its
/// `HERMES_HOME`, so it would reach the developer's own board.
@MainActor
@Suite struct KanbanCompletionGateB04Tests {

    private static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    private static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")

    private static func board(
        _ tasks: [HermesKanbanTask], caps: HermesCapabilities
    ) -> KanbanBoardViewModel {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-b04-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let vm = KanbanBoardViewModel(context: .local(home: home))
        vm.capabilities = caps
        vm.tasks = tasks
        return vm
    }

    private static func task(_ id: String, status: String, result: String? = nil) -> HermesKanbanTask {
        HermesKanbanTask(
            id: id, title: "card \(id)", assignee: "alice", status: status,
            priority: 0, createdAt: "2026-09-27T09:00:00Z", result: result)
    }

    @Test func aBlockedCardWithNoResultIsRefusedBeforeTheUnblockRuns() {
        let vm = Self.board([Self.task("t_b", status: "blocked")], caps: Self.v0214)
        #expect(vm.completionNeedsResult(taskId: "t_b"))

        vm.attemptMove(taskId: "t_b", to: .done)
        #expect(vm.lastError == KanbanBoardViewModel.completionResultRequiredMessage)
        // Still Blocked: no optimistic override, so no unblock was started.
        #expect(vm.tasks(in: .blocked).map(\.id) == ["t_b"])
        #expect(vm.tasks(in: .upNext).isEmpty)
    }

    @Test func aWhitespaceResultIsNotEvidence() {
        let vm = Self.board([Self.task("t_r", status: "ready")], caps: Self.v0214)
        vm.attemptMove(taskId: "t_r", to: .done, completeResult: "  \n ")
        #expect(vm.lastError != nil)
        #expect(vm.tasks(in: .upNext).map(\.id) == ["t_r"])
    }

    /// Hermes also accepts the task's stored `result` (kanban_db.py:2880-2882).
    @Test func aStoredResultSatisfiesTheGate() {
        let vm = Self.board([Self.task("t_s", status: "running", result: "done earlier")], caps: Self.v0214)
        #expect(!vm.completionNeedsResult(taskId: "t_s"))
    }

    @Test func reviewApprovalNeedsNoResult() {
        let vm = Self.board([Self.task("t_v", status: "review")], caps: Self.v0214)
        #expect(!vm.completionNeedsResult(taskId: "t_v"))
    }

    /// Below 0.21.4 a blank completion succeeds, so nothing changes there.
    @Test func olderHostsStillCompleteWithoutAResult() {
        let vm = Self.board([Self.task("t_b", status: "blocked")], caps: Self.v0213)
        #expect(!vm.completionNeedsResult(taskId: "t_b"))
    }
}

/// S03-F3 / S13-F4 per Hermes band, at the chat call site. Below 0.21.5 no
/// config gives Scarf's (ACP) chats kanban tools, so the sheet's Enable path
/// must write nothing; on 0.21.5+ it writes `platform_toolsets.acp`.
@MainActor
@Suite(.serialized) struct KanbanChatEnableBandB04Tests {

    /// `enableKanbanToolset()` records the sheet's dismissal under the
    /// context id, and a `.local(home:)` context shares the real local id,
    /// so the test host's own defaults must be put back afterwards.
    private static func preservingDismissal(_ body: () async throws -> Void) async rethrows {
        let key = "scarf.kanbanOnboarding.dismissed.\(ServerContext.local.id.uuidString)"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        try await body()
    }

    @Test func theUnavailablePromptWritesNothing() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let original = "model:\n  default: x\n"
        try original.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let vm = ChatViewModel(context: home.context)
        vm.kanbanOnboardingPrompt = .unavailableInChat
        await Self.preservingDismissal { await vm.enableKanbanToolset() }
        let after = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        #expect(after == original)
    }

    @Test func theOfferPromptWritesTheACPList() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try "model:\n  default: x\n".write(
            toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let vm = ChatViewModel(context: home.context)
        vm.kanbanOnboardingPrompt = .offerEnable(platform: "acp")
        await Self.preservingDismissal { await vm.enableKanbanToolset() }
        let after = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        #expect(after.contains("platform_toolsets:\n  acp:\n  - hermes-acp\n  - kanban\n"))
        #expect(!after.contains("cli:"))
    }
}
