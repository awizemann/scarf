import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P38 item 9 — the "nothing stored → no-op" guard existed only in
/// `setApprovalMode`. The other six clear rows shelled `hermes config unset`
/// unconditionally, and `unset_config_value` prints `Config key not set:
/// <key>` for an absent key — which `HermesConfigUnset.judge` correctly reads
/// as a failure, so the user got a red "Couldn't clear" for a button that had
/// nothing to do. The guard now sits in `unsetSetting` beside the floor gate,
/// with `isStored` a REQUIRED argument for the same reason `capabilities` is.
@Suite("P38 — a clear with nothing to clear runs nothing")
@MainActor
struct HermesP38ClearRowNoOpTests {

    private typealias CLILog = HermesP35ApprovalsHostDefaultTests.CLILog

    private static func viewModel(_ log: CLILog) -> SettingsViewModel {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p38-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return SettingsViewModel(context: .local(home: home), cliRunner: log.runner())
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

    private var v0211: HermesCapabilities {
        HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    }

    /// Every clear row, on a config where the key is ABSENT. Nothing should
    /// reach the CLI and no banner should appear — the row is already in the
    /// state the click asks for.
    @Test func anAbsentKeyIsNeverSentToTheCLI() async {
        for (key, _, act) in HermesP37ConfigUnsetFloorTests.clearRows {
            let log = CLILog(output: "Config key not set: \(key)", exitCode: 1)
            let vm = Self.viewModel(log)
            // NOTE: no `stored(vm)` — the key is absent.
            if key == "auxiliary.compression.max_concurrency" { continue }
            act(vm, v0211)
            await Self.settle(vm, log, expectingACall: false)
            #expect(log.calls.isEmpty, "\(key): cleared a key that was never set")
            #expect(vm.message == nil, "\(key): a no-op posted a banner")
        }
    }

    /// The aux row's stored value is passed by the view (there is no keyed
    /// accessor on `AuxiliarySettings`), so it gets its own case.
    @Test func theAuxiliaryRowRespectsItsStoredArgument() async {
        let absent = CLILog(output: "Config key not set: auxiliary.compression.max_concurrency",
                            exitCode: 1)
        let vmAbsent = Self.viewModel(absent)
        vmAbsent.setAuxiliaryMaxConcurrency("compression", value: nil, stored: nil,
                                           capabilities: v0211)
        await Self.settle(vmAbsent, absent, expectingACall: false)
        #expect(absent.calls.isEmpty)
        #expect(vmAbsent.message == nil)

        let present = CLILog(output: "")
        let vmPresent = Self.viewModel(present)
        vmPresent.setAuxiliaryMaxConcurrency("compression", value: nil, stored: 4,
                                            capabilities: v0211)
        await Self.settle(vmPresent, present)
        #expect(present.calls == [["config", "unset", "--", "auxiliary.compression.max_concurrency"]])
    }

    /// The guard must not swallow a real clear.
    @Test func aStoredKeyIsStillCleared() async {
        for (key, stored, act) in HermesP37ConfigUnsetFloorTests.clearRows
        where key != "auxiliary.compression.max_concurrency" {
            let log = CLILog(output: "")
            let vm = Self.viewModel(log)
            stored(vm)
            act(vm, v0211)
            await Self.settle(vm, log)
            #expect(log.calls == [["config", "unset", "--", key]], "\(key): the real clear was swallowed")
        }
    }
}

/// P38 item 10 — `BotDraft.controlCharacterFieldLabel` covered five fields
/// and omitted `group` / `groups`, which the writer also emits through
/// `YAMLScalar.quoteIfNeeded` (`HermesBotProfileYAML.swift:437`, `:441`). A
/// control character already in either one is carried through every save, and
/// `read_profile_meta` turns the unloadable result into empty defaults — the
/// bot drops out of the roster (`hermes_cli/profiles.py:471-480`, `:609-618`
/// @ `v2026.9.7`).
@Suite("P38 — the control-character refusal covers the carried group keys")
@MainActor
struct HermesP38BotGroupControlCharacterTests {

    private static func identity(
        legacyGroup: String? = nil,
        groups: [String] = []
    ) -> HermesBotIdentity {
        var id = HermesBotIdentity(profileName: "research", profileDirectory: "/tmp/research")
        id.legacyGroup = legacyGroup
        id.groups = groups
        return id
    }

    @Test func aControlCharacterInTheLegacyGroupScalarIsRefused() {
        let draft = BotDraft(identity: Self.identity(legacyGroup: "team\u{0007}a"))
        #expect(draft.controlCharacterFieldLabel == "Group")
    }

    @Test func aControlCharacterInAnyGroupsItemIsRefused() {
        let draft = BotDraft(identity: Self.identity(groups: ["ok", "bad\u{0001}"]))
        #expect(draft.controlCharacterFieldLabel == "Groups")
    }

    @Test func cleanGroupKeysAreAccepted() {
        let draft = BotDraft(identity: Self.identity(legacyGroup: "team", groups: ["a", "b"]))
        #expect(draft.controlCharacterFieldLabel == nil)
    }

    /// A tab is a control character in YAML's sense too, and Hermes's own
    /// writer would emit it — the editor refuses rather than corrupt.
    @Test func aTabInAGroupIsRefused() {
        let draft = BotDraft(identity: Self.identity(groups: ["a\tb"]))
        #expect(draft.controlCharacterFieldLabel == "Groups")
    }
}
