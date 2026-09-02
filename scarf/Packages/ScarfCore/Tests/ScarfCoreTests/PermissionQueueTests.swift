import Testing
import Foundation
@testable import ScarfCore

/// Regression coverage for the v2.24.0 audit-board item "pendingPermission
/// single slot → queue".
///
/// `RichChatViewModel.pendingPermission` used to be one optional slot.
/// Hermes can raise a second `session/request_permission` while the
/// first is still unanswered (parallel tool calls in a single turn),
/// and the assignment in `handleACPEvent` silently overwrote the first:
/// the open sheet swapped contents under the user, and the overwritten
/// request was never answered, so its tool call stayed blocked for the
/// rest of the turn.
@Suite struct PermissionQueueTests {

    private func request(_ title: String) -> ACPPermissionRequestEvent {
        ACPPermissionRequestEvent(
            toolCallTitle: title,
            toolCallKind: "execute",
            options: [("allow", "Allow once"), ("deny", "Deny")]
        )
    }

    /// Open the pre-engagement gate so live events aren't replay-dropped.
    @MainActor private func engagedVM() -> RichChatViewModel {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "go")
        return vm
    }

    @MainActor private func raise(_ vm: RichChatViewModel, id: Int, title: String) {
        vm.handleACPEvent(.permissionRequest(
            sessionId: "s", requestId: id, request: request(title)
        ))
    }

    /// The core bug: two concurrent requests. Both must be presentable
    /// and resolvable — the second must not evict the first.
    @Test @MainActor func secondRequestQueuesBehindTheFirst() {
        let vm = engagedVM()
        raise(vm, id: 1, title: "run: rm -rf /tmp/a")
        raise(vm, id: 2, title: "run: curl evil.example")

        #expect(vm.permissionQueue.count == 2)
        // The UI shows the head — arrival order, not last-writer-wins.
        #expect(vm.pendingPermission?.requestId == 1)
        #expect(vm.pendingPermission?.title == "run: rm -rf /tmp/a")

        // Resolving the head presents the next one.
        vm.resolvePermission(requestId: 1)
        #expect(vm.pendingPermission?.requestId == 2)
        #expect(vm.permissionQueue.count == 1)

        vm.resolvePermission(requestId: 2)
        #expect(vm.pendingPermission == nil)
        #expect(vm.permissionQueue.isEmpty)
    }

    /// Resolution is id-keyed, not "pop the head". A user can answer the
    /// presented request after a newer one has already been queued; the
    /// answer must retire the request it belongs to.
    @Test @MainActor func resolutionIsIdKeyedNotPositional() {
        let vm = engagedVM()
        raise(vm, id: 10, title: "first")
        raise(vm, id: 11, title: "second")

        // Answer the SECOND out of order (e.g. a sheet that was already
        // presenting it when the head changed underneath).
        vm.resolvePermission(requestId: 11)
        #expect(vm.permissionQueue.map(\.requestId) == [10])
    }

    /// A second `resolvePermission` for an already-answered id — the
    /// exact shape of a SwiftUI sheet writing its dismissal after
    /// `onRespond` already popped — must be a no-op, NOT a pop of the
    /// next queued request (which the user would then never see).
    @Test @MainActor func doubleResolveDoesNotSwallowTheNextRequest() {
        let vm = engagedVM()
        raise(vm, id: 1, title: "first")
        raise(vm, id: 2, title: "second")

        vm.resolvePermission(requestId: 1)
        vm.resolvePermission(requestId: 1) // stale dismissal write
        #expect(vm.pendingPermission?.requestId == 2)
        #expect(vm.permissionQueue.count == 1)
    }

    /// A duplicate re-send of the same request id refreshes in place
    /// rather than queueing the same approval twice.
    @Test @MainActor func duplicateIdIsDeduped() {
        let vm = engagedVM()
        raise(vm, id: 7, title: "original")
        raise(vm, id: 7, title: "refreshed")

        #expect(vm.permissionQueue.count == 1)
        #expect(vm.pendingPermission?.title == "refreshed")
    }

    /// A queued request whose turn ended must be dropped, not presented
    /// stale on the next turn — answering it would go nowhere.
    @Test @MainActor func promptCompleteDropsQueuedRequests() {
        let vm = engagedVM()
        raise(vm, id: 1, title: "first")
        raise(vm, id: 2, title: "second")

        vm.handleACPEvent(.promptComplete(
            sessionId: "s",
            response: ACPPromptResult(
                stopReason: "end_turn",
                inputTokens: 1, outputTokens: 1,
                thoughtTokens: 0, cachedReadTokens: 0
            )
        ))
        #expect(vm.permissionQueue.isEmpty)
        #expect(vm.pendingPermission == nil)
    }

    /// Same for a dropped connection: the whole queue goes, not just
    /// the head that happened to be on screen.
    @Test @MainActor func connectionLostDropsTheWholeQueue() {
        let vm = engagedVM()
        raise(vm, id: 1, title: "first")
        raise(vm, id: 2, title: "second")
        raise(vm, id: 3, title: "third")

        vm.handleACPEvent(.connectionLost(reason: "pipe closed"))
        #expect(vm.permissionQueue.isEmpty)
    }

    @Test @MainActor func finalizeOnDisconnectDropsTheWholeQueue() {
        let vm = engagedVM()
        raise(vm, id: 1, title: "first")
        raise(vm, id: 2, title: "second")

        vm.finalizeOnDisconnect()
        #expect(vm.permissionQueue.isEmpty)
    }
}
