import Testing
import Foundation
import ScarfCore
@testable import scarf

/// S13a-F1 — `hermes kanban dispatch` exits 0 whether or not it started the
/// task the user dropped on Running. The board read nothing back, so the
/// Running override stayed forever (the poll said ready/todo, which never
/// matches Running). Now the pass's `spawned` / `skipped_*` lists are read,
/// the user is told why, and the card goes back to where Hermes has it.
@MainActor
@Suite struct KanbanDispatchSkipC02Tests {

    /// Answers `kanban dispatch` with a fixed JSON payload (shaped like
    /// `_cmd_dispatch`, `hermes_cli/kanban_ops.py:97-116` @ `v2026.9.24`)
    /// and `kanban list` with the task still `ready`.
    final class DispatchTransport: ServerTransport, @unchecked Sendable {
        let dispatchJSON: String
        let listJSON: String
        init(dispatchJSON: String, listStatus: String) {
            self.dispatchJSON = dispatchJSON
            self.listJSON = #"[{"id":"t_a","title":"card","assignee":"alice","status":"\#(listStatus)","priority":0,"created_at":"2026-09-13T09:00:00Z"}]"#
        }
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
            let out = args.contains("dispatch") ? dispatchJSON
                : args.contains("list") ? listJSON : "[]"
            return ProcessResult(exitCode: 0, stdout: Data(out.utf8), stderr: Data())
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

    private static func board(_ transport: DispatchTransport) -> KanbanBoardViewModel {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-c02-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let context = ServerContext.local(home: home)
        let vm = KanbanBoardViewModel(
            context: context, service: KanbanService(context: context, transport: transport))
        vm.tasks = [HermesKanbanTask(
            id: "t_a", title: "card", assignee: "alice", status: "ready",
            priority: 0, createdAt: "2026-09-13T09:00:00Z")]
        return vm
    }

    private static let cappedPass = #"""
    {"reclaimed":0,"crashed":[],"timed_out":[],"stale":[],"auto_blocked":[],"promoted":0,
     "reaped_terminal_workers":[],"spawned":[],"skipped_unassigned":[],"skipped_nonspawnable":[],
     "skipped_per_profile_capped":[{"task_id":"t_a","assignee":"alice","current":2}],
     "auto_assigned_default":[],"respawn_guarded":[],"rate_limited":[],"skipped_locked":false,
     "memory_pressure":null}
    """#

    @Test func aSkippedDropSaysWhyAndLeavesRunning() async {
        let vm = Self.board(DispatchTransport(dispatchJSON: Self.cappedPass, listStatus: "ready"))
        vm.attemptMove(taskId: "t_a", to: .running, confirmed: true)
        #expect(vm.tasks(in: .running).map(\.id) == ["t_a"])  // optimistic

        for _ in 0..<300 where vm.transientNotice == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.transientNotice?.contains("alice") == true)
        #expect(vm.lastError == nil)
        // Not stuck in Running: back in Up Next, where Hermes has it.
        #expect(vm.tasks(in: .running).isEmpty)
        #expect(vm.tasks(in: .upNext).map(\.id) == ["t_a"])
    }

    @Test func aSpawnedDropStaysInRunningWithNoNotice() async {
        let spawned = #"{"promoted":0,"spawned":[{"task_id":"t_a","assignee":"alice","workspace":"/w"}]}"#
        let vm = Self.board(DispatchTransport(dispatchJSON: spawned, listStatus: "running"))
        vm.attemptMove(taskId: "t_a", to: .running, confirmed: true)
        for _ in 0..<300 where vm.tasks.first?.status != "running" {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.transientNotice == nil)
        #expect(vm.tasks(in: .running).map(\.id) == ["t_a"])
    }
}
