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

    /// Every verb the board runs goes through this, so no test here spawns
    /// the real `hermes`. A `.local(home:)` context redirects file paths
    /// only: the binary is still the developer's own, with no `HERMES_HOME`,
    /// so a confirmed move used to run a real board-wide
    /// `hermes kanban dispatch` against their `~/.hermes`. Answers exit 0
    /// with an empty list, which is all `refresh()` needs.
    final class RecordingTransport: ServerTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }

        let contextID: ServerID = UUID()
        var isRemote: Bool { false }
        func readFile(_ path: String) throws -> Data { Data() }
        func unguardedWriteFile(_ path: String, data: Data) throws {}
        func fileExists(_ path: String) -> Bool { false }
        func stat(_ path: String) -> FileStat? { nil }
        func statAll(_ paths: [String]) -> [String: FileStat]? { nil }
        func listDirectory(_ path: String) throws -> [String] { [] }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws {}
        func runProcess(
            executable: String, args: [String], stdin: Data?, timeout: TimeInterval
        ) throws -> ProcessResult {
            lock.lock(); _calls.append(args); lock.unlock()
            return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
        }
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        func makeProcess(executable: String, args: [String], cwd: String?) -> Process { Process() }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { AsyncStream { $0.finish() } }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private static func board(
        _ tasks: [HermesKanbanTask], transport: RecordingTransport = RecordingTransport()
    ) -> KanbanBoardViewModel {
        let context = scratchContext()
        let vm = KanbanBoardViewModel(
            context: context,
            service: KanbanService(context: context, transport: transport))
        vm.tasks = tasks
        return vm
    }

    /// The test the decision asks for: **the drop parks instead of
    /// dispatching.** What it actually observes is the synchronous half of
    /// `attemptMove` — a parked `pendingDispatch` is recorded, the optimistic
    /// status override does NOT land (the card is still in Up Next), and
    /// `lastError` stays nil. It does NOT observe the argv: `service` is a
    /// concrete `KanbanService` built in `KanbanBoardViewModel.init`
    /// (`KanbanBoardViewModel.swift:41`) with no injection point, so no spy
    /// can record what would have been spawned. The absent override is the
    /// proxy: `attemptMove` applies it on the same path that starts the CLI
    /// task, so no override means that path was not taken.
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
    @Test func confirmingProceedsWithTheMove() async {
        let transport = RecordingTransport()
        let vm = Self.board([Self.task("t_a", status: "ready")], transport: transport)
        vm.attemptMove(taskId: "t_a", to: .running)
        #expect(!transport.calls.contains { $0.contains("dispatch") },
                "the drop dispatched before the user confirmed")
        vm.confirmPendingDispatch()

        #expect(vm.pendingDispatch == nil)
        #expect(vm.tasks(in: .running).map(\.id) == ["t_a"],
                "the confirmed move never applied its optimistic override")
        // And the confirmed move really runs the dispatcher pass — through
        // the recording transport, never a real `hermes`.
        for _ in 0..<200 where !transport.calls.contains(where: { $0.contains("dispatch") }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.calls.contains { $0.starts(with: ["kanban", "dispatch", "--json"]) })
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

    /// Every route into Running that the planner ACCEPTS ends in
    /// `.dispatch` — `blocked` and `scheduled` sources plan
    /// `[.unblock, .dispatch]` — so the confirmation is keyed on the plan
    /// containing that step (P60), not on the one `upNext` case.
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

    /// **P60: a REFUSED transition must not ask first.**
    ///
    /// The confirmation used to be parked on `destination == .running`
    /// BEFORE `KanbanService.plan` ran, so every source the planner refuses
    /// on the way to Running showed the board-wide dispatch sheet, took the
    /// user's yes, and only then failed with a banner — the sheet asking
    /// permission for a pass that was never going to happen.
    ///
    /// The four refused sources, each from `KanbanService.plan`:
    /// Done is terminal (no `reopen` verb); Triage is promoted by a
    /// specifier agent; Review → Running is neither of the two exits the
    /// round-6 decision-6 gate opens (`done` / `upNext`), so it falls to the
    /// `default:` refusal on every host; and Archived lives outside the
    /// board, so it falls there too.
    ///
    /// Ordering it after the plan fixes both halves at once: no sheet, and
    /// the refusal reaches `lastError` on the first gesture.
    @Test(arguments: [("done", KanbanBoardColumn.done), ("triage", .triage),
                      ("review", .review), ("archived", .archived)])
    func aRefusedDestinationDoesNotAskFirst(_ pair: (String, KanbanBoardColumn)) {
        let vm = Self.board([Self.task("t_a", status: pair.0)])
        vm.showArchived = true
        vm.attemptMove(taskId: "t_a", to: .running)

        #expect(vm.pendingDispatch == nil, """
            a transition the planner REFUSES asked for a board-wide dispatch \
            confirmation first — the sheet is parked ahead of the plan
            """)
        #expect(vm.lastError != nil,
                "the refusal never reached the banner: the move was parked instead")
        // And the card did not move.
        #expect(vm.tasks(in: pair.1).map(\.id) == ["t_a"])
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
