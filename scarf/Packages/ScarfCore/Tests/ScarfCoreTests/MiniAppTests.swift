import Testing
import Foundation
@testable import ScarfCore

/// Model-layer coverage for Milestone 2 mini-apps: permission + manifest
/// Codable, on-disk discovery via `MiniAppService`, and `ProjectStore`
/// populating `ScarfProject.miniApps`. Pure data + temp dirs — no Xcode,
/// no real `~/.hermes`.
@Suite struct MiniAppTests {

    // MARK: - MiniAppPermission

    @Test func permissionRawValueRoundTrips() {
        let cases: [(MiniAppPermission, String)] = [
            (.prompt, "prompt"),
            (.events, "events"),
            (.store, "store"),
            (.net, "net"),
            (.kanbanWrite, "kanban:write"),
            (.fileRead, "file:read"),
            (.fileWrite, "file:write"),
            (.query("kanban.tasks"), "query:kanban.tasks"),
            (.unknown("future:thing"), "future:thing"),
        ]
        for (perm, raw) in cases {
            #expect(perm.rawValue == raw)
            #expect(MiniAppPermission(rawValue: raw) == perm)
        }
    }

    @Test func permissionDecodesFromStringArray() throws {
        let json = #"["prompt","query:messages","kanban:write","weird"]"#
        let perms = try JSONDecoder().decode([MiniAppPermission].self, from: Data(json.utf8))
        #expect(perms == [.prompt, .query("messages"), .kanbanWrite, .unknown("weird")])
        // Encode round-trips back to the same strings.
        let reencoded = try JSONEncoder().encode(perms)
        let strings = try JSONDecoder().decode([String].self, from: reencoded)
        #expect(strings == ["prompt", "query:messages", "kanban:write", "weird"])
    }

    @Test func sensitivePermissionsAreFlagged() {
        #expect(MiniAppPermission.net.isSensitive)
        #expect(MiniAppPermission.fileWrite.isSensitive)
        #expect(MiniAppPermission.kanbanWrite.isSensitive)
        #expect(MiniAppPermission.unknown("x").isSensitive)  // deny-by-default
        #expect(MiniAppPermission.prompt.isSensitive)         // drives a tool-enabled agent
        #expect(!MiniAppPermission.query("kanban.tasks").isSensitive)  // allow-listed read-only kind
        #expect(MiniAppPermission.query("sessions").isSensitive)       // non-allowlisted kind → sensitive (default-off for generated)
        // Whole-project read is an elevation, not a default: `.env`,
        // `*.pem` and `config.yaml` live under a project root, so an
        // agent-generated app must not get `file:read` pre-ticked.
        #expect(MiniAppPermission.fileRead.isSensitive)
        #expect(!MiniAppPermission.store.isSensitive)
        #expect(!MiniAppPermission.events.isSensitive)
    }

    /// The launch sheet's default policy: nothing sensitive is pre-checked
    /// for an agent-generated mini-app. Pins the property `defaultChecked()`
    /// in `MiniAppPermissionPreview` actually relies on.
    @Test func agentGeneratedAppsGetNoSensitivePermissionByDefault() {
        let declared: [MiniAppPermission] = [.store, .events, .fileRead, .prompt, .net, .query("kanban.tasks")]
        let preTicked = declared.filter { !$0.isSensitive }
        #expect(Set(preTicked) == Set([.store, .events, .query("kanban.tasks")]))
    }

    // MARK: - MiniAppManifest

    @Test func manifestMinimalDecodeFillsDefaults() throws {
        let json = #"{ "id": "burndown", "name": "Burndown" }"#
        let m = try JSONDecoder().decode(MiniAppManifest.self, from: Data(json.utf8))
        #expect(m.id == "burndown")
        #expect(m.name == "Burndown")
        #expect(m.entry == "index.html")
        #expect(m.version == "1.0.0")
        #expect(m.minBridgeVersion == "1.0")
        #expect(m.permissions.isEmpty)        // default-deny
        #expect(m.generated == false)
        #expect(m.panelHint == nil)
    }

    @Test func manifestFullRoundTrips() throws {
        let json = """
        {
          "id": "burndown", "name": "Burndown", "version": "2.1.0",
          "entry": "app.html", "minBridgeVersion": "1.0",
          "permissions": ["query:kanban.tasks", "prompt", "events", "store"],
          "panelHint": { "preferredWidth": 420, "placement": "panel" },
          "generated": true
        }
        """
        let m = try JSONDecoder().decode(MiniAppManifest.self, from: Data(json.utf8))
        #expect(m.entry == "app.html")
        #expect(m.generated == true)
        #expect(m.permissions.contains(.prompt))
        #expect(m.permissions.contains(.query("kanban.tasks")))
        #expect(m.panelHint?.preferredWidth == 420)
        #expect(m.panelHint?.placement == "panel")
        // Re-encode + decode is stable.
        let again = try JSONDecoder().decode(MiniAppManifest.self, from: JSONEncoder().encode(m))
        #expect(again == m)
    }

    // MARK: - MiniAppService discovery

    @Test func discoverFindsMiniAppsAndForcesDirId() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Two valid mini-apps; the second's manifest LIES about its id —
        // discovery must force the id to the directory name.
        try Self.writeMiniApp(dir, id: "alpha", manifest: #"{ "id": "alpha", "name": "Alpha" }"#)
        try Self.writeMiniApp(dir, id: "beta", manifest: #"{ "id": "NOT-beta", "name": "Beta", "generated": true }"#)
        // A stray dir with no miniapp.json is ignored.
        try FileManager.default.createDirectory(atPath: dir + "/.scarf/miniapps/empty", withIntermediateDirectories: true)

        let svc = MiniAppService(context: .local)
        let found = svc.discover(projectPath: dir)
        #expect(found.map(\.id) == ["alpha", "beta"])  // sorted, "empty" skipped
        let beta = found.first { $0.id == "beta" }
        #expect(beta?.id == "beta")           // forced to dir name, not "NOT-beta"
        #expect(beta?.generated == true)

        let refs = svc.discoverRefs(projectPath: dir)
        #expect(refs.map(\.id) == ["alpha", "beta"])
        #expect(refs.first { $0.id == "beta" }?.generated == true)
    }

    @Test func discoverSkipsInvalidIds() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Self.writeMiniApp(dir, id: "good", manifest: #"{ "id": "good", "name": "Good" }"#)
        try Self.writeMiniApp(dir, id: "has space", manifest: #"{ "id": "x", "name": "Spacey" }"#)
        try Self.writeMiniApp(dir, id: ".hidden", manifest: #"{ "id": "y", "name": "Hidden" }"#)

        #expect(MiniAppService(context: .local).discover(projectPath: dir).map(\.id) == ["good"])
        #expect(MiniAppService.isValidMiniAppId("good"))
        #expect(MiniAppService.isValidMiniAppId("a-b_c.1"))
        #expect(!MiniAppService.isValidMiniAppId("has space"))
        #expect(!MiniAppService.isValidMiniAppId(".hidden"))
        #expect(!MiniAppService.isValidMiniAppId(""))
        #expect(!MiniAppService.isValidMiniAppId("a/b"))
    }

    @Test func discoverEmptyWhenNoMiniAppsDir() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(MiniAppService(context: .local).discover(projectPath: dir).isEmpty)
    }

    // MARK: - ProjectStore.derive includes miniApps

    @Test func deriveDiscoversMiniApps() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-miniapp-derive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let projectDir = home.appendingPathComponent("proj", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: projectDir + "/.scarf", withIntermediateDirectories: true)
        try Self.writeMiniApp(projectDir, id: "board", manifest: #"{ "id": "board", "name": "Board" }"#)

        let ctx = ServerContext.local(home: home)
        let derived = ProjectStore(context: ctx).derive(from: ProjectEntry(name: "Proj", path: projectDir))
        #expect(derived.miniApps.map(\.id) == ["board"])
    }

    // MARK: - ScarfProject.miniApps round-trip

    @Test func scarfProjectMiniAppsRoundTrip() throws {
        let p = ScarfProject(
            name: "X", rootPath: "/tmp/x",
            miniApps: [.init(id: "a"), .init(id: "b", generated: true)]
        )
        let decoded = try JSONDecoder().decode(ScarfProject.self, from: JSONEncoder().encode(p))
        #expect(decoded.miniApps.map(\.id) == ["a", "b"])
        #expect(decoded.miniApps.first { $0.id == "b" }?.generated == true)
    }

    /// A `miniApps` entry written by an older Scarf WITHOUT the `generated`
    /// key must decode to `generated == false` — the conservative trust
    /// default the permission sheet keys off. Pins the custom `MiniAppRef`
    /// decoder so a future change can't silently flip the default.
    @Test func miniAppRefDefaultsGeneratedFalseWhenKeyAbsent() throws {
        let json = """
        {
          "id": "AAAAAAAA-1111-2222-3333-444444444444",
          "name": "Legacy",
          "rootPath": "/tmp/legacy",
          "miniApps": [{ "id": "old-app" }]
        }
        """
        let decoded = try JSONDecoder().decode(ScarfProject.self, from: Data(json.utf8))
        let ref = try #require(decoded.miniApps.first)
        #expect(ref.id == "old-app")
        #expect(ref.generated == false)
    }

    // MARK: - Helpers

    static func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "scarf-miniapp-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeMiniApp(_ projectDir: String, id: String, manifest: String) throws {
        let appDir = projectDir + "/.scarf/miniapps/" + id
        try FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        try manifest.data(using: .utf8)!.write(to: URL(fileURLWithPath: appDir + "/miniapp.json"))
    }
}
