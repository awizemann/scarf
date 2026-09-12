import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P39 — the Mac surfaces that used to banner success over a refused write.
///
/// The CLI fake returns Hermes's own managed-install refusal at **exit 0**,
/// exactly as `set_config_value` does (`hermes_cli/config.py:3450-3452` →
/// `format_managed_message`, `:445-450`, on stderr, then a bare `return`).
/// Before P39 each of these paths read `exitCode == 0` and reported a save.
@Suite("P39 — managed-install refusals on the Mac surfaces")
@MainActor
struct HermesManagedRefusalP39Tests {

    private typealias CLILog = HermesP35ApprovalsHostDefaultTests.CLILog

    /// Verbatim `format_managed_message("set configuration values")`.
    static let managedSetRefusal = """
    Cannot set configuration values: this Hermes installation is managed by nixos.
    Use your package manager to upgrade or reinstall Hermes.
    """

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p39-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    private static func viewModel(_ log: CLILog) -> SettingsViewModel {
        SettingsViewModel(context: scratchContext(), cliRunner: log.runner())
    }

    /// Wait on the OBSERVABLE, not the clock. `SettingsViewModel.writeChain`
    /// is the `Task` every settings write is serialised through, and its
    /// last act is `commitConfigWrite` — the banner these tests assert on —
    /// so awaiting it is precisely "the write finished and said so". This
    /// used to poll for a call and then nap a flat 300 ms (P45 finding 12).
    ///
    /// `expectingACall: false` is the "nothing must run" shape: there is no
    /// observable to wait FOR, so it polls to a short deadline, breaking out
    /// early if a call does appear — the caller's `#expect(log.calls.isEmpty)`
    /// is what then fails.
    private static func settle(
        _ vm: SettingsViewModel, _ log: CLILog, expectingACall: Bool = true
    ) async {
        if !expectingACall {
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline, log.calls.isEmpty, vm.writeChain == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await vm.writeChain?.value
    }

    // MARK: - Settings

    /// The headline defect: `setSetting` judged by exit code, and a managed
    /// host refuses at exit 0. Every toggle, stepper and picker in Settings
    /// banner'd "Saved <key>" over a config.yaml the host never wrote.
    @Test func aRefusedSettingsWriteBannersTheRefusalNotSaved() async {
        let log = CLILog(output: Self.managedSetRefusal, exitCode: 0)
        let vm = Self.viewModel(log)

        vm.setSetting("display.streaming", value: "true")
        await Self.settle(vm, log)

        #expect(vm.saveMessageIsFailure, "a refused write reported success")
        #expect(vm.message?.contains("managed by nixos") == true,
                "the banner did not quote Hermes's own reason: \(vm.message ?? "nil")")
    }

    /// And the argv carries the `--` separator, so a value like `-1` is a
    /// value and not an option (`config set`'s positionals are `nargs="?"`,
    /// `hermes_cli/subcommands/config.py:24-31` @ v2026.9.7).
    @Test func theSettingsWriteArgvSeparatesThePositionals() async throws {
        let log = CLILog(output: "✓ Set model.context_length = -1 in /tmp/config.yaml", exitCode: 0)
        let vm = Self.viewModel(log)

        vm.setSetting("model.context_length", value: "-1")
        await Self.settle(vm, log)

        let call = try #require(log.calls.first)
        #expect(call == ["config", "set", "--", "model.context_length", "-1"])
    }

    /// A genuine success is still a success — this is the C1 half: a host
    /// without `.managed` behaves exactly as before.
    @Test func anOrdinaryHostStillReportsASave() async {
        let log = CLILog(output: "✓ Set display.streaming = true in /tmp/config.yaml", exitCode: 0)
        let vm = Self.viewModel(log)

        vm.setSetting("display.streaming", value: "true")
        await Self.settle(vm, log)

        #expect(vm.saveMessageIsFailure == false)
        #expect(vm.message?.contains("Saved display.streaming") == true)
    }

    /// `hermes memory off` is the fourth `save_config` door
    /// (`hermes_cli/main_agent_cmds.py:10-18`): it prints
    /// `✓ Memory provider: built-in only` (`:17`) after a save the managed arm
    /// refused at exit 0.
    @Test func aRefusedMemoryOffBannersTheRefusal() async throws {
        let log = CLILog(output: """
        Cannot save configuration: this Hermes installation is managed by nixos.
        Use your package manager to upgrade or reinstall Hermes.

          ✓ Memory provider: built-in only
          Saved to config.yaml
        """, exitCode: 0)
        let vm = Self.viewModel(log)

        vm.setMemoryProvider("")
        await Self.settle(vm, log)

        let call = try #require(log.calls.first)
        #expect(call == ["memory", "off"])
        #expect(vm.saveMessageIsFailure, "a refused `memory off` reported success")
    }

    // MARK: - Platform setup forms (all 15)

    /// `PlatformSetupHelpers.saveForm`'s per-key loop judged by exit code, so
    /// all fifteen forms reported "Saved — restart gateway to apply" over a
    /// file the managed host never wrote.
    @Test func aRefusedPlatformFormSaveIsAFailure() {
        let log = CLILog(output: Self.managedSetRefusal, exitCode: 0)
        let outcome = PlatformSetupHelpers.saveForm(
            context: Self.scratchContext(),
            envPairs: [:],
            configKV: ["platforms.telegram.enabled": "true"],
            runner: log.runner()
        )
        #expect(outcome.isFailure, "a refused form save reported success")
        #expect(outcome.text.contains("platforms.telegram.enabled"))
    }

    @Test func anOrdinaryPlatformFormSaveStillSucceeds() {
        let log = CLILog(
            output: "✓ Set platforms.telegram.enabled = true in /tmp/config.yaml", exitCode: 0)
        let outcome = PlatformSetupHelpers.saveForm(
            context: Self.scratchContext(),
            envPairs: [:],
            configKV: ["platforms.telegram.enabled": "true"],
            runner: log.runner()
        )
        #expect(outcome.isFailure == false, "an accepted form save reported failure")
    }

    @Test func theFormArgvSeparatesThePositionals() throws {
        let log = CLILog(output: "✓ Set a.b = -1 in /tmp/config.yaml", exitCode: 0)
        _ = PlatformSetupHelpers.saveForm(
            context: Self.scratchContext(),
            envPairs: [:],
            configKV: ["a.b": "-1"],
            runner: log.runner()
        )
        let call = try #require(log.calls.first)
        #expect(call == ["config", "set", "--", "a.b", "-1"])
    }
}

/// P39 / round-4 decision 11 — a bot's model-pin clear.
@Suite("P39 — bot model-pin clear verdicts")
struct BotAgentClearPinP39Tests {

    private static func result(_ output: String, _ exitCode: Int32) -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: Data(output.utf8), stderr: Data())
    }

    private static func stderrResult(_ output: String, _ exitCode: Int32) -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: Data(), stderr: Data(output.utf8))
    }

    /// The hole P39 closed: `isBenignUnset` opened with
    /// `guard result.exitCode != 0 else { return true }`, so ANY exit 0 was
    /// "fine" — including `unset_config_value`'s managed arm, which prints to
    /// stderr and bare-`return`s (`hermes_cli/config.py:3549-3551` @
    /// v2026.9.7). The Clear button reported success over an untouched pin.
    @Test func theManagedRefusalAtExitZeroIsNotBenign() {
        let refusal = Self.stderrResult("""
        Cannot unset configuration values: this Hermes installation is managed by nixos.
        Use your package manager to upgrade or reinstall Hermes.
        """, 0)
        #expect(BotAgentViewModel.isBenignUnset(refusal) == false)
    }

    /// The one failure that IS benign: the key was never pinned.
    /// `_exit_invalid(f"Config key not set: {key}")` — `config.py:3561`
    /// (`.env` arm) and `:3579` (config.yaml arm), both `sys.exit(1)`.
    @Test func anUnpinnedKeyIsStillBenign() {
        #expect(BotAgentViewModel.isBenignUnset(
            Self.stderrResult("Config key not set: model.default", 1)))
    }

    /// A real clear.
    @Test func aSuccessfulUnsetIsBenign() {
        #expect(BotAgentViewModel.isBenignUnset(
            Self.result("✓ Unset model.default from /tmp/config.yaml", 0)))
    }

    /// Every other refusal is reported — including the administrator-pinned
    /// key, which exits 1 with a DIFFERENT sentence than "not set".
    @Test func anAdministratorPinnedKeyIsReported() {
        #expect(BotAgentViewModel.isBenignUnset(Self.stderrResult(
            "Cannot unset 'model.default': it is managed by your administrator (/etc/hermes/config.yaml) and cannot be changed. Contact your administrator to modify it.",
            1)) == false)
    }
}

/// P39 fresh-eyes — the quick-commands sheet writes TWO keys, and picked which
/// one to blame with `exitCode != 0`.
///
/// That predicate is false for the refusal this whole phase is about, so a
/// `type` write refused at exit 0 read as "type is fine" and the banner named
/// `quick_commands.<name>.command` and quoted the OTHER spawn's output.
@Suite("P39 — the quick-commands failure attribution")
@MainActor
struct QuickCommandFailureAttributionP39Tests {

    private static let managedRefusal = """
    Cannot set configuration values: this Hermes installation is managed by nixos.
    Use your package manager to upgrade or reinstall Hermes.
    """

    @Test func anExitZeroRefusalOnTheTypeWriteNamesTheTypeKey() {
        let vm = QuickCommandsViewModel(context: .local)
        vm.applyAddOrUpdateResult(
            sanitizedName: "deploy",
            typeResult: (output: Self.managedRefusal, exitCode: 0),
            cmdResult: (output: "✓ Set quick_commands.deploy.command = ./go in /tmp/config.yaml",
                        exitCode: 0)
        )
        #expect(vm.messageIsFailure, "a refused quick-command save reported success")
        #expect(vm.message?.contains("quick_commands.deploy.type") == true,
                "blamed the wrong key: \(vm.message ?? "nil")")
        #expect(vm.message?.contains("managed by nixos") == true,
                "did not quote Hermes's own reason: \(vm.message ?? "nil")")
    }

    @Test func anExitZeroRefusalOnTheCommandWriteNamesTheCommandKey() {
        let vm = QuickCommandsViewModel(context: .local)
        vm.applyAddOrUpdateResult(
            sanitizedName: "deploy",
            typeResult: (output: "✓ Set quick_commands.deploy.type = exec in /tmp/config.yaml",
                         exitCode: 0),
            cmdResult: (output: Self.managedRefusal, exitCode: 0)
        )
        #expect(vm.messageIsFailure)
        #expect(vm.message?.contains("quick_commands.deploy.command") == true,
                "blamed the wrong key: \(vm.message ?? "nil")")
    }
}
