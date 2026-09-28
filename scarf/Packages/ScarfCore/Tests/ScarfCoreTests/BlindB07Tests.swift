import Testing
import Foundation
@testable import ScarfCore

/// Blind re-audit phase B07: iOS memory conflict check (S14-F2), the Logs
/// component filter (S14-F3), the `.managed` false opt-out (S05-F3) and the
/// Vercel Sandbox backend bands (S05-F2).
@Suite struct BlindB07Tests {

    // MARK: - S14-F2 iOS memory Save conflict check

    private static func scratchContext() throws -> (ServerContext, URL, String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
        let path = IOSMemoryViewModel.Kind.memory.path(on: ctx)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return (ctx, base, path)
    }

    private static func text(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The agent writes an entry while the editor is open: Save must refuse,
    /// keep the agent's entry on disk, keep the draft, and hand back the
    /// on-disk text.
    @MainActor
    @Test func saveRefusesWhenTheAgentChangedTheFileMeanwhile() async throws {
        let (ctx, base, path) = try Self.scratchContext()
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("§ first entry\n".utf8).write(to: URL(fileURLWithPath: path))

        let vm = IOSMemoryViewModel(kind: .memory, context: ctx)
        await vm.load()
        vm.text = "§ first entry\n§ my edit\n"

        let agentVersion = "§ first entry\n§ agent added this\n"
        try Data(agentVersion.utf8).write(to: URL(fileURLWithPath: path))

        let saved = await vm.save()
        #expect(!saved)
        #expect(vm.conflictOnDisk == agentVersion)
        #expect(vm.lastError == nil, "a conflict is a question, not a failure")
        #expect(Self.text(path) == agentVersion, "the agent's entry must survive")
        #expect(vm.text == "§ first entry\n§ my edit\n", "the draft is kept")

        // "Keep editing" keeps the same baseline, so a second Save still refuses.
        vm.dismissConflict()
        #expect(await vm.save() == false)
        #expect(vm.conflictOnDisk == agentVersion)

        // "Reload" takes the server's text and re-arms a clean editor.
        vm.acceptOnDiskVersion()
        #expect(vm.conflictOnDisk == nil)
        #expect(vm.text == agentVersion)
        #expect(!vm.hasUnsavedChanges)

        // …and an edit on top of it saves normally, round-tripping through load.
        vm.text = agentVersion + "§ after reload\n"
        #expect(await vm.save())
        let reread = IOSMemoryViewModel(kind: .memory, context: ctx)
        await reread.load()
        #expect(reread.text == agentVersion + "§ after reload\n")
    }

    /// "Overwrite" is the user's explicit answer: it publishes the draft.
    @MainActor
    @Test func forcedSaveOverwritesAfterAConflict() async throws {
        let (ctx, base, path) = try Self.scratchContext()
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: path))
        let vm = IOSMemoryViewModel(kind: .memory, context: ctx)
        await vm.load()
        vm.text = "mine\n"
        try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(await vm.save() == false)
        vm.dismissConflict()
        #expect(await vm.save(force: true))
        #expect(Self.text(path) == "mine\n")
        #expect(vm.conflictOnDisk == nil)
        #expect(!vm.hasUnsavedChanges)
    }

    /// An unchanged file still saves on the first try, and a file that was
    /// absent at load still creates (both baselines are "").
    @MainActor
    @Test func unchangedAndAbsentFilesStillSave() async throws {
        let (ctx, base, path) = try Self.scratchContext()
        defer { try? FileManager.default.removeItem(at: base) }
        let vm = IOSMemoryViewModel(kind: .memory, context: ctx)
        await vm.load()
        vm.text = "created\n"
        #expect(await vm.save())
        vm.text = "created\nedited\n"
        #expect(await vm.save())
        #expect(Self.text(path) == "created\nedited\n")
    }

    /// A file created by the agent after the editor loaded it as absent is a
    /// conflict, not something to publish over.
    @MainActor
    @Test func fileCreatedAfterAnAbsentLoadIsAConflict() async throws {
        let (ctx, base, path) = try Self.scratchContext()
        defer { try? FileManager.default.removeItem(at: base) }
        let vm = IOSMemoryViewModel(kind: .memory, context: ctx)
        await vm.load()
        vm.text = "mine\n"
        try Data("agent\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(await vm.save() == false)
        #expect(vm.conflictOnDisk == "agent\n")
        #expect(Self.text(path) == "agent\n")
    }

    // MARK: - S14-F3 Logs component filter

    /// Real logger names from a v0.21.5 `agent.log`, classified the way
    /// Hermes's `COMPONENT_PREFIXES` (hermes_logging.py:159-169) does.
    @Test func componentPrefixesMatchHermesLoggerNames() {
        typealias C = LogsViewModel.LogComponent
        #expect(C.cli.matches(logger: "hermes_cli.main"))
        #expect(C.cli.matches(logger: "cli"))
        #expect(!C.agent.matches(logger: "hermes_cli.main"))
        #expect(C.agent.matches(logger: "run_agent"))
        #expect(C.agent.matches(logger: "model_tools"))
        #expect(C.agent.matches(logger: "agent.auxiliary_client"))
        #expect(C.agent.matches(logger: "batch_runner"))
        #expect(C.gateway.matches(logger: "gateway.run"))
        #expect(C.gateway.matches(logger: "plugins.platforms.telegram"))
        #expect(C.gateway.matches(logger: "hermes_plugins.slack"))
        #expect(!C.gateway.matches(logger: "plugins.memory"))
        #expect(C.tools.matches(logger: "tools.terminal_tool"))
        #expect(C.cron.matches(logger: "cron.scheduler"))
        #expect(!C.cron.matches(logger: "hermes_state"))
        #expect(C.all.matches(logger: "anything"))
    }

    @Test @MainActor func cliFilterNoLongerHidesHermesCliLines() {
        let vm = LogsViewModel(context: .local)
        vm.entries = [
            LogEntry(id: 1, timestamp: "t", level: .info, sessionId: nil, logger: "hermes_cli.config", message: "a", raw: "a"),
            LogEntry(id: 2, timestamp: "t", level: .info, sessionId: nil, logger: "run_agent", message: "b", raw: "b"),
            LogEntry(id: 3, timestamp: "t", level: .info, sessionId: nil, logger: "gateway.run", message: "c", raw: "c"),
        ]
        vm.selectedComponent = .cli
        #expect(vm.filteredEntries.map(\.id) == [1])
        vm.selectedComponent = .agent
        #expect(vm.filteredEntries.map(\.id) == [2])
    }

    // MARK: - S05-F3 `.managed` explicit opt-out

    @Test func falseMarkerIsAnOptOutFromV0213() {
        let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
        #expect(v0213.hasManagedMarkerFalseOptOut)
        #expect(!v0212.hasManagedMarkerFalseOptOut)
        #expect(!HermesCapabilities.empty.hasManagedMarkerFalseOptOut)

        for raw in ["false", "0", "no", "OFF\n", " No "] {
            #expect(HermesManagedInstall.system(
                fromMarker: raw, readsMarkerContents: true, honoursFalseOptOut: true) == nil, "\(raw)")
        }
        // Below the floor Hermes calls the host managed by "false".
        #expect(HermesManagedInstall.system(
            fromMarker: "false", readsMarkerContents: true, honoursFalseOptOut: false) == "false")
        // Truthy and named markers are unchanged.
        #expect(HermesManagedInstall.system(
            fromMarker: "1", readsMarkerContents: true, honoursFalseOptOut: true) == "nixos")
        #expect(HermesManagedInstall.system(
            fromMarker: "home-manager", readsMarkerContents: true, honoursFalseOptOut: true) == "home-manager")
    }

    /// The probe threads the flag through: a v0.21.5 host with a `false`
    /// marker is writable, a v0.21.2 host with the same marker is not.
    @Test func probeHonoursTheOptOutOnlyWhereTheHostDoes() {
        let cache = HermesManagedInstallCache(probe: { _ in "false\n" })
        let ctx = ServerContext.local(home: URL(fileURLWithPath: "/tmp/scarf-b07-managed-\(UUID().uuidString)"))
        let new = cache.managedInstall(for: ctx, capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)"))
        #expect(!new.isManaged)
        let old = cache.managedInstall(for: ctx, capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)"))
        #expect(old.system == "false")
    }

    // MARK: - S05-F2 Vercel Sandbox backend bands

    @Test func vercelSandboxFollowsItsTwoBands() {
        func caps(_ v: String) -> HermesCapabilities { HermesCapabilities.parseLine("Hermes Agent v\(v)") }
        #expect(!caps("0.11.0").hasVercelTerminal)
        #expect(caps("0.12.0").hasVercelTerminal)
        #expect(caps("0.14.0").hasVercelTerminal)
        #expect(!caps("0.15.0").hasVercelTerminal)
        #expect(!caps("0.19.0").hasVercelTerminal)
        #expect(caps("0.19.1").hasVercelTerminal)
        #expect(caps("0.21.5").hasVercelTerminal)
        #expect(!HermesCapabilities.empty.hasVercelTerminal)
    }
}
