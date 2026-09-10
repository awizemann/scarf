import Testing
import Foundation
import ScarfCore
@testable import scarf_mobile

/// P28 / finding H2 — the iOS quick-edit sheet defeated P20's `approvals.mode`
/// absence sentinel.
///
/// P20 made the iOS READ sentinel-aware (an absent key reports `""`) and left a
/// comment claiming the sheet "then offers the modes without pre-selecting
/// one". It did the opposite: priming pre-selected `options.first` for an empty
/// value and `hasValidValue` was unconditionally true for a picker, so opening
/// the sheet on a stock v0.19+ host that runs `smart` and tapping Save wrote
/// `approvals.mode: manual`. The option set was `["manual", "auto", "yolo"]`
/// besides, so `smart`/`off` could not be selected at all while `auto`/`yolo`
/// — never members at any tag — could be written.
@Suite struct SettingsEditorSentinelP28Tests {

    private func spec(_ key: String) -> SettingSpec {
        SettingSpec.v1Editable.first { $0.key == key }!
    }

    private func picker(_ kind: SettingSpec.Kind) -> (options: [String], labels: [String: String]) {
        guard case .enumPicker(let options, let labels) = kind else {
            Issue.record("\(kind) is not an enum picker")
            return ([], [:])
        }
        return (options, labels)
    }

    private func caps(_ line: String) -> HermesCapabilities { HermesCapabilities.parseLine(line) }

    /// The option set is Hermes's own `_VALID_MODES`
    /// (`tools/approval_context.py:197` @ v2026.9.7), taken from the shared
    /// model so the two platforms cannot drift. Fails on the old
    /// `["manual", "auto", "yolo"]` literal.
    @Test func theModeOptionsAreHermesOwnValidModes() {
        let (options, _) = picker(spec("approvals.mode").kind)
        #expect(options == HermesApprovalMode.options)
        #expect(options == ["manual", "smart", "off"])
        #expect(!options.contains("auto"), "`auto` has never been an approvals.mode member")
        #expect(!options.contains("yolo"))
    }

    /// `resolved(capabilities:)` prepends the ABSENT-key sentinel and labels it
    /// with the mode the connected host would actually run — the same row the
    /// Mac picker carries (`AgentTab.swift`). Fails without the new
    /// `approvals.mode` arm: there is no row an absent key can select.
    @Test func theResolvedSpecCarriesAHostDefaultSentinelRow() {
        let v0211 = picker(spec("approvals.mode").resolved(capabilities: caps("Hermes Agent v0.21.1 (2026.9.7)")).kind)
        #expect(v0211.options.first == "", "there is no row for an absent key")
        #expect(v0211.options == [""] + HermesApprovalMode.options)
        #expect(v0211.labels[""] == "Host default (smart)")

        // Below v0.19 an absent key really does mean `manual`; an undetected
        // host (failed probe) says it does not know.
        #expect(picker(spec("approvals.mode").resolved(capabilities: caps("Hermes Agent v0.18.1 (2026.7.7)")).kind)
            .labels[""] == "Host default (manual)")
        #expect(picker(spec("approvals.mode").resolved(capabilities: caps("nonsense")).kind)
            .labels[""] == "Host default (unknown)")
    }

    /// The rule the finding turns on: an ABSENT value must not prime a
    /// concrete option. `primedScalar` is the sheet's own priming function —
    /// `primeFromCurrent` sets the control from it and Save refuses to write a
    /// value still equal to it — so this pins the no-pin guarantee.
    ///
    /// Fails both ways on the old code: with `options.first` priming it
    /// returns `manual` for an absent key.
    @Test func anAbsentModePrimesTheSentinelAndNotAMode() {
        let resolved = spec("approvals.mode").resolved(capabilities: caps("Hermes Agent v0.21.1 (2026.9.7)"))
        #expect(resolved.kind.primedScalar(currentValue: "") == "",
                "an absent approvals.mode primed a concrete mode, which Save would then pin")
        // A stored mode still primes itself, including the two the old option
        // set could not represent.
        for mode in HermesApprovalMode.options {
            #expect(resolved.kind.primedScalar(currentValue: mode) == mode)
        }
    }

    /// `agent.max_turns` reports the RESOLVED host default ("Unlimited" on
    /// v0.20.5+, else 500/60), so the same rule has to hold there: priming maps
    /// it onto the 0 sentinel and an untouched Save writes nothing. Fails if
    /// priming ever produced a number the user did not type.
    @Test func theResolvedMaxTurnsDefaultIsNotPinnedByOpeningTheSheet() {
        let resolved = spec("agent.max_turns").resolved(capabilities: caps("Hermes Agent v0.21.1 (2026.9.7)"))
        #expect(resolved.kind.primedScalar(currentValue: "Unlimited") == "0")
        #expect(resolved.kind.primedScalar(currentValue: "500") == "500")
        // The 0 row only exists where Hermes can resolve it.
        guard case .number(let range, _) = resolved.kind else { Issue.record("not a stepper"); return }
        #expect(range.lowerBound == 0)
        guard case .number(let preRange, _) = spec("agent.max_turns")
            .resolved(capabilities: caps("Hermes Agent v0.20.4 (2026.8.18)")).kind
        else { Issue.record("not a stepper"); return }
        #expect(preRange.lowerBound == 1, "a pre-0.20.5 host has no unlimited semantics")
    }

    /// Every other kind still primes exactly what it used to — the guard must
    /// not change what a stored value does.
    @Test func theOtherKindsPrimeUnchanged() {
        #expect(spec("display.show_cost").kind.primedScalar(currentValue: "true") == "true")
        #expect(spec("display.show_cost").kind.primedScalar(currentValue: "yes") == "true")
        #expect(spec("display.show_cost").kind.primedScalar(currentValue: "") == "false")
        #expect(spec("model.default").kind.primedScalar(currentValue: "kimi-k2") == "kimi-k2")
    }
}
