import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Coverage for the cross-feature session-delete seam (t-5f1d9008):
///
/// The Sessions tab (`SessionsViewModel.confirmDelete`) is an
/// independent delete surface with no reference to the window's
/// `ChatViewModel`. Pre-fix, deleting the chat-ATTACHED session there
/// ran the CLI delete and nothing else — the `hermes acp` client kept
/// running against the deleted session: orphaned in-flight turn plus a
/// leaked process (the leak shape t-01bd55ec fixed for the chat
/// sidebar's own delete path). Post-fix, `confirmDelete` broadcasts
/// `SessionDeletedSignal` after a successful CLI delete and each
/// window's ChatViewModel filters it by FULL session id + FULL
/// `ServerContext` (multi-server windows; profile scoping re-points the
/// home while keeping the `ServerID`), running the same teardown as
/// `deleteSession` on a match.
///
/// ACP plumbing is scripted through the `acpClientFactory` seam and the
/// CLI through `sessionDeleteRunner` — no subprocess, no real Hermes.
/// Reuses `ChatViewModelStartLifecycleTests`' scripted channel/helpers.
@Suite struct SessionDeletedSignalTests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias ScriptedACPChannel = Lifecycle.ScriptedACPChannel

    /// Thread-safe recorder for posted `SessionDeletedSignal`
    /// notifications (payloads only — the block observer isn't
    /// isolated). Suites run in parallel in one process and the signal
    /// is a process-wide broadcast, so assertions must filter by the
    /// test's own temp-home context.
    final class SignalRecorder: @unchecked Sendable {
        private var payloads: [(sessionId: String, context: ServerContext)] = []
        private let lock = NSLock()
        func record(_ note: Notification) {
            guard let sid = note.userInfo?[SessionDeletedSignal.sessionIdKey] as? String,
                  let ctx = note.userInfo?[SessionDeletedSignal.contextKey] as? ServerContext
            else { return }
            lock.lock(); defer { lock.unlock() }
            payloads.append((sessionId: sid, context: ctx))
        }
        func recorded(for context: ServerContext) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return payloads.filter { $0.context == context }.map(\.sessionId)
        }
    }

    /// A chat VM booted to Ready on `sessionId` with a held-open
    /// in-flight turn, ready for a delete signal to land on it.
    @MainActor
    private static func attachedMidTurnChat(
        home: TempHermesHome, channel: ScriptedACPChannel, sessionId: String
    ) async -> ChatViewModel {
        let vm = ChatViewModel(context: home.context)
        vm.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in channel }
        }
        vm.startNewSession()
        let ready = await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
                && vm.richChatViewModel.sessionId == sessionId
        }
        #expect(ready)
        vm.sendText("long-running turn") // held open by the scripted channel
        let promptInFlight = await Lifecycle.waitUntil {
            await channel.sentMethods.contains("session/prompt")
        }
        #expect(promptInFlight)
        #expect(vm.richChatViewModel.isAgentWorking)
        return vm
    }

    /// A SessionsViewModel wired to a stubbed CLI runner. `exitCode`
    /// scripts success/failure; `deleteSessionId` is pre-staged as the
    /// confirm dialog would have.
    @MainActor
    private static func sessionsVM(
        context: ServerContext, deleting sessionId: String, exitCode: Int32,
        deletes: Lifecycle.DeleteRecorder
    ) -> SessionsViewModel {
        let svm = SessionsViewModel(context: context)
        svm.sessionDeleteRunner = { _, sid in
            deletes.record(sid)
            return exitCode
        }
        svm.deleteSessionId = sessionId
        svm.showDeleteConfirmation = true
        return svm
    }

    // MARK: - ChatViewModel reacts to the signal

    /// The bug's flagship path: the Sessions tab deletes the session the
    /// chat is ATTACHED to while a turn is in flight. The chat client
    /// must route through the full t-01bd55ec teardown: best-effort
    /// `session/cancel` before the kill, `client.stop()` (channel
    /// closed — pre-fix the process + dispatch sources leaked until app
    /// quit while the orphaned turn kept running server-side),
    /// transcript detached, idle status, delete-specific toast.
    @Test @MainActor func sessionsTabDeleteOfAttachedSessionMidTurnTearsDownChatClient() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let vm = await Self.attachedMidTurnChat(home: home, channel: ch, sessionId: "sess-A")

        let deletes = Lifecycle.DeleteRecorder()
        let svm = Self.sessionsVM(
            context: home.context, deleting: "sess-A", exitCode: 0, deletes: deletes)
        svm.confirmDelete()
        #expect(deletes.recorded == ["sess-A"])
        #expect(svm.showDeleteConfirmation == false)
        #expect(svm.deleteSessionId == nil)

        // The orphaned turn gets a bounded best-effort cancel…
        let cancelSent = await Lifecycle.waitUntil {
            await ch.sentMethods.contains("session/cancel")
        }
        #expect(cancelSent, "Sessions-tab delete of the attached session killed no turn: session/cancel never sent (pre-fix leak)")
        // …and the client is actually stopped (channel closed), not
        // left running until app quit.
        let closed = await Lifecycle.waitUntil { await ch.closed }
        #expect(closed, "Sessions-tab delete of the attached session leaked the ACP client (channel never closed)")

        // Transcript + preparing state sane: blank idle chat.
        #expect(vm.richChatViewModel.sessionId == nil)
        #expect(vm.richChatViewModel.messages.isEmpty)
        #expect(vm.richChatViewModel.isAgentWorking == false)
        #expect(vm.isPreparingSession == false)
        #expect(vm.isStartingSession == false)
        #expect(vm.hasActiveProcess == false)
        #expect(vm.acpStatus.isEmpty)
        // Composer-level feedback names the delete, not a session switch.
        #expect(vm.richChatViewModel.transientHint == "Turn cancelled — session deleted.")
    }

    /// Deleting a NON-attached session from the Sessions tab must be a
    /// strict no-op for chat: client stays up, the in-flight turn keeps
    /// running, no cancel RPC, transcript untouched.
    @Test @MainActor func sessionsTabDeleteOfOtherSessionLeavesChatUntouched() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let vm = await Self.attachedMidTurnChat(home: home, channel: ch, sessionId: "sess-A")

        let deletes = Lifecycle.DeleteRecorder()
        let svm = Self.sessionsVM(
            context: home.context, deleting: "sess-other", exitCode: 0, deletes: deletes)
        svm.confirmDelete()
        #expect(deletes.recorded == ["sess-other"])

        // Give any erroneous teardown time to surface before asserting
        // the live session is untouched.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let stillOpen = await ch.closed
        #expect(stillOpen == false, "Sessions-tab delete of a non-attached session stopped the live chat client")
        let methods = await ch.sentMethods
        #expect(!methods.contains("session/cancel"),
                "Sessions-tab delete of a non-attached session cancelled the live turn")
        #expect(vm.richChatViewModel.sessionId == "sess-A")
        #expect(vm.richChatViewModel.isAgentWorking)
        #expect(vm.hasActiveProcess)
    }

    /// Multi-window identity: a delete of the SAME session id on a
    /// DIFFERENT server context (here: a different Hermes home — the
    /// same shape profile scoping produces) must not touch this window's
    /// chat, even though the ids match. Pins the full-`ServerContext`
    /// comparison, not id-only.
    @Test @MainActor func sessionsTabDeleteOnOtherServerContextLeavesChatUntouched() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let otherHome = try Lifecycle.configuredHome()
        defer { otherHome.cleanup() }
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let vm = await Self.attachedMidTurnChat(home: home, channel: ch, sessionId: "sess-A")

        // Same session id, other context's Sessions tab.
        let deletes = Lifecycle.DeleteRecorder()
        let svm = Self.sessionsVM(
            context: otherHome.context, deleting: "sess-A", exitCode: 0, deletes: deletes)
        svm.confirmDelete()
        #expect(deletes.recorded == ["sess-A"])

        try? await Task.sleep(nanoseconds: 300_000_000)
        let stillOpen = await ch.closed
        #expect(stillOpen == false, "a delete on a DIFFERENT server context tore down this window's chat client (id-only match)")
        let methods = await ch.sentMethods
        #expect(!methods.contains("session/cancel"),
                "a delete on a different server context cancelled this window's turn")
        #expect(vm.richChatViewModel.sessionId == "sess-A")
        #expect(vm.richChatViewModel.isAgentWorking)
    }

    // MARK: - SessionsViewModel posting contract

    /// A successful CLI delete posts exactly one `SessionDeletedSignal`
    /// carrying the full session id and the poster's full context, and
    /// resets the confirm-dialog state.
    @Test @MainActor func successfulDeletePostsSignalWithIdAndContext() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let signals = SignalRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: SessionDeletedSignal.name, object: nil, queue: .main
        ) { note in signals.record(note) }
        defer { NotificationCenter.default.removeObserver(token) }

        let deletes = Lifecycle.DeleteRecorder()
        let svm = Self.sessionsVM(
            context: home.context, deleting: "sess-X", exitCode: 0, deletes: deletes)
        svm.confirmDelete()

        #expect(deletes.recorded == ["sess-X"])
        #expect(signals.recorded(for: home.context) == ["sess-X"],
                "successful Sessions-tab delete did not broadcast SessionDeletedSignal")
        #expect(svm.showDeleteConfirmation == false)
        #expect(svm.deleteSessionId == nil)
    }

    /// A FAILED CLI delete (non-zero exit) must post nothing — the
    /// session still exists server-side, and a spurious signal would
    /// tear down a healthy attached chat.
    @Test @MainActor func failedDeletePostsNoSignal() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let signals = SignalRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: SessionDeletedSignal.name, object: nil, queue: .main
        ) { note in signals.record(note) }
        defer { NotificationCenter.default.removeObserver(token) }

        let deletes = Lifecycle.DeleteRecorder()
        let svm = Self.sessionsVM(
            context: home.context, deleting: "sess-X", exitCode: 1, deletes: deletes)
        svm.confirmDelete()

        #expect(deletes.recorded == ["sess-X"])
        #expect(signals.recorded(for: home.context).isEmpty,
                "failed CLI delete broadcast SessionDeletedSignal — a healthy attached chat would be torn down")
        // Dialog state still resets (matches pre-existing behavior).
        #expect(svm.showDeleteConfirmation == false)
        #expect(svm.deleteSessionId == nil)
    }
}
