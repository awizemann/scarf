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
