import Testing
import Foundation
@testable import ScarfCore

/// Trust-boundary coverage for the mini-app bridge: default-deny
/// permission enforcement, the method registry, the injected JS shim, and
/// the sandboxed store.
@Suite struct MiniAppBridgeTests {

    // MARK: - Dispatcher (default-deny)

    @Test func ungatedSurfacesAllowedWithNoGrants() {
        let d = MiniAppBridgeDispatcher(grantedPermissions: [])
        for m in [MiniAppBridgeMethod.contextGet, .uiToast, .uiSetTitle, .uiResize, .uiRequestClose] {
            #expect(d.preflight(m) == nil, "\(m.rawValue) should be ungated")
        }
    }

    @Test func storeDeniedWithoutGrantAllowedWithGrant() {
        let denied = MiniAppBridgeDispatcher(grantedPermissions: [])
        #expect(denied.preflight(.storeGet)?.errorCode == "permission_denied")
        #expect(denied.preflight(.storeSet)?.errorCode == "permission_denied")

        let granted = MiniAppBridgeDispatcher(grantedPermissions: [.store])
        #expect(granted.preflight(.storeGet) == nil)
        #expect(granted.preflight(.storeSet) == nil)
    }

    @Test func dataChannelGating() {
        // All surfaces are implemented now; gating is purely by permission.
        // file.read → file:read.
        #expect(MiniAppBridgeDispatcher(grantedPermissions: []).preflight(.fileRead)?.errorCode == "permission_denied")
        #expect(MiniAppBridgeDispatcher(grantedPermissions: [.fileRead]).preflight(.fileRead) == nil)
        // kanban.read → query:kanban.tasks.
        #expect(MiniAppBridgeDispatcher(grantedPermissions: []).preflight(.kanbanRead)?.errorCode == "permission_denied")
        #expect(MiniAppBridgeDispatcher(grantedPermissions: [.query("kanban.tasks")]).preflight(.kanbanRead) == nil)
        // query's static perm is nil (the kind-specific query:<kind> check is
        // enforced in the handler), so preflight passes.
        #expect(MiniAppBridgeDispatcher(grantedPermissions: []).preflight(.query) == nil)
    }

    @Test func agentChannelGatedAndImplemented() {
        // prompt + events are now wired: denied without grant, authorized
        // (nil) with it.
        #expect(MiniAppBridgeDispatcher(grantedPermissions: []).preflight(.promptSend)?.errorCode == "permission_denied")
        #expect(MiniAppBridgeDispatcher(grantedPermissions: [.prompt]).preflight(.promptSend) == nil)
        #expect(MiniAppBridgeDispatcher(grantedPermissions: []).preflight(.eventsSubscribe)?.errorCode == "permission_denied")
        #expect(MiniAppBridgeDispatcher(grantedPermissions: [.events]).preflight(.eventsSubscribe) == nil)
    }

    @Test func methodPermissionMap() {
        #expect(MiniAppBridgeMethod.storeGet.requiredPermission == .store)
        #expect(MiniAppBridgeMethod.promptSend.requiredPermission == .prompt)
        #expect(MiniAppBridgeMethod.eventsSubscribe.requiredPermission == .events)
        #expect(MiniAppBridgeMethod.kanbanRead.requiredPermission == .query("kanban.tasks"))
        #expect(MiniAppBridgeMethod.contextGet.requiredPermission == nil)
        #expect(MiniAppBridgeMethod.uiToast.requiredPermission == nil)
    }

    // MARK: - Rate limiter

    @Test func rateLimiterSlidingWindow() {
        let rl = MiniAppRateLimiter(maxEvents: 2, windowSeconds: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        var (allowed, hist) = rl.decide(now: t0, history: [])
        #expect(allowed); #expect(hist.count == 1)
        (allowed, hist) = rl.decide(now: t0.addingTimeInterval(1), history: hist)
        #expect(allowed); #expect(hist.count == 2)
        // Third within the window → denied, history unchanged.
        (allowed, hist) = rl.decide(now: t0.addingTimeInterval(2), history: hist)
        #expect(!allowed); #expect(hist.count == 2)
        // Once the window slides past the earlier calls → allowed again.
        (allowed, hist) = rl.decide(now: t0.addingTimeInterval(61), history: hist)
        #expect(allowed); #expect(hist.count == 1)
    }

    // MARK: - JS shim

    @Test func javaScriptSourceShape() {
        let ctx = MiniAppContext(
            projectId: "11111111-2222-3333-4444-555555555555",
            projectName: "Demo", projectRoot: "/tmp/demo",
            serverId: "srv", miniAppId: "burndown", generated: false
        )
        let js = MiniAppBridge.javaScriptSource(context: ctx)
        #expect(js.contains("messageHandlers.scarfbridge.postMessage"))
        #expect(js.contains("version: \"\(miniAppBridgeVersion)\""))
        #expect(js.contains("\"burndown\""))                 // context baked in
        #expect(js.contains("Object.defineProperty(window, \"scarf\""))
        #expect(js.contains("Object.freeze"))
        // The deferred event channel must throw, not silently no-op.
        #expect(js.contains("onEvent"))
        // onEvent hands the caller no promise, so the shim must settle the
        // events.subscribe rejection itself — a denied `events` grant must
        // not surface as an unhandled rejection in the mini-app's console.
        #expect(js.contains("post(\"events.subscribe\", []).catch("))
        #expect(js.contains("console.warn(\"scarf.onEvent: \""))
    }

    @Test func minBridgeVersionGate() {
        // Host provides miniAppBridgeVersion ("1.0").
        #expect(MiniAppBridge.satisfiesMinBridgeVersion("1.0"))
        #expect(MiniAppBridge.satisfiesMinBridgeVersion("0.9"))   // older requirement ok
        #expect(MiniAppBridge.satisfiesMinBridgeVersion("1"))     // "1" → 1.0
        #expect(!MiniAppBridge.satisfiesMinBridgeVersion("1.1"))  // needs a newer minor
        #expect(!MiniAppBridge.satisfiesMinBridgeVersion("2.0"))  // needs a newer major
    }

    @Test func contextRoundTrips() throws {
        let ctx = MiniAppContext(
            projectId: "p", projectName: "N", projectRoot: "/r",
            serverId: "s", miniAppId: "m", generated: true
        )
        let decoded = try JSONDecoder().decode(MiniAppContext.self, from: JSONEncoder().encode(ctx))
        #expect(decoded == ctx)
        #expect(decoded.bridgeVersion == miniAppBridgeVersion)
    }

    // MARK: - MiniAppStore (sandboxed KV)

    @Test func storeRoundTripsAndIsolatesByMiniApp() throws {
        let dir = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = MiniAppStore(context: .local)

        #expect(store.get(projectPath: dir, miniAppId: "a", key: "k") == nil)
        try store.set(projectPath: dir, miniAppId: "a", key: "k", value: "{\"n\":1}")
        #expect(store.get(projectPath: dir, miniAppId: "a", key: "k") == "{\"n\":1}")
        // Different mini-app id is a separate sandbox.
        #expect(store.get(projectPath: dir, miniAppId: "b", key: "k") == nil)
        // State file lives under the mini-app's own directory.
        let path = MiniAppStore.statePath(projectPath: dir, miniAppId: "a")
        #expect(path.hasSuffix("/.scarf/miniapps/a/state.json"))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func storeRejectsEmptyKey() throws {
        let dir = try Self.makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(throws: MiniAppStore.StoreError.self) {
            try MiniAppStore(context: .local).set(projectPath: dir, miniAppId: "a", key: "", value: "1")
        }
    }

    static func makeTempProject() throws -> String {
        let dir = NSTemporaryDirectory() + "scarf-miniappstore-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/.scarf", withIntermediateDirectories: true)
        return dir
    }
}
