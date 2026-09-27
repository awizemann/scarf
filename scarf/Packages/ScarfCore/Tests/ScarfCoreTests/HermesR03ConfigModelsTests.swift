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

// MARK: - S06-F2: llama.cpp writes `custom` where Hermes ignores base_url

@Suite struct LlamaCppProviderR03Tests {
    let selection = LocalModelSelection(
        providerID: "llamacpp", modelID: "qwen3", baseURL: "http://192.168.1.20:8081/v1")

    private func provider(_ ops: [LocalModelConfigPlan.Operation]) -> String? {
        for case let .set(key, value) in ops where key == "model.provider" { return value }
        return nil
    }

    private func baseURL(_ ops: [LocalModelConfigPlan.Operation]) -> String? {
        for case let .set(key, value) in ops where key == "model.base_url" { return value }
        return nil
    }

    @Test func writesCustomOnV0211AndLater() {
        for host in [HermesHost.v0211, HermesHost.caps("Hermes Agent v0.21.5 (2026.9.24)")] {
            let ops = LocalModelConfigPlan.operations(selecting: selection, capabilities: host)
            #expect(provider(ops) == "custom")
            #expect(baseURL(ops) == "http://192.168.1.20:8081/v1")
            // Provider still commits LAST (crash-safe ordering).
            #expect(ops.last == .set(key: "model.provider", value: "custom"))
        }
    }

    @Test func olderAndUndetectedHostsKeepWritingLlamacpp() {
        for host in [HermesHost.v021, HermesHost.undetected] {
            let ops = LocalModelConfigPlan.operations(selecting: selection, capabilities: host)
            #expect(provider(ops) == "llamacpp")
        }
        // The default argument is the undetected host.
        #expect(provider(LocalModelConfigPlan.operations(selecting: selection)) == "llamacpp")
    }

    @Test func spellingAliasesResolveTheSameWay() {
        for spelling in ["llama.cpp", "llama-cpp", "LlamaCpp"] {
            let ops = LocalModelConfigPlan.operations(
                selecting: LocalModelSelection(providerID: spelling, modelID: "m", baseURL: "http://127.0.0.1:8080/v1"),
                capabilities: HermesHost.v0211)
            #expect(provider(ops) == "custom", "\(spelling)")
        }
    }

    @Test func otherLocalRowsAreUntouched() {
        for id in ["ollama", "lmstudio", "vllm", "custom"] {
            let ops = LocalModelConfigPlan.operations(
                selecting: LocalModelSelection(providerID: id, modelID: "m", baseURL: "http://127.0.0.1:9000/v1"),
                capabilities: HermesHost.v0211)
            #expect(provider(ops) == id)
        }
    }

    @Test func bannerAlignToLlamacppFollowsTheSameRule() {
        // The remote path delegates a switch-to-local to the local plan.
        var cfg = HermesConfig.empty
        cfg.provider = "openrouter"
        cfg.modelBaseURL = "http://127.0.0.1:8080/v1"
        let ops = LocalModelConfigPlan.operations(
            selectingRemoteModel: "qwen3", provider: "llamacpp", current: cfg,
            capabilities: HermesHost.v0211)
        #expect(provider(ops) == "custom")
    }
}

// MARK: - S06-F7: image-gen picker rows per host

@Suite struct ImageGenModelsR03Tests {
    private func ids(_ caps: HermesCapabilities) -> [String] {
        ModelCatalogService.imageGenModels(capabilities: caps).map(\.modelID)
    }

    @Test func undetectedAndOlderHostsGetTheUnchangedList() {
        let base = ModelCatalogService.imageGenModels.map(\.modelID)
        #expect(ids(.empty) == base)
        #expect(ids(HermesHost.v021) == base)
    }

    @Test func eachAdditionArrivesAtItsFloor() {
        let v0211 = ids(HermesHost.v0211)
        #expect(v0211.contains("muse-image-1.0"))
        #expect(!v0211.contains("openai/gpt-image-2.5/flare/text-to-image"))

        let v0212 = ids(HermesHost.caps("Hermes Agent v0.21.2 (2026.9.11)"))
        let gpt2 = try! #require(v0212.firstIndex(of: "fal-ai/gpt-image-2"))
        #expect(v0212[gpt2 + 1] == "openai/gpt-image-2.5/flare/text-to-image")
        #expect(v0212[gpt2 + 2] == "openai/gpt-image-2.5/sunburst/text-to-image")
        #expect(!v0212.contains("fal-ai/kling-image/v3/text-to-image"))

        let v0215 = ids(HermesHost.caps("Hermes Agent v0.21.5 (2026.9.24)"))
        let grok = try! #require(v0215.firstIndex(of: "xai/grok-imagine-image/v2.0/text-to-image"))
        #expect(v0215[grok + 1] == "fal-ai/kling-image/v3/text-to-image")
        #expect(v0215[grok + 2] == "meta/muse-image/text-to-image")
        #expect(v0215.count == Set(v0215).count, "no duplicate rows")
        #expect(v0215.count == ModelCatalogService.imageGenModels.count + 5)
    }
}
