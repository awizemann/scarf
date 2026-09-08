import Testing
import Foundation
@testable import ScarfCore

/// GW-E2a — the hermes-global config surface (`~/.hermes/config.yaml`,
/// `~/.hermes/.env`, `MEMORY.md`/`USER.md`) converted from destroy-shaped
/// read-modify-write to `GuardedTextFile`.
///
/// W1 shape: everything runs against a real temp directory through
/// `LocalTransport`, because the bug is in what the WRITER BELIEVES about the
/// file — a fake transport that always answers honestly would prove nothing.
/// The unreadable cases use mode 0000, which only produces an unreadable file
/// for a non-root user, so they self-skip under root.
@Suite struct GuardedTextFileE2aTests {

    private static var runningAsRoot: Bool { getuid() == 0 }

    /// A scratch directory the caller destroys with `cleanUp`. The
    /// `withScratch` closure form cannot cross into `@MainActor` tests.
    private static func makeScratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-e2a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func cleanUp(_ base: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: base.path
        )
        try? FileManager.default.removeItem(at: base)
    }

    private static func withScratch(_ body: sending (URL) async throws -> Void) async throws {
        let base = try makeScratch()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: base.path
            )
            try? FileManager.default.removeItem(at: base)
        }
        try await body(base)
    }

    private static func writeConfig(_ ctx: ServerContext, _ yaml: String) throws {
        try FileManager.default.createDirectory(
            atPath: (ctx.paths.configYAML as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(yaml.utf8).write(to: URL(fileURLWithPath: ctx.paths.configYAML))
    }

    private static func chmod(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private static func text(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    // MARK: - The helper itself

    @Test func absentFileLoadsAsNotExistingAndStillWritesFresh() async throws {
        try await Self.withScratch { base in
            let path = base.appendingPathComponent("nothing-here.md").path
            let file = GuardedTextFile(transport: LocalTransport(), label: "test")
            let loaded = try file.load(path)
            #expect(loaded.exists == false)
            #expect(loaded.text.isEmpty)
            try file.write("fresh\n", to: path, after: loaded)
            #expect(Self.text(path) == "fresh\n")
            // Nothing was replaced, so nothing was backed up.
            #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
        }
    }

    /// Zero bytes is DAMAGE for a JSON sidecar and a LEGAL STATE here: a
    /// person can empty their `.env` or their `MEMORY.md`, and refusing to
    /// write over that would freeze the surface forever.
    @Test func emptyTextFileIsLegalAndDistinguishableFromAbsent() async throws {
        try await Self.withScratch { base in
            let path = base.appendingPathComponent("MEMORY.md").path
            FileManager.default.createFile(atPath: path, contents: Data())
            let file = GuardedTextFile(transport: LocalTransport(), label: "MEMORY.md")
            let loaded = try file.load(path)
            #expect(loaded.exists, "an empty file EXISTS — .env's header branch depends on it")
            #expect(loaded.text.isEmpty)
            try file.write("hello\n", to: path, after: loaded)
            #expect(Self.text(path) == "hello\n")
        }
    }

    @Test func unreadableFileRefusesAndLeavesTheBytesAlone() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let path = base.appendingPathComponent("config.yaml").path
            try Data("model:\n  default: gpt-4o\n".utf8)
                .write(to: URL(fileURLWithPath: path))
            try Self.chmod(path, 0o000)
            let file = GuardedTextFile(transport: LocalTransport(), label: "config.yaml")
            #expect(throws: GuardedTextFile.Refusal.self) { try file.load(path) }
            try Self.chmod(path, 0o644)
            #expect(Self.text(path) == "model:\n  default: gpt-4o\n")
        }
    }

    @Test func nonUTF8BytesAreRefusedRatherThanRebuiltFrom() async throws {
        try await Self.withScratch { base in
            let path = base.appendingPathComponent("config.yaml").path
            try Data([0xFF, 0xFE, 0x00, 0x9C]).write(to: URL(fileURLWithPath: path))
            let file = GuardedTextFile(transport: LocalTransport(), label: "config.yaml")
            #expect(throws: GuardedTextFile.Refusal.self) { try file.load(path) }
            #expect((try? Data(contentsOf: URL(fileURLWithPath: path)))?.count == 4)
        }
    }

    @Test func writeKeepsAOneDeepBakOfTheBytesItReplaces() async throws {
        try await Self.withScratch { base in
            let path = base.appendingPathComponent("config.yaml").path
            try Data("original\n".utf8).write(to: URL(fileURLWithPath: path))
            let file = GuardedTextFile(transport: LocalTransport(), label: "config.yaml")
            let loaded = try file.load(path)
            try file.write("replacement\n", to: path, after: loaded)
            #expect(Self.text(path) == "replacement\n")
            #expect(Self.text(path + ".bak") == "original\n")
        }
    }

    // MARK: - KanbanToolsetEnabler (config.yaml, both sites)

    private static let kanbanConfig = """
    model:
      default: gpt-4o
    platform_toolsets:
      cli:
        - files
        - shell

    """

    @Test func kanbanEnableWritesAndBacksUpOnAHealthyConfig() async throws {
        try await Self.withScratch { base in
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            try Self.writeConfig(ctx, Self.kanbanConfig)
            let result = await KanbanToolsetEnabler(context: ctx).enable()
            #expect(result == .enabled)
            let after = try #require(Self.text(ctx.paths.configYAML))
            #expect(after.contains("    - kanban"))
            #expect(after.contains("    - files"), "the rest of the config must survive")
            #expect(Self.text(ctx.paths.configYAML + ".bak") == Self.kanbanConfig)
        }
    }

    @Test func kanbanEnableRefusesOnAnUnreadableConfigAndLeavesItIntact() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            try Self.writeConfig(ctx, Self.kanbanConfig)
            try Self.chmod(ctx.paths.configYAML, 0o000)
            let result = await KanbanToolsetEnabler(context: ctx).enable()
            guard case .failed = result else {
                Issue.record("a blipped read must fail, not publish: \(result)")
                return
            }
            try Self.chmod(ctx.paths.configYAML, 0o644)
            #expect(Self.text(ctx.paths.configYAML) == Self.kanbanConfig)
        }
    }

    @Test func kanbanDisableRefusesOnAnUnreadableConfigAndLeavesItIntact() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let enabled = Self.kanbanConfig.replacingOccurrences(
                of: "    - shell", with: "    - shell\n    - kanban"
            )
            try Self.writeConfig(ctx, enabled)
            try Self.chmod(ctx.paths.configYAML, 0o000)
            let result = await KanbanToolsetEnabler(context: ctx).disable()
            guard case .failed = result else {
                Issue.record("a blipped read must fail, not publish: \(result)")
                return
            }
            try Self.chmod(ctx.paths.configYAML, 0o644)
            #expect(Self.text(ctx.paths.configYAML) == enabled)
        }
    }

    // MARK: - GatewayConfigWriter.saveList (config.yaml)

    @Test func gatewaySaveListSplicesAHealthyConfigAndBacksItUp() async throws {
        try await Self.withScratch { base in
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let original = "model:\n  default: gpt-4o\n"
            try Self.writeConfig(ctx, original)
            let ok = GatewayConfigWriter.saveList(
                context: ctx, platform: "slack", key: "allowed_channels", items: ["C1"]
            )
            #expect(ok)
            let after = try #require(Self.text(ctx.paths.configYAML))
            #expect(after.contains("default: gpt-4o"), "the rest of the config must survive")
            #expect(after.contains("- C1"))
            #expect(Self.text(ctx.paths.configYAML + ".bak") == original)
        }
    }

    /// The exact `readText(path) ?? ""` bug: a blipped read used to publish a
    /// config.yaml holding nothing but this one allowlist.
    @Test func gatewaySaveListRefusesOnAnUnreadableConfig() async throws {
        try #require(!Self.runningAsRoot)
        try await Self.withScratch { base in
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let original = "model:\n  default: gpt-4o\n"
            try Self.writeConfig(ctx, original)
            try Self.chmod(ctx.paths.configYAML, 0o000)
            let ok = GatewayConfigWriter.saveList(
                context: ctx, platform: "slack", key: "allowed_channels", items: ["C1"]
            )
            #expect(!ok)
            try Self.chmod(ctx.paths.configYAML, 0o644)
            #expect(Self.text(ctx.paths.configYAML) == original)
        }
    }

    // MARK: - IOSMemoryViewModel (MEMORY.md / USER.md)

    @MainActor
    @Test func iosMemorySaveRefusesOverAnUnreadableFile() async throws {
        try #require(!Self.runningAsRoot)
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        do {
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let path = IOSMemoryViewModel.Kind.memory.path(on: ctx)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try Data("the user's prose\n".utf8).write(to: URL(fileURLWithPath: path))
            try Self.chmod(path, 0o000)

            let vm = IOSMemoryViewModel(kind: .memory, context: ctx)
            await vm.load()
            // GW-F2 (DI M12): the loader no longer answers a failed read with
            // an empty buffer and an armed Save. No proof, no save — and a
            // keystroke cannot re-arm it.
            #expect(!vm.isLoaded)
            #expect(!vm.canSave)
            vm.text = "typed over a buffer nobody read\n"
            #expect(!vm.canSave, "a keystroke must not re-arm Save after a failed load")
            #expect(!vm.hasUnsavedChanges)
            let saved = await vm.save()
            #expect(!saved)
            #expect(vm.lastError != nil)

            try Self.chmod(path, 0o644)
            #expect(Self.text(path) == "the user's prose\n")
        }
    }

    @MainActor
    @Test func iosMemorySaveStillWritesAnEmptyFileAndAnAbsentOne() async throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        do {
            let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
            let path = IOSMemoryViewModel.Kind.memory.path(on: ctx)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            // Absent.
            let vm = IOSMemoryViewModel(kind: .memory, context: ctx)
            await vm.load()
            vm.text = "first\n"
            #expect(await vm.save())
            #expect(Self.text(path) == "first\n")
            // Empty — a legal state, not damage.
            try Data().write(to: URL(fileURLWithPath: path))
            await vm.load()
            vm.text = "second\n"
            #expect(await vm.save())
            #expect(Self.text(path) == "second\n")
        }
    }

    /// The disarmed state must not WEDGE: a successful load re-arms the
    /// editor, and the view re-issues `load()` on every appearance.
    @MainActor
    @Test func iosMemoryEditorRearmsAfterASuccessfulReload() async throws {
        try #require(!Self.runningAsRoot)
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
        let path = IOSMemoryViewModel.Kind.memory.path(on: ctx)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("prose\n".utf8).write(to: URL(fileURLWithPath: path))
        try Self.chmod(path, 0o000)

        let vm = IOSMemoryViewModel(kind: .memory, context: ctx)
        await vm.load()
        #expect(!vm.canSave)

        try Self.chmod(path, 0o644)
        await vm.load()
        #expect(vm.isLoaded)
        #expect(vm.text == "prose\n", "the real bytes, not the blip's emptiness")
        vm.text = "edited\n"
        #expect(vm.canSave)
        #expect(await vm.save())
        #expect(Self.text(path) == "edited\n")
    }

    // MARK: - One guard, not five copies

    /// The structural point of this sub-batch. `~/.hermes/config.yaml` had
    /// FIVE independent writers, each with its own private read
    /// (`readText(path) ?? ""`, `readFile(…) ?? nil`, `try? readFile`). They
    /// now share `GuardedTextFile`, and this test fails the moment somebody
    /// adds a sixth writer with a private copy of the guard.
    @Test func everyConfigYAMLWriterRoutesThroughTheSharedGuard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // → ScarfCoreTests
            .deletingLastPathComponent()  // → Tests
            .deletingLastPathComponent()  // → ScarfCore
            .deletingLastPathComponent()  // → Packages
            .deletingLastPathComponent()  // → scarf
            .deletingLastPathComponent()  // → repo root
        let writers = [
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanToolsetEnabler.swift",
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GatewayConfigWriter.swift",
            "scarf/scarf/Core/Services/HermesFileService.swift",
            "scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift",
            "scarf/scarf/Core/Services/HermesEnvService.swift",
        ]
        for relative in writers {
            let url = root.appendingPathComponent(relative)
            let source = try #require(
                try? String(contentsOf: url, encoding: .utf8),
                "missing \(relative) — the manifest is stale"
            )
            #expect(
                source.contains("GuardedTextFile("),
                "\(relative) writes an irreplaceable hermes-global text file and must go through GuardedTextFile"
            )
            #expect(
                !source.contains("UNGUARDED-WRITE(R)"),
                "\(relative) still carries an R annotation — a converted site's annotation is a lie"
            )
        }
    }
}
