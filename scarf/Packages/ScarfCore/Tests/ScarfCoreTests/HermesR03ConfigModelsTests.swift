import Foundation
import Testing
@testable import ScarfCore

/// Hermes v0.21.5 audit remediation, phase R03 (config & models).
/// Each suite names the finding it pins.

// MARK: - S05-F2: reasoning effort "none"

@Suite struct ReasoningEffortNoneR03Tests {
    let v0210 = HermesHost.v021
    let v0211 = HermesHost.v0211
    let v0215 = HermesHost.caps("Hermes Agent v0.21.5 (2026.9.24)")
    let v0180 = HermesHost.caps("Hermes Agent v0.18.0 (2026.7.1)")

    @Test func noneIsSentAsFalseWhereConfigSetWouldStoreNull() {
        // v0.21.1+: `config set agent.reasoning_effort none` stores YAML
        // null ("use the default"); `false` stores YAML False (disabled).
        for host in [v0211, v0215] {
            #expect(HermesReasoningEffort.configSetValue(for: "none", capabilities: host) == "false")
            #expect(HermesReasoningEffort.configSetValue(for: " None ", capabilities: host) == "false")
        }
    }

    @Test func noneIsSentVerbatimBelowTheCoercionFloor() {
        // Below v0.21.1 `none` is stored as the string and disables; and
        // pre-v0.18.1 `parse_reasoning_effort(False)` is "use the default",
        // so sending `false` there would be the bug in reverse.
        for host in [v0180, v0210, HermesHost.undetected] {
            #expect(HermesReasoningEffort.configSetValue(for: "none", capabilities: host) == "none")
        }
    }

    @Test func otherLevelsAreNeverRewritten() {
        for level in ["", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "disabled"] {
            #expect(HermesReasoningEffort.configSetValue(for: level, capabilities: v0215) == level)
        }
    }

    @Test func storedFalseShowsAsTheNoneRow() {
        // Round trip: what Scarf writes for "none" re-reads as `false`,
        // and the picker must land back on "none", not a widened row.
        let written = HermesReasoningEffort.configSetValue(for: "none", capabilities: v0215)
        let shown = HermesReasoningEffort.agentPickerSelection(for: written, capabilities: v0215)
        #expect(shown == "none")
        // "none" is a real row, so levels(selected:) widens nothing.
        let rows = HermesReasoningEffort.levels(capabilities: v0215, selected: shown)
        #expect(rows == HermesReasoningEffort.levels(capabilities: v0215))
        #expect(HermesReasoningEffort.unsupportedLevelNotice(for: written, capabilities: v0215) == nil)
        // The other disabling spellings are the same setting.
        #expect(HermesReasoningEffort.agentPickerSelection(for: "disabled", capabilities: v0215) == "none")
        #expect(HermesReasoningEffort.agentPickerSelection(for: "False", capabilities: v0215) == "none")
    }

    @Test func scarfReadsBackWhatHermesWrites() {
        // `hermes config set -- agent.reasoning_effort false` at v2026.9.24
        // writes `reasoning_effort: false` (verified against a scratch
        // HERMES_HOME; `none` writes an EMPTY scalar instead). Scarf's own
        // reader must surface that as the "none" row.
        let cfg = HermesConfig(yaml: "agent:\n  reasoning_effort: false\n")
        #expect(cfg.reasoningEffort == "false")
        #expect(HermesReasoningEffort.agentPickerSelection(for: cfg.reasoningEffort, capabilities: v0215) == "none")
        // The bug's end state: an empty scalar reads as "Hermes default".
        let broken = HermesConfig(yaml: "agent:\n  reasoning_effort:\n")
        #expect(HermesReasoningEffort.agentPickerSelection(for: broken.reasoningEffort, capabilities: v0215) == "")
    }

    @Test func pickerSelectionIsUnchangedForEverythingElse() {
        #expect(HermesReasoningEffort.agentPickerSelection(for: "", capabilities: v0215) == "")
        #expect(HermesReasoningEffort.agentPickerSelection(for: "  ", capabilities: v0215) == "")
        #expect(HermesReasoningEffort.agentPickerSelection(for: "high", capabilities: v0215) == "high")
        #expect(HermesReasoningEffort.agentPickerSelection(for: "none", capabilities: v0215) == "none")
        // Pre-v0.18.1 `false` does NOT disable, so it must not masquerade
        // as the "none" row there.
        #expect(HermesReasoningEffort.agentPickerSelection(for: "false", capabilities: v0180) == "false")
    }

    @Test func coercionFloorIsV0211() {
        #expect(!v0210.configSetCoercesNoneToNull)
        #expect(v0211.configSetCoercesNoneToNull)
        #expect(v0215.configSetCoercesNoneToNull)
        #expect(!HermesHost.undetected.configSetCoercesNoneToNull)
    }
}

// MARK: - S05-F1: auxiliary.session_search removed at v0.15.0

@Suite struct SessionSearchAuxR03Tests {
    @Test func rowExistsOnlyBeforeV015() {
        #expect(HermesHost.caps("Hermes Agent v0.14.0 (2026.5.16)").hasSessionSearchAux)
        #expect(HermesHost.caps("Hermes Agent v0.12.0 (2026.4.30)").hasSessionSearchAux)
        #expect(!HermesHost.caps("Hermes Agent v0.15.0 (2026.5.28)").hasSessionSearchAux)
        #expect(!HermesHost.caps("Hermes Agent v0.21.5 (2026.9.24)").hasSessionSearchAux)
    }

    @Test func unknownVersionHidesLikeItsSiblings() {
        #expect(!HermesHost.undetected.hasSessionSearchAux)
        #expect(!HermesHost.undetected.hasWebExtractAux)
    }
}
