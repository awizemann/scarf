import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P56, round-6 decision 9 — dropping ONE card on Running runs a BOARD-WIDE
/// dispatcher pass.
///
/// `hermes kanban dispatch` has no per-task selector: the whole argv is
/// `--dry-run` / `--max` / `--failure-limit` / `--json`
/// (`hermes_cli/kanban_parser.py:346-353` @ `v2026.9.7`), so the pass spawns
/// workers for every assigned `ready` task in priority order and may well
/// start a different one first. The gesture said "this task"; the verb means
/// "all of them". Nothing runs until the user confirms.
@MainActor
@Suite struct KanbanDispatchConfirmP56Tests {

    /// An isolated Hermes home so nothing here can touch the developer's own.
    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p56-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    private static func task(
        _ id: String, status: String, assignee: String? = "alice"
    ) -> HermesKanbanTask {
        HermesKanbanTask(
            id: id, title: "card \(id)", assignee: assignee, status: status,
            priority: 0, createdAt: "2026-09-13T09:00:00Z")
    }

    private static func board(_ tasks: [HermesKanbanTask]) -> KanbanBoardViewModel {
        let vm = KanbanBoardViewModel(context: scratchContext())
        vm.tasks = tasks
        return vm
    }

    /// The test the decision asks for: **the dispatch does not run until
    /// confirmed.** Proven by the two observable effects `attemptMove` has
    /// when it proceeds — the optimistic status override, and the CLI task it
    /// spawns. Neither happens; a parked move is recorded instead.
    @Test func aDropOnRunningParksInsteadOfDispatching() {
        let vm = Self.board([Self.task("t_a", status: "ready")])
        vm.attemptMove(taskId: "t_a", to: .running)

        #expect(vm.pendingDispatch?.taskId == "t_a")
        #expect(vm.pendingDispatch?.source == .upNext)
        // Nothing moved: the card is still where the user picked it up, so a
        // cancel needs no rollback.
        #expect(vm.tasks(in: .upNext).map(\.id) == ["t_a"])
        #expect(vm.lastError == nil)
    }

    /// Confirming is the ONE path that proceeds. It clears the parked move
    /// and applies the optimistic mutation `attemptMove` was holding back.
    @Test func confirmingProceedsWithTheMove() {
        let vm = Self.board([Self.task("t_a", status: "ready")])
        vm.attemptMove(taskId: "t_a", to: .running)
        vm.confirmPendingDispatch()

        #expect(vm.pendingDispatch == nil)
        #expect(vm.tasks(in: .running).map(\.id) == ["t_a"],
                "the confirmed move never applied its optimistic override")
    }

    /// Cancelling drops it, with nothing to undo.
    @Test func cancellingLeavesTheCardAlone() {
        let vm = Self.board([Self.task("t_a", status: "ready")])
        vm.attemptMove(taskId: "t_a", to: .running)
        vm.cancelPendingDispatch()

        #expect(vm.pendingDispatch == nil)
        #expect(vm.tasks(in: .upNext).map(\.id) == ["t_a"])
    }

    /// `confirmPendingDispatch()` with nothing parked is a no-op, not a
    /// dispatcher pass on whatever card happens to be first.
    @Test func confirmingNothingDoesNothing() {
        let vm = Self.board([Self.task("t_a", status: "ready")])
        vm.confirmPendingDispatch()
        #expect(vm.pendingDispatch == nil)
        #expect(vm.tasks(in: .upNext).map(\.id) == ["t_a"])
    }

    /// Every route into Running ends in `.dispatch` — `blocked` and
    /// `scheduled` sources plan `[.unblock, .dispatch]` — so the confirmation
    /// is keyed on the DESTINATION, not on the one `upNext` case.
    @Test(arguments: [("blocked", KanbanBoardColumn.blocked), ("scheduled", .scheduled)])
    func everySourceIntoRunningAsksFirst(_ pair: (String, KanbanBoardColumn)) {
        let vm = Self.board([Self.task("t_a", status: pair.0)])
        vm.attemptMove(taskId: "t_a", to: .running)
        #expect(vm.pendingDispatch?.source == pair.1)
        #expect(vm.tasks(in: pair.1).map(\.id) == ["t_a"])
    }

    /// …and a move that does NOT dispatch is unaffected: no sheet, and the
    /// optimistic override lands immediately as it always did.
    @Test func aMoveThatDoesNotDispatchIsUnchanged() {
        let vm = Self.board([Self.task("t_a", status: "blocked")])
        vm.attemptMove(taskId: "t_a", to: .upNext)
        #expect(vm.pendingDispatch == nil)
        #expect(vm.tasks(in: .upNext).map(\.id) == ["t_a"])
    }

    /// The parked move carries the card's TITLE, because the confirmation
    /// names the task the user dropped — the whole point is that the pass may
    /// start a different one.
    @Test func theParkedMoveCarriesTheTitleTheSheetShows() {
        let vm = Self.board([Self.task("t_a", status: "ready")])
        vm.attemptMove(taskId: "t_a", to: .running)
        #expect(vm.pendingDispatch?.taskTitle == "card t_a")
    }
}
