import Foundation
import Observation
import ScarfCore
import os

/// Read-only view of `hermes kanban list --json`. Multi-profile
/// collaboration was reverted upstream while the design is reworked,
/// so v2.6 ships read-only on Mac and defers create/claim/dispatch UI
/// to v2.7+.
///
/// Polls every 5s while foregrounded so dispatcher progress is visible
/// without manual refresh; the polling task is suspended when the view
/// disappears so background windows don't keep hammering SSH.
@Observable
@MainActor
final class KanbanViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "KanbanViewModel")

    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }

    var tasks: [HermesKanbanTask] = []
    var isLoading = false
    var lastError: String?
    var statusFilter: StatusFilter = .all

    /// Subset Hermes accepts on `--status`. `.all` skips the flag.
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all
        case triage
        case todo
        case ready
        case running
        case blocked
        case done
        case archived

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            default:   return rawValue.capitalized
            }
        }
    }

    private var pollTask: Task<Void, Never>?

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func load() async {
        isLoading = true
        let svc = fileService
        let filter = statusFilter
        let result = await Task.detached { () -> (exitCode: Int32, stdout: String, stderr: String) in
            var args = ["kanban", "list", "--json"]
            if filter != .all {
                args.append(contentsOf: ["--status", filter.rawValue])
            }
            return svc.runHermesCLISplit(args: args, timeout: 15)
        }.value

        defer { isLoading = false }

        guard result.exitCode == 0 else {
            lastError = result.stderr.isEmpty
                ? "kanban list failed (\(result.exitCode))"
                : result.stderr
            tasks = []
            return
        }

        guard let data = result.stdout.data(using: .utf8) else {
            lastError = "kanban list returned non-UTF8 output"
            tasks = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([HermesKanbanTask].self, from: data)
            tasks = decoded
            lastError = nil
        } catch {
            // No "(no matching tasks)" fallback: this argv always carries
            // `--json`, and the CLI returns `[]` before it can print that
            // line. The check only ever fired on a board whose own task text
            // contained the phrase — turning a decode failure into a
            // silently-emptied board.
            logger.warning("kanban JSON decode failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't parse kanban list output"
            tasks = []
        }
    }
}
