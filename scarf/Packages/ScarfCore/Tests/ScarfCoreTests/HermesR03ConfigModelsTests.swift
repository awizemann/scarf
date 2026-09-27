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

// MARK: - S06-F3: named-profile auth.json falls back to the root per provider

@Suite struct HermesAuthFallbackR03Tests {
    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func object(_ data: Data?) -> [String: Any] {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    let root: [String: Any] = [
        "active_provider": "nous",
        "providers": ["nous": ["access_token": "root-token"]],
        "credential_pool": [
            "openrouter": [["id": "r1", "access_token": "sk-root"]],
            "anthropic": [["id": "r2", "access_token": "sk-ant-root"]],
            "empty": [] as [Any],
        ],
    ]

    @Test func rootFillsOnlyProvidersTheProfileLacks() {
        let profile: [String: Any] = [
            "credential_pool": ["anthropic": [["id": "p1", "access_token": "sk-ant-profile"]]],
        ]
        let merged = HermesAuthFallback.merge(
            profile: json(profile), root: json(root), includeProviderState: true)
        let out = object(merged.data)
        let pool = out["credential_pool"] as? [String: [[String: Any]]]
        // Profile wins where it has ANY entries.
        #expect(pool?["anthropic"]?.first?["id"] as? String == "p1")
        // Root fills the gap.
        #expect(pool?["openrouter"]?.first?["id"] as? String == "r1")
        // An empty root list is not inherited.
        #expect(pool?["empty"] == nil)
        #expect(merged.inheritedPools == ["openrouter"])
        // providers.nous comes from the root.
        let providers = out["providers"] as? [String: [String: Any]]
        #expect(providers?["nous"]?["access_token"] as? String == "root-token")
        #expect(merged.inheritedProviders == ["nous"])
        // active_provider is the profile's own (none) — never merged.
        #expect(out["active_provider"] == nil)
    }

    @Test func anEmptyProfileListStillInherits() {
        // `[]` is "zero entries" to Hermes, so the root list applies.
        let profile: [String: Any] = ["credential_pool": ["openrouter": [] as [Any]]]
        let merged = HermesAuthFallback.merge(
            profile: json(profile), root: json(root), includeProviderState: false)
        #expect(merged.inheritedPools.contains("openrouter"))
    }

    @Test func providerStateFallbackHasItsOwnFloor() {
        let merged = HermesAuthFallback.merge(profile: nil, root: json(root), includeProviderState: false)
        #expect(merged.inheritedProviders.isEmpty)
        #expect((object(merged.data)["providers"] as? [String: Any]) == nil)
        #expect(merged.inheritedPools == ["openrouter", "anthropic"])
    }

    @Test func noRootLeavesTheProfileBytesAlone() {
        let profile = json(["credential_pool": ["x": [["id": "1"]]]])
        let merged = HermesAuthFallback.merge(profile: profile, root: nil, includeProviderState: true)
        #expect(merged.data == profile)
        #expect(merged.inheritedPools.isEmpty && merged.inheritedProviders.isEmpty)
        // An unparseable root is the same as none.
        let bad = HermesAuthFallback.merge(profile: profile, root: Data("{nope".utf8), includeProviderState: true)
        #expect(bad.data == profile)
    }

    @Test func rootPathOnlyForNamedProfilesOnAFallbackHost() {
        let host = HermesHost.caps("Hermes Agent v0.21.5 (2026.9.24)")
        #expect(HermesAuthFallback.rootAuthJSONPath(forHome: "/Users/a/.hermes/profiles/work", capabilities: host)
                == "/Users/a/.hermes/auth.json")
        #expect(HermesAuthFallback.rootAuthJSONPath(forHome: "~/.hermes/profiles/work", capabilities: host)
                == "~/.hermes/auth.json")
        #expect(HermesAuthFallback.rootAuthJSONPath(forHome: "/Users/a/.hermes", capabilities: host) == nil)
        #expect(HermesAuthFallback.rootAuthJSONPath(
            forHome: "/Users/a/.hermes/profiles/work", capabilities: .empty) == nil)
        #expect(HermesAuthFallback.rootAuthJSONPath(
            forHome: "/Users/a/.hermes/profiles/work",
            capabilities: HermesHost.caps("Hermes Agent v0.12.0 (2026.4.30)")) == nil)
    }

    @Test func floors() {
        #expect(!HermesHost.caps("Hermes Agent v0.12.0 (2026.4.30)").hasProfileAuthPoolFallback)
        #expect(HermesHost.caps("Hermes Agent v0.13.0 (2026.5.7)").hasProfileAuthPoolFallback)
        #expect(!HermesHost.caps("Hermes Agent v0.14.0 (2026.5.16)").hasProfileAuthProviderStateFallback)
        #expect(HermesHost.caps("Hermes Agent v0.15.0 (2026.5.28)").hasProfileAuthProviderStateFallback)
    }

    @Test func loadReadsBothFilesThroughTheTransport() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("r03-auth-\(UUID().uuidString)")
        let profileHome = base.appendingPathComponent("profiles/work")
        try FileManager.default.createDirectory(at: profileHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try json(root).write(to: base.appendingPathComponent("auth.json"))

        let host = HermesHost.caps("Hermes Agent v0.21.5 (2026.9.24)")
        // Profile has no auth.json at all: everything comes from the root.
        let merged = HermesAuthFallback.load(
            authJSONPath: profileHome.path + "/auth.json",
            home: profileHome.path,
            capabilities: host,
            transport: LocalTransport())
        #expect(merged.inheritedProviders == ["nous"])
        #expect(merged.inheritedPools == ["openrouter", "anthropic"])

        // Default-profile home: only its own file, unchanged.
        let own = HermesAuthFallback.load(
            authJSONPath: base.path + "/auth.json", home: base.path,
            capabilities: host, transport: LocalTransport())
        #expect(own.inheritedPools.isEmpty)
        #expect(own.data == (try Data(contentsOf: base.appendingPathComponent("auth.json"))))
    }
}

// MARK: - S06-F5: Nous catalog filter + fallback

@Suite struct NousCatalogR03Tests {
    @Test func hermesModelsAreDroppedLikeHermesDoes() {
        let raw = [
            NousModel(id: "Hermes-3-Llama-3.1-405B"),
            NousModel(id: "anthropic/claude-opus-5.5"),
            NousModel(id: "nousresearch/hermes-4-70b"),
            NousModel(id: " openai/gpt-6-astra "),
            NousModel(id: "anthropic/claude-opus-5.5"),
            NousModel(id: "  "),
        ]
        let ids = NousModelCatalogService.agenticModels(raw).map(\.id)
        #expect(ids == ["anthropic/claude-opus-5.5", "openai/gpt-6-astra"])
    }

    @Test func fallbackIsVendorPrefixedAndSurvivesTheFilter() {
        let fallback = NousModelCatalogService.fallbackModels
        #expect(!fallback.isEmpty)
        #expect(NousModelCatalogService.agenticModels(fallback) == fallback)
        #expect(fallback.allSatisfy { $0.id.contains("/") })
        // Hermes's catalog default is offered.
        #expect(fallback.contains { $0.id == "z-ai/glm-5.2" })
        // Nous is an aggregator, so none of these can raise the
        // model/provider mismatch banner (S06-F1).
        for model in fallback {
            var cfg = HermesConfig.empty
            cfg.model = model.id
            cfg.provider = "nous"
            #expect(ModelPreflight.detectMismatch(cfg) == nil, "\(model.id)")
        }
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

    @Test func eachAdditionArrivesAtItsFloor() throws {
        let v0211 = ids(HermesHost.v0211)
        #expect(v0211.contains("muse-image-1.0"))
        #expect(!v0211.contains("openai/gpt-image-2.5/flare/text-to-image"))

        let v0212 = ids(HermesHost.caps("Hermes Agent v0.21.2 (2026.9.11)"))
        let gpt2 = try #require(v0212.firstIndex(of: "fal-ai/gpt-image-2"))
        #expect(v0212[gpt2 + 1] == "openai/gpt-image-2.5/flare/text-to-image")
        #expect(v0212[gpt2 + 2] == "openai/gpt-image-2.5/sunburst/text-to-image")
        #expect(!v0212.contains("fal-ai/kling-image/v3/text-to-image"))

        let v0215 = ids(HermesHost.caps("Hermes Agent v0.21.5 (2026.9.24)"))
        let grok = try #require(v0215.firstIndex(of: "xai/grok-imagine-image/v2.0/text-to-image"))
        #expect(v0215[grok + 1] == "fal-ai/kling-image/v3/text-to-image")
        #expect(v0215[grok + 2] == "meta/muse-image/text-to-image")
        #expect(v0215.count == Set(v0215).count, "no duplicate rows")
        #expect(v0215.count == ModelCatalogService.imageGenModels.count + 5)
    }
}
