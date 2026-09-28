import Testing
import Foundation
import ScarfCore
@testable import scarf

// B12 — follow-ups to the blind re-audit: custom providers reach every model
// picker, the template export sheet re-checks its files, and Mattermost's
// `.env` line is only dropped after config.yaml took the value.

private func scratchContext(_ tag: String) -> ServerContext {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("scarf-b12-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return .local(home: home)
}

@MainActor
private func until(timeout: TimeInterval, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private let customProviderYAML = """
model:
  default: qwen3
  provider: my-lab
providers:
  my-lab:
    base_url: http://lab:8000/v1

"""

@Suite("B12 — custom providers, export rescan, Mattermost unset order")
@MainActor
struct BlindB12Tests {

    // MARK: - Model presets + chat preflight get config.yaml's custom providers

    @Test func presetEditorReadsTheMainProfilesCustomProviders() async throws {
        let ctx = scratchContext("presets")
        try customProviderYAML.write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let vm = ModelPresetsViewModel(context: ctx)
        #expect(vm.customProviders == .none)
        vm.refreshCustomProviders()
        await until(timeout: 10) { vm.customProviders != .none }
        #expect(vm.customProviders.names.contains("my-lab"))
    }

    @Test func chatPreflightSheetGetsTheCustomProviders() async throws {
        let ctx = scratchContext("chat")
        try customProviderYAML.write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let vm = ChatViewModel(context: ctx)
        vm.knownProviderIDs = ["anthropic"]
        vm.refreshConfigDiagnostics()
        await until(timeout: 10) { vm.customProviders != .none }
        #expect(vm.customProviders.names.contains("my-lab"))
    }

    // MARK: - Template export re-checks the project folder

    @Test func exportSheetRescanPicksUpAFileAddedWhileOpen() async throws {
        let ctx = scratchContext("export")
        let dir = ctx.paths.home + "/proj"
        try FileManager.default.createDirectory(atPath: dir + "/.scarf", withIntermediateDirectories: true)
        for rel in ["README.md", ".scarf/dashboard.json"] {
            FileManager.default.createFile(atPath: dir + "/" + rel, contents: Data())
        }
        let vm = TemplateExporterViewModel(context: ctx, project: ProjectEntry(name: "P", path: dir))
        await vm.rescanFiles()?.value
        #expect(vm.fileScan?.agentsMdPresent == false)
        #expect(!vm.requiredFilesPresent)

        FileManager.default.createFile(atPath: dir + "/AGENTS.md", contents: Data())
        await vm.rescanFiles()?.value
        #expect(vm.fileScan?.agentsMdPresent == true)
        #expect(vm.requiredFilesPresent)
        #expect(!vm.isRescanning)
    }

    // MARK: - Mattermost: .env line survives a failed config write

    @Test func aFailedConfigWriteKeepsTheEnvLine() {
        let ctx = scratchContext("mm-fail")
        let env = "MATTERMOST_URL=https://mm.example\nMATTERMOST_REQUIRE_MENTION=true\n"
        try? env.write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        let outcome = PlatformSetupHelpers.saveForm(
            context: ctx,
            envPairs: ["MATTERMOST_URL": "https://mm.example"],
            configKV: ["mattermost.require_mention": "false"],
            envUnsetAfterConfig: ["MATTERMOST_REQUIRE_MENTION"],
            runner: { _, _ in ("boom", 1) }
        )
        #expect(outcome.isFailure)
        let after = (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
        #expect(after.contains("\nMATTERMOST_REQUIRE_MENTION=true"), "\(after)")
        #expect(!after.contains("# MATTERMOST_REQUIRE_MENTION"), "\(after)")
    }

    @Test func aSuccessfulConfigWriteThenDropsTheEnvLine() {
        let ctx = scratchContext("mm-ok")
        try? "MATTERMOST_REQUIRE_MENTION=true\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        let outcome = PlatformSetupHelpers.saveForm(
            context: ctx,
            envPairs: [:],
            configKV: ["mattermost.require_mention": "false"],
            envUnsetAfterConfig: ["MATTERMOST_REQUIRE_MENTION"],
            runner: { args, _ in
                ("✓ Set \(args.last ?? "") in config.yaml", 0)
            }
        )
        #expect(!outcome.isFailure)
        let after = (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
        #expect(after.contains("# MATTERMOST_REQUIRE_MENTION=true"), "\(after)")
    }
}
