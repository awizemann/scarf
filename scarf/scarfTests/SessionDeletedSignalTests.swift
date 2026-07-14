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
/// `SessionDeletedSignal` after a successful CLI delete — and so does
/// `ChatViewModel.deleteSession` (wave-1 audit: another window's chat
/// sidebar is just as much an independent delete surface). Each
/// window's ChatViewModel filters by full session id + session-STORE
/// identity (`ServerContext.id` AND `paths.home` — multi-server
/// windows; profile scoping re-points the home while keeping the
/// `ServerID`; cosmetic context fields like `displayName` must NOT
/// veto a teardown), running the same teardown as `deleteSession` on
/// a match.
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

    /// Wave-1 audit: two windows on the SAME server/profile, both able
    /// to see session `sess-A`; window A deletes it from its CHAT
    /// SIDEBAR (`ChatViewModel.deleteSession`), window B's chat is
    /// attached to it mid-turn. Pre-fix, `deleteSession` ran only its
    /// own window's teardown and posted nothing — window B's `hermes
    /// acp` client stayed orphaned exactly the way the Sessions tab
    /// left it before 46735ba. Post-fix the sidebar delete broadcasts
    /// the same signal, and B routes through the full teardown.
    @Test @MainActor func chatSidebarDeleteInAnotherWindowTearsDownAttachedChat() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let vmB = await Self.attachedMidTurnChat(home: home, channel: ch, sessionId: "sess-A")

        // Window A: same context, idle chat (no ACP session), deletes
        // sess-A from its sidebar.
        let vmA = ChatViewModel(context: home.context)
        let deletes = Lifecycle.DeleteRecorder()
        vmA.sessionDeleteRunner = { _, sid in
            deletes.record(sid)
            return 0
        }
        vmA.deleteSession("sess-A")
        #expect(deletes.recorded == ["sess-A"])

        let cancelSent = await Lifecycle.waitUntil {
            await ch.sentMethods.contains("session/cancel")
        }
        #expect(cancelSent, "sidebar delete in window A killed no turn in window B: session/cancel never sent (cross-window orphan)")
        let closed = await Lifecycle.waitUntil { await ch.closed }
        #expect(closed, "sidebar delete in window A leaked window B's ACP client (channel never closed)")
        #expect(vmB.richChatViewModel.sessionId == nil)
        #expect(vmB.richChatViewModel.isAgentWorking == false)
        #expect(vmB.hasActiveProcess == false)
        #expect(vmB.richChatViewModel.transientHint == "Turn cancelled — session deleted.")
        // Window A itself stays a blank idle chat — its own broadcast
        // must not boomerang into a second teardown or a stray hint.
        #expect(vmA.richChatViewModel.sessionId == nil)
        #expect(vmA.richChatViewModel.transientHint == nil)
    }

    /// Wave-1 audit: the store-identity filter must match on
    /// (`ServerContext.id`, `paths.home`) — a context whose COSMETIC
    /// fields drifted (renamed server, probe-cached `hermesBinaryHint`)
    /// still points at the same state.db, and skipping the teardown on
    /// a full-struct mismatch would silently reintroduce the orphaned
    /// client. Fails pre-fix (full `==` comparison).
    @Test @MainActor func deleteFromCosmeticallyDriftedContextStillTearsDown() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let vm = await Self.attachedMidTurnChat(home: home, channel: ch, sessionId: "sess-A")

        var drifted = home.context
        drifted.displayName = "Renamed Since Window Opened"
        #expect(drifted != home.context) // precondition: full == would veto

        let deletes = Lifecycle.DeleteRecorder()
        let svm = Self.sessionsVM(
            context: drifted, deleting: "sess-A", exitCode: 0, deletes: deletes)
        svm.confirmDelete()

        let closed = await Lifecycle.waitUntil { await ch.closed }
        #expect(closed, "cosmetic displayName drift between poster and chat context vetoed the teardown — same session store, client leaked")
        #expect(vm.richChatViewModel.sessionId == nil)
        #expect(vm.richChatViewModel.isAgentWorking == false)
    }

    // MARK: - Posting contracts

    /// The chat sidebar's own delete (`ChatViewModel.deleteSession`)
    /// mirrors the Sessions-tab contract: a successful CLI delete posts
    /// exactly one signal (id + context), a failed one posts nothing.
    @Test @MainActor func chatSidebarDeletePostsSignalOnSuccessOnly() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let signals = SignalRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: SessionDeletedSignal.name, object: nil, queue: .main
        ) { note in signals.record(note) }
        defer { NotificationCenter.default.removeObserver(token) }

        let vm = ChatViewModel(context: home.context)
        let deletes = Lifecycle.DeleteRecorder()

        vm.sessionDeleteRunner = { _, sid in deletes.record(sid); return 1 }
        vm.deleteSession("sess-F")
        #expect(signals.recorded(for: home.context).isEmpty,
                "failed sidebar CLI delete broadcast SessionDeletedSignal")

        vm.sessionDeleteRunner = { _, sid in deletes.record(sid); return 0 }
        vm.deleteSession("sess-S")
        #expect(deletes.recorded == ["sess-F", "sess-S"])
        #expect(signals.recorded(for: home.context) == ["sess-S"],
                "successful sidebar delete did not broadcast exactly one SessionDeletedSignal")
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
