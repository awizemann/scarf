import Testing
import Foundation
import ScarfCore
@testable import scarf_mobile

/// P35 / round-3 decision 10 — the iOS host-default row is wired to
/// `hermes config unset` behind `hasConfigUnset`, without regressing P29's
/// rule that it must NEVER write an empty scalar.
@Suite struct SettingsEditorClearP35Tests {

    private func spec(_ key: String) -> SettingSpec {
        SettingSpec.v1Editable.first { $0.key == key }!
    }
    private func caps(_ line: String) -> HermesCapabilities { HermesCapabilities.parseLine(line) }
    private var v0211: HermesCapabilities { caps("Hermes Agent v0.21.1 (2026.9.7)") }
    private var v018: HermesCapabilities { caps("Hermes Agent v0.18.2 (2026.7.7.2)") }

    private var approvalsKind: SettingSpec.Kind {
        spec("approvals.mode").resolved(capabilities: v0211).kind
    }

    /// Fails before the fix: `clearAction` did not exist and the row did
    /// nothing at all over a stored mode.
    @Test func theSentinelRowOverAStoredModeUnsetsOnAV019PlusHost() {
        for stored in HermesApprovalMode.options {
            #expect(
                SettingEditorSheet.clearAction(
                    kind: approvalsKind, stringValue: "", primedValue: stored,
                    capabilities: v0211
                ) == .unset,
                "selecting Host default over a stored `\(stored)` did not clear the key"
            )
        }
    }

    /// Below the floor the row is inert and explains itself — Scarf never
    /// shells `config unset` at a host that has no such verb (C5).
    @Test func theSentinelRowIsInertWithAHintBelowTheFloor() {
        #expect(
            SettingEditorSheet.clearAction(
                kind: approvalsKind, stringValue: "", primedValue: "manual",
                capabilities: v018
            ) == .belowFloor
        )
        // An UNDETECTED host is treated as below the floor, not above it.
        #expect(
            SettingEditorSheet.clearAction(
                kind: approvalsKind, stringValue: "", primedValue: "manual",
                capabilities: .empty
            ) == .belowFloor
        )
        #expect(HermesConfigUnset.belowFloorHint(key: "approvals.mode").contains("config unset"))
    }

    /// Nothing to clear, and nothing that is a clear gesture at all.
    @Test func everythingElseIsNotAClearGesture() {
        // Untouched sheet on an ABSENT key: no stored value, nothing to unset.
        #expect(SettingEditorSheet.clearAction(
            kind: approvalsKind, stringValue: "", primedValue: "", capabilities: v0211) == nil)
        #expect(SettingEditorSheet.clearAction(
            kind: approvalsKind, stringValue: "", primedValue: nil, capabilities: v0211) == nil)
        // A real mode selection is a write, not a clear.
        #expect(SettingEditorSheet.clearAction(
            kind: approvalsKind, stringValue: "smart", primedValue: "manual", capabilities: v0211) == nil)
        // A picker with no sentinel row, and the other kinds, are untouched —
        // `approvals.smart_policy`'s empty scalar IS Hermes's own default and
        // clearing it must stay a plain `config set`.
        #expect(SettingEditorSheet.clearAction(
            kind: .enumPicker(options: ["manual", "smart", "off"]),
            stringValue: "", primedValue: "manual", capabilities: v0211) == nil)
        #expect(SettingEditorSheet.clearAction(
            kind: .text, stringValue: "", primedValue: "be careful", capabilities: v0211) == nil)
        #expect(SettingEditorSheet.clearAction(
            kind: .toggle, stringValue: "false", primedValue: "true", capabilities: v0211) == nil)
    }

    /// P29's rule, restated at the new seam: the sentinel row still writes NO
    /// scalar. `clearAction` is an alternative to `valueToWrite`, not a way
    /// around it.
    @Test func theSentinelRowStillWritesNoScalar() {
        for stored in HermesApprovalMode.options + [""] {
            #expect(SettingEditorSheet.valueToWrite(
                kind: approvalsKind, stringValue: "", primedValue: stored) == nil)
        }
    }

    /// `save()` has exactly ONE `vm.unsetValue` call and it is inside the
    /// `clearAction` branch, which `return`s — so the clear path can never
    /// fall through into the write path, and a second clear site cannot
    /// appear silently (the P29 lesson).
    @Test func saveHasOneUnsetAndItIsBehindTheClearBranch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Scarf iOSTests
            .deletingLastPathComponent()          // scarf
            .appendingPathComponent("Scarf iOS/Settings/SettingEditorSheet.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.components(separatedBy: "vm.unsetValue(").count - 1 == 1)
        guard let branch = source.range(of: "if let clear = Self.clearAction("),
              let unset = source.range(of: "try await vm.unsetValue("),
              let write = source.range(of: "guard let value = Self.valueToWrite(")
        else {
            Issue.record("the sheet no longer routes the clear gesture through `clearAction`")
            return
        }
        #expect(branch.upperBound < unset.lowerBound)
        #expect(unset.upperBound < write.lowerBound, "the clear branch must precede (and return before) the write path")
    }
}
