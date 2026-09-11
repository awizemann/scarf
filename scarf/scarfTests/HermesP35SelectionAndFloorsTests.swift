import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P35 of the whole-surface audit — round-3 decision 8: when the platform
/// roster narrows after the detached read, snap the selection back so no
/// sub-floor form stays writable and no sub-floor `--platform` argv can be
/// shelled (charter C5).
@Suite("P35 — post-load selection reconciliation")
struct HermesP35SelectionAndFloorsTests {

    /// `scarf/` project directory, for the source scans below.
    private static var projectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: projectDir.appendingPathComponent(relative), encoding: .utf8)
    }

    /// A 0.14 host: below `ntfy`'s floor and below every other gated row's.
    private var v014: HermesCapabilities {
        HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.5.16)")
    }

    /// The pane the user can open in the pre-load window, and the narrowed
    /// roster the read produces a moment later.
    private var wideRoster: [HermesToolPlatform] {
        KnownPlatforms.visible(on: v014) { _ in true }   // "not looked yet"
    }
    private var narrowedRoster: [HermesToolPlatform] {
        KnownPlatforms.visible(on: v014) { _ in false }  // nothing configured
    }

    // MARK: - The seam

    @Test func theSeamSnapsOnlyAnAbsentSelection() {
        let ntfy = try! #require(wideRoster.first { $0.name == "ntfy" })
        #expect(narrowedRoster.contains { $0.name == "ntfy" } == false,
                "premise: the narrowed roster must no longer offer ntfy")

        #expect(KnownPlatforms.reconcile(selection: ntfy, against: narrowedRoster).name == "cli")
        // A selection the narrowed roster still carries is left alone — the
        // snap must not yank a user off a perfectly good pane.
        let telegram = try! #require(narrowedRoster.first { $0.name == "telegram" })
        #expect(KnownPlatforms.reconcile(selection: telegram, against: narrowedRoster).name == "telegram")
        #expect(KnownPlatforms.reconcile(selection: ntfy, against: wideRoster).name == "ntfy")
        // Empty roster (a paranoid caller): `cli`, never a crash.
        #expect(KnownPlatforms.reconcile(selection: ntfy, against: []).name == "cli")
    }

    // MARK: - Platforms

    /// Fails before the fix: `selected` keeps `ntfy`, whose detail pane is
    /// `NtfySetupView` and whose Save writes `platforms.ntfy.*` at a host
    /// with no ntfy adapter.
    @Test @MainActor func platformsSelectionSnapsBackWhenTheRosterNarrows() {
        let vm = PlatformsViewModel(context: .local)
        vm.selected = wideRoster.first { $0.name == "ntfy" }!
        vm.reconcileSelection(visible: narrowedRoster)
        #expect(vm.selected.name == "cli",
                "a sub-floor platform stayed selected (and writable) after the roster narrowed")

        // Control: a still-visible selection is untouched.
        vm.selected = narrowedRoster.first { $0.name == "telegram" }!
        vm.reconcileSelection(visible: narrowedRoster)
        #expect(vm.selected.name == "telegram")
    }

    // MARK: - Tools

    /// Fails before the fix: `selectedPlatform` keeps `ntfy`, and every
    /// toggle in the pane shells `hermes tools enable … --platform ntfy`.
    @Test @MainActor func toolsSelectionSnapsBackWhenTheRosterNarrows() async {
        let vm = ToolsViewModel(context: .local)
        vm.selectedPlatform = wideRoster.first { $0.name == "ntfy" }!
        await vm.reconcileSelection(visible: narrowedRoster)
        #expect(vm.selectedPlatform.name == "cli",
                "a sub-floor platform stayed selected, so toggleTool would still pass --platform ntfy")

        vm.selectedPlatform = narrowedRoster.first { $0.name == "telegram" }!
        await vm.reconcileSelection(visible: narrowedRoster)
        #expect(vm.selectedPlatform.name == "telegram")
    }

    // MARK: - The wiring

    /// Both reconcilers live in view models but are DRIVEN by the views,
    /// which own the capability environment and therefore the visible list.
    /// A green pair of unit tests above with no caller is exactly the P29
    /// "sentinel read without sentinel write" shape, so pin the call sites.
    @Test func bothViewsDriveTheReconcilerOffTheVisibleList() throws {
        for path in ["scarf/Features/Platforms/Views/PlatformsView.swift",
                     "scarf/Features/Tools/Views/ToolsView.swift"] {
            let src = try Self.source(path)
            #expect(src.contains("reconcileSelection(visible:"),
                    "\(path) never calls the reconciler")
            #expect(src.contains("onChange(of: visiblePlatforms.map(\\.name))"),
                    "\(path) does not re-reconcile when the visible roster changes")
        }
    }
}

/// P35 / round-3 decision 10 — the Mac "Host default" approvals row.
@Suite("P35 — the Host default approvals row")
@MainActor
struct HermesP35ApprovalsHostDefaultTests {

    /// Thread-safe fake `hermes`, in the shape P11 established.
    final class CLILog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
        let output: String
        let exitCode: Int32
        init(output: String = "✓ Unset approvals.mode from /tmp/config.yaml", exitCode: Int32 = 0) {
            self.output = output
            self.exitCode = exitCode
        }
        func runner() -> HermesCLIRunner {
            { [self] args, _ in
                lock.lock(); _calls.append(args); lock.unlock()
                return (output, exitCode)
            }
        }
    }

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p35-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    private static func viewModel(_ log: CLILog, storedMode: String?) -> SettingsViewModel {
        let vm = SettingsViewModel(context: scratchContext(), cliRunner: log.runner())
        vm.config = HermesConfig(yaml: storedMode.map { "approvals:\n  mode: \($0)\n" } ?? "agent:\n")
        return vm
    }

    /// Let the serialised write chain run. `expectingACall: false` cannot
    /// wait for evidence — the assertion is that nothing ran — so it settles
    /// for a fixed beat instead of burning the deadline.
    private static func settle(_ log: CLILog, expectingACall: Bool = true) async {
        if expectingACall {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, log.calls.isEmpty {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private var v0211: HermesCapabilities {
        HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    }
    private var v018: HermesCapabilities {
        HermesCapabilities.parseLine("Hermes Agent v0.18.2 (2026.7.7.2)")
    }

    /// Fails before the fix: the row was inert everywhere, so nothing ran.
    @Test func hostDefaultIssuesConfigUnsetOnAV019PlusHost() async {
        let log = CLILog()
        let vm = Self.viewModel(log, storedMode: "manual")
        #expect(vm.config.storedApprovalMode != nil, "premise: a mode is stored")

        vm.setApprovalMode("", capabilities: v0211)
        await Self.settle(log)

        #expect(log.calls == [["config", "unset", "approvals.mode"]])
        #expect(vm.messageIsFailure == false)
    }

    /// Below the `hasConfigUnset` floor the row shells nothing (C5) and says
    /// how to clear the key on the host.
    @Test func hostDefaultIsInertWithAHintBelowTheFloor() async {
        let log = CLILog()
        let vm = Self.viewModel(log, storedMode: "manual")

        vm.setApprovalMode("", capabilities: v018)
        await Self.settle(log, expectingACall: false)

        #expect(log.calls.isEmpty, "a v0.18 host was asked to run `config unset`")
        #expect(vm.messageIsFailure)
        #expect(vm.message?.contains("config unset") == true)
    }

    /// Nothing stored: nothing to clear, and no banner either.
    @Test func hostDefaultOverAnAbsentKeyIsAPlainNoOp() async {
        let log = CLILog()
        let vm = Self.viewModel(log, storedMode: nil)

        vm.setApprovalMode("", capabilities: v0211)
        await Self.settle(log, expectingACall: false)

        #expect(log.calls.isEmpty)
        #expect(vm.message == nil)
    }

    /// The exit-0 refusal (`is_managed()` prints and returns) must not be
    /// banner'd as a success. Fails if the write is judged by exit code.
    @Test func aManagedInstallRefusalAtExitZeroIsReportedAsAFailure() async {
        let log = CLILog(
            output: "Cannot unset configuration values: this Hermes installation is managed by NixOS.",
            exitCode: 0
        )
        let vm = Self.viewModel(log, storedMode: "manual")

        vm.setApprovalMode("", capabilities: v0211)
        await Self.settle(log)

        #expect(log.calls == [["config", "unset", "approvals.mode"]])
        #expect(vm.messageIsFailure, "an exit-0 refusal was reported as a successful clear")
        #expect(vm.message?.contains("managed by NixOS") == true)
    }

    /// An explicit mode still goes through `config set`, unchanged.
    @Test func anExplicitModeStillWrites() async {
        let log = CLILog(output: "")
        let vm = Self.viewModel(log, storedMode: nil)

        vm.setApprovalMode("smart", capabilities: v0211)
        await Self.settle(log)

        #expect(log.calls == [["config", "set", "approvals.mode", "smart"]])
    }
}
