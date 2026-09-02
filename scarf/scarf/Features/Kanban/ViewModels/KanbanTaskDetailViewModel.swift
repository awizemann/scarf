import Foundation
import Observation
import ScarfCore
import os

/// Drives the inspector pane for a single Kanban task. Loads the full
/// `kanban show` detail (comments + events + parent results) and the
/// run history (`kanban runs`). Mutations route back through the
/// shared `KanbanService` so the board's optimistic merge picks them
/// up on the next poll tick.
@Observable
@MainActor
final class KanbanTaskDetailViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "KanbanTaskDetailViewModel")

    let service: KanbanService
    let taskId: String

    var detail: HermesKanbanTaskDetail?
    var runs: [HermesKanbanRun] = []
    var isLoading = false
    var lastError: String?
    var commentDraft: String = ""

    // MARK: - Worker log
    /// Captured worker stdout/stderr from `hermes kanban log <id>`.
    /// Empty until the first poll completes; updates every ~2s while
    /// the task is running.
    var log: String = ""
    /// True when the log view is showing only the tail of a larger file.
    /// A cap that degrades silently is indistinguishable from a short log,
    /// so the Log tab renders a banner off this.
    var logWasTruncated: Bool = false
    var isLogStreaming: Bool = false

    private var logPollTask: Task<Void, Never>?
    private var detailPollTask: Task<Void, Never>?

    init(service: KanbanService, taskId: String) {
        self.service = service
        self.taskId = taskId
    }
    // No deinit-side cancellation: `logPollTask` is MainActor-isolated
    // and `deinit` is nonisolated; relying on the Task's `[weak self]`
    // capture is enough, and the inspector calls `stopLogPolling()`
    // from `onDisappear` for predictable cleanup.

    /// Start polling task detail (header / comments / events / runs)
    /// every 5s while the inspector is open. Same cadence as the board
    /// so a worker transition (e.g. running → done) is reflected in
    /// the inspector header + primary-action button without the user
    /// having to close and reopen. Idempotent. The first iteration
    /// runs immediately so the initial fetch matches one-shot
    /// `load()` semantics.
    func startDetailPolling() {
        guard detailPollTask == nil else { return }
        detailPollTask = Task { [weak self] in
            var interval = KanbanPollBackoff.boardBase
            while !Task.isCancelled {
                guard let self else { return }
                await self.load()
                interval = KanbanPollBackoff.nextInterval(
                    current: interval, base: KanbanPollBackoff.boardBase,
                    succeeded: self.lastError == nil
                )
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stopDetailPolling() {
        detailPollTask?.cancel()
        detailPollTask = nil
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let detail = service.show(taskId: taskId)
            async let runs = service.runs(taskId: taskId)
            self.detail = try await detail
            self.runs = (try? await runs) ?? []
            lastError = nil
        } catch let err as KanbanError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// One-shot log refresh. Use when the user opens the Log tab and
    /// the task isn't running (so we don't want to start a poll loop).
    func refreshLogOnce() async {
        do {
            // BOUNDED. `tailBytes: nil` pulled the entire worker log over the
            // transport on every 2-second tick, so the cost of a tick grew
            // with the length of the run. `KanbanService.log` has always
            // supported `--tail`; it just was never passed.
            let text = try await service.log(
                taskId: taskId, tailBytes: KanbanPollBackoff.logTailBytes
            )
            // Announce the cap rather than silently showing a decapitated
            // log: at exactly the tail size we cannot tell a log that fits
            // from one that was cut, so say so either way.
            logWasTruncated = text.utf8.count >= KanbanPollBackoff.logTailBytes
            self.log = text
        } catch let err as KanbanError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Start polling the worker log every 2s. Called when the Log tab
    /// is opened on a running task. Idempotent: a second call is a
    /// no-op while the previous loop is alive.
    func startLogPolling() {
        guard logPollTask == nil else { return }
        isLogStreaming = true
        logPollTask = Task { [weak self] in
            var interval = KanbanPollBackoff.logBase
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLogOnce()
                interval = KanbanPollBackoff.nextInterval(
                    current: interval, base: KanbanPollBackoff.logBase,
                    succeeded: self.lastError == nil
                )
                try? await Task.sleep(nanoseconds: interval)
                // Auto-stop when the task transitions out of running.
                if let status = self.detail?.task.status,
                   KanbanStatus.from(status) != .running {
                    self.isLogStreaming = false
                    self.logPollTask = nil
                    return
                }
            }
        }
    }

    func stopLogPolling() {
        logPollTask?.cancel()
        logPollTask = nil
        isLogStreaming = false
    }

    func submitComment() async {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try await service.comment(taskId: taskId, text: text, author: nil)
            commentDraft = ""
            await load()
        } catch let err as KanbanError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }
}
