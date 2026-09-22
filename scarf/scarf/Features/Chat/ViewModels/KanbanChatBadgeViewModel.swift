import Foundation
import Observation
import ScarfCore
import os

/// Drives the live count badge on `SessionInfoBar`'s Kanban chip.
/// Polls `KanbanService.list` every 5 seconds while mounted, counts the
/// tasks of *this chat* that are live (`running`, `blocked` or `review`
/// — see `KanbanChatBadgeState.liveStatuses`), scoped precisely by the
/// originating ACP `session_id` (v0.15+), and exposes the result for
/// the chip to render.
///
/// **Concurrency.** `@MainActor + @Observable`. The CLI invocation runs
/// on `Task.detached(priority: .utility)` inside `KanbanService` per the
/// project's Swift 6 rules; only the small state transitions land on
/// MainActor.
///
/// **Lifecycle.** Hosts mount via `.task(id: …)` and MUST call
/// `bind(to:)` with the current chat session id before `run` — including
/// when it is `nil`, which is what clears the previous chat's count.
/// The poll key also carries the scene phase, so a backgrounded window
/// stops spawning `hermes kanban list` (C10), exactly as
/// `KanbanBoardView` does.
///
/// **Staleness.** `KanbanService.runHermes` uses `Task.detached`, which
/// view-task cancellation does not reach, so a poll issued for chat A
/// can outlive the switch to chat B (up to the 20 s `list` timeout).
/// Every result is stamped with the session id it was issued for and
/// dropped by `KanbanChatBadgeState` when that id is no longer bound.
@Observable
@MainActor
final class KanbanChatBadgeViewModel {
    private let logger = Logger(
        subsystem: "com.scarf",
        category: "KanbanChatBadgeViewModel"
    )

    /// The pure state machine (ScarfCore) — all badge rules live there.
    private var state = KanbanChatBadgeState()

    /// `nil` while the first poll for the bound session hasn't returned,
    /// or when no chat session is bound. Zero is a real value.
    var liveCount: Int? { state.liveCount }

    private let context: ServerContext
    private let service: KanbanService

    init(context: ServerContext) {
        self.context = context
        self.service = KanbanService(context: context)
    }

    /// Point the badge at a chat session. Call this from the host's
    /// `.task(id:)` body *before* any capability guard — a chat with no
    /// session, or a different session, must clear the old count rather
    /// than keep asserting it.
    func bind(to sessionId: String?) {
        state.bind(to: sessionId)
    }

    /// Start the long-running poller for the bound session. The task is
    /// automatically cancelled when the view leaves the tree or the
    /// poll key changes.
    func run(capabilities: HermesCapabilities) async {
        guard capabilities.hasKanbanSessionFilter else { return }
        // Tick immediately so the chip's first render has data, then
        // sleep + tick on the configured interval.
        await poll()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(state.currentInterval * 1_000_000_000))
            } catch {
                return
            }
            await poll()
        }
    }

    private func poll() async {
        guard let issuedFor = state.beginPoll() else { return }
        do {
            let rows = try await service.list(KanbanListFilter(session: issuedFor))
            let count = KanbanChatBadgeState.liveCount(of: rows)
            state.accept(count: count, issuedFor: issuedFor)
        } catch {
            logger.debug("kanban badge poll failed: \(error.localizedDescription, privacy: .public)")
            // Don't surface — the chip just drops its number. Back off so
            // a persistent failure doesn't pin the CPU or the remote host.
            state.fail(issuedFor: issuedFor)
        }
    }
}
