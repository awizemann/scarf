import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Host-side coverage for `ScarfMiniAppBridge` — the `window.scarf` bridge
/// that was shipped "build-verified only". `WKScriptMessage` has no usable
/// public initializer, so these tests drive the extracted `dispatch`
/// seam (the body of `userContentController` after the `{method, args}`
/// decode) directly. That seam owns the trust boundary, so it's exactly the
/// security-critical half worth a regression net.
///
/// **Why `@MainActor`.** WebKit calls the real entry point on the main
/// thread, and the sync reply paths + `ui.*` actions assume it. Running the
/// suite on the main actor honors that contract: the async surfaces hop
/// back to the main queue before replying, and awaiting (via `Task.sleep`
/// in `callDispatch`) frees the main actor so that queue drains and the
/// reply lands.
@MainActor
@Suite struct ScarfMiniAppBridgeTests {

    // MARK: - Ungated baseline (positive control for the seam)

    /// `context.get` carries no permission, so it resolves with the baked
    /// context JSON even with an empty grant set — proving the extracted
    /// `dispatch` seam routes a happy-path call correctly.
    @Test func contextGetReturnsBakedContextUngated() async throws {
        let bridge = makeBridge(projectPath: "/tmp/scarf-ctx", granted: [])
        let (result, error) = try await callDispatch(bridge, .contextGet)
        #expect(error == nil)
        // The injected context JSON includes this mini-app's id.
        #expect((result as? String)?.contains("\"miniAppId\":\"test-app\"") == true)
    }

    // MARK: - Trust boundary (preflight denies before any service runs)

    /// A method whose permission is NOT granted must be rejected by
    /// `dispatcher.preflight` before the handler runs: the reply carries the
    /// denial as `errorCode: errorMessage`, and the service is never touched.
    /// The agent surface gives a clean spy — if `prompt.send` reached the
    /// session, an ACP handshake/prompt would hit the fake channel; a denied
    /// call leaves the wire empty.
    @Test func deniedMethodRepliesDenialAndNeverTouchesService() async throws {
        let fake = MiniAppAgentSessionTests.FakeACPChannel()
        let session = makeSession(fake)
        // No `.prompt` grant.
        let bridge = makeBridge(projectPath: "/tmp/scarf-deny", granted: [], agentSession: session)

        let (result, error) = try await callDispatch(bridge, .promptSend, ["hello"])

        #expect(result == nil)
        #expect(error == "permission_denied: Permission 'prompt' is not granted to this mini-app.")
        // Service untouched: the session never even started its handshake.
        #expect(await fake.sentCount == 0)
    }

    /// `events.subscribe` is the second sensitive agent surface
    /// (`scarf.onEvent`). Without the `.events` grant, `preflight` must deny
    /// it BEFORE the handler registers an event sink — the symmetric
    /// guarantee to the `prompt` case above.
    @Test func eventsSubscribeDeniedWithoutGrantNeverRegistersSink() async throws {
        let fake = MiniAppAgentSessionTests.FakeACPChannel()
        let session = makeSession(fake)
        // No `.events` grant.
        let bridge = makeBridge(projectPath: "/tmp/scarf-events-deny", granted: [], agentSession: session)

        let (result, error) = try await callDispatch(bridge, .eventsSubscribe)

        #expect(result == nil)
        #expect(error == "permission_denied: Permission 'events' is not granted to this mini-app.")
        // Gate fired before the handler — no sink registered, no ACP activity.
        #expect(await fake.sentCount == 0)
    }

    // MARK: - Per-surface gating (store)

    /// With `.store` granted, `store.set` then `store.get` round-trips the
    /// opaque JSON value through the sandboxed KV.
    @Test func storeSetThenGetRoundTripsWithGrant() async throws {
        let dir = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let bridge = makeBridge(projectPath: dir, granted: [.store])

        let (_, setError) = try await callDispatch(bridge, .storeSet, ["k", "{\"n\":1}"])
        #expect(setError == nil)

        let (getResult, getError) = try await callDispatch(bridge, .storeGet, ["k"])
        #expect(getError == nil)
        #expect(getResult as? String == "{\"n\":1}")
    }

    /// `store.set` without the `.store` grant is denied — and, crucially, the
    /// store is never reached: no state file is written.
    @Test func storeDeniedWithoutGrantWritesNothing() async throws {
        let dir = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let bridge = makeBridge(projectPath: dir, granted: [])  // no `.store`

        let (result, error) = try await callDispatch(bridge, .storeSet, ["k", "{\"n\":1}"])
        #expect(result == nil)
        #expect(error == "permission_denied: Permission 'store' is not granted to this mini-app.")

        let statePath = MiniAppStore.statePath(projectPath: dir, miniAppId: "test-app")
        #expect(!FileManager.default.fileExists(atPath: statePath))
    }

    // MARK: - Dynamic query:<kind> gate

    /// `scarf.query("kanban.tasks")` is allowed only when the matching
    /// `.query("kanban.tasks")` permission is granted. With it granted and an
    /// empty project (no kanban tenant), the handler runs and replies `[]` —
    /// the gate let it through to the service.
    @Test func queryKanbanTasksAllowedWithMatchingGrant() async throws {
        let dir = try Self.makeTempProject()   // no manifest → no tenant → "[]"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let bridge = makeBridge(projectPath: dir, granted: [.query("kanban.tasks")])

        let (result, error) = try await callDispatch(bridge, .query, ["kanban.tasks"])
        #expect(error == nil)
        #expect(result as? String == "[]")
    }

    /// The dynamic gate keys on the exact kind: a kind that isn't in the
    /// granted set is refused even when a *different* query kind is granted.
    @Test func queryNonGrantedKindRepliesPermissionDenied() async throws {
        let bridge = makeBridge(projectPath: "/tmp/scarf-q", granted: [.query("kanban.tasks")])

        let (result, error) = try await callDispatch(bridge, .query, ["sessions"])
        #expect(result == nil)
        #expect(error == "permission_denied: query:sessions is not granted")
    }

    /// A privacy-deferred kind (sessions/messages/…) that the user *did*
    /// grant passes the dynamic gate, but the handler still fail-closes with
    /// `not_implemented` — chat content isn't exposed to web content yet.
    @Test func queryPrivacyDeferredKindRepliesNotImplemented() async throws {
        let bridge = makeBridge(projectPath: "/tmp/scarf-q", granted: [.query("sessions")])

        let (result, error) = try await callDispatch(bridge, .query, ["sessions"])
        #expect(result == nil)
        #expect(error == "not_implemented: query:sessions is not available in this build")
    }

    /// The dedicated `kanban.read` method is the preflight-gated twin of
    /// `query("kanban.tasks")` (its required permission IS
    /// `query:kanban.tasks`); granted, it reaches the same handler and
    /// replies `[]` for an empty board.
    @Test func kanbanReadAllowedWithQueryGrant() async throws {
        let dir = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let bridge = makeBridge(projectPath: dir, granted: [.query("kanban.tasks")])

        let (result, error) = try await callDispatch(bridge, .kanbanRead)
        #expect(error == nil)
        #expect(result as? String == "[]")
    }

    // MARK: - file.read containment

    /// An in-root, UTF-8, under-cap file returns its text. (Containment is
    /// exhaustively covered by MiniAppAssetResolverTests in ScarfCore; here
    /// we assert the bridge wires the happy path through.)
    @Test func fileReadReturnsInRootUTF8Text() async throws {
        let dir = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data("hello world".utf8).write(to: URL(fileURLWithPath: dir + "/notes.txt"))
        let bridge = makeBridge(projectPath: dir, granted: [.fileRead])

        let (result, error) = try await callDispatch(bridge, .fileRead, ["notes.txt"])
        #expect(error == nil)
        #expect(result as? String == "hello world")
    }

    /// A `..` parent-escape path is mapped to `not_found` (the resolver
    /// refuses it before any read).
    @Test func fileReadRejectsParentEscapeAsNotFound() async throws {
        let dir = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let bridge = makeBridge(projectPath: dir, granted: [.fileRead])

        let (result, error) = try await callDispatch(bridge, .fileRead, ["../escape.txt"])
        #expect(result == nil)
        #expect(error?.hasPrefix("not_found:") == true)
    }

    /// An absolute path can't re-root out of the project (a leading `/` is
    /// treated as relative to base), so it just misses → `not_found`.
    @Test func fileReadRejectsAbsolutePathAsNotFound() async throws {
        let dir = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let bridge = makeBridge(projectPath: dir, granted: [.fileRead])

        let (result, error) = try await callDispatch(bridge, .fileRead, ["/etc/passwd"])
        #expect(result == nil)
        #expect(error?.hasPrefix("not_found:") == true)
    }

    /// A symlink planted inside the project that points at a file *outside*
    /// it is refused → `not_found`. This proves the bridge uses the
    /// symlink-hardened `containedFilePath`, not the lexical-only resolver —
    /// the exact escape that would otherwise leak `~/.hermes/auth.json`.
    @Test func fileReadRejectsSymlinkEscapeAsNotFound() async throws {
        let dir = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A secret living outside the project root.
        let outside = NSTemporaryDirectory() + "scarf-outside-" + UUID().uuidString + ".txt"
        try Data("TOP SECRET".utf8).write(to: URL(fileURLWithPath: outside))
        defer { try? FileManager.default.removeItem(atPath: outside) }
        // A symlink inside the project pointing at it.
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.txt", withDestinationPath: outside)
        let bridge = makeBridge(projectPath: dir, granted: [.fileRead])

        let (result, error) = try await callDispatch(bridge, .fileRead, ["link.txt"])
        #expect(result == nil)
        #expect(error?.hasPrefix("not_found:") == true)
    }

    /// F1, the other direction. The read is now anchored to a base resolved
    /// ONCE and required to be where it claims — and the obvious way to get
    /// that wrong is to refuse a project root that legitimately sits under a
    /// symlinked prefix, which on macOS is most temp paths (`/tmp` →
    /// `/private/tmp`) and any user who keeps projects behind a link. Both
    /// sides of the anchor comparison resolve, so this must still read.
    @Test func fileReadStillWorksWhenTheProjectRootSitsBehindALink() async throws {
        let real = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: real) }
        try Data("hello".utf8).write(to: URL(fileURLWithPath: real + "/note.txt"))
        let link = NSTemporaryDirectory() + "scarf-rootlink-" + UUID().uuidString
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        defer { try? FileManager.default.removeItem(atPath: link) }

        let bridge = makeBridge(projectPath: link, granted: [.fileRead])
        let (result, error) = try await callDispatch(bridge, .fileRead, ["note.txt"])
        #expect(error == nil)
        #expect(result as? String == "hello")
    }

    // MARK: - Harness

    /// Build a bridge with a chosen granted-permission set. `serverContext`
    /// stays `.local` (its only filesystem reads here are scoped to the temp
    /// `projectPath`, which has no manifest/tenant), and `onUIAction` is a
    /// no-op (no `ui.*` surface is exercised).
    private func makeBridge(
        projectPath: String,
        granted: Set<MiniAppPermission>,
        agentSession: MiniAppAgentSession? = nil
    ) -> ScarfMiniAppBridge {
        ScarfMiniAppBridge(
            projectPath: projectPath,
            miniAppId: "test-app",
            serverContext: .local,
            dispatcher: MiniAppBridgeDispatcher(grantedPermissions: granted),
            store: MiniAppStore(context: .local),
            context: MiniAppContext(
                projectId: "11111111-2222-3333-4444-555555555555",
                projectName: "Test",
                projectRoot: projectPath,
                serverId: "srv",
                miniAppId: "test-app",
                generated: true
            ),
            agentSession: agentSession,
            onUIAction: { _ in }
        )
    }

    /// A `MiniAppAgentSession` wired over an in-memory `FakeACPChannel`
    /// (mirrors `MiniAppAgentSessionTests.makeSession`). Never spawns a real
    /// `hermes acp`; left unprompted in these tests so the wire stays empty.
    private func makeSession(_ fake: MiniAppAgentSessionTests.FakeACPChannel) -> MiniAppAgentSession {
        MiniAppAgentSession(context: .local, projectRoot: "/tmp/scarf-miniapp-bridge-tests") { ctx in
            ACPClient(context: ctx) { _ in fake }
        }
    }

    /// Drive one `dispatch` call and await its single reply. The bridge
    /// replies either synchronously or via the main queue, so this polls a
    /// lock-guarded box with suspending sleeps — never blocking the queue the
    /// reply needs — and throws on timeout so a missing reply fails fast.
    @discardableResult
    private func callDispatch(
        _ bridge: ScarfMiniAppBridge,
        _ method: MiniAppBridgeMethod,
        _ args: [String] = [],
        timeout: TimeInterval = 3
    ) async throws -> (result: Any?, error: String?) {
        let box = ReplyBox()
        bridge.dispatch(method: method, args: args) { result, error in
            box.set(result: result, error: error)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = box.value { return r }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("dispatch(\(method.rawValue)) never replied within \(timeout)s")
        throw TimeoutError()
    }

    static func makeTempProject() throws -> String {
        let dir = NSTemporaryDirectory() + "scarf-miniappbridge-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/.scarf", withIntermediateDirectories: true)
        return dir
    }

    struct TimeoutError: Error {}

    /// One-shot, lock-guarded reply slot. The bridge invokes the reply once,
    /// possibly from the main queue; this captures it thread-safely so the
    /// awaiting test reads it back. `Any?` is non-Sendable but in practice is
    /// always `String?`/`nil`, hence `@unchecked`.
    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (result: Any?, error: String?)?
        func set(result: Any?, error: String?) {
            lock.lock(); if stored == nil { stored = (result, error) }; lock.unlock()
        }
        var value: (result: Any?, error: String?)? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }
}
