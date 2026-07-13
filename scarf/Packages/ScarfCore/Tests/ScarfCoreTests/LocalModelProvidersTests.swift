import Testing
import Foundation
@testable import ScarfCore

/// Pins the T0 design contract for the model picker's "Local" section —
/// the exact `model.provider` strings and required-key flags that the
/// Hermes v0.17.0 runtime reader (runtime_provider.py + auth.py) needs
/// for a working local chat. These aren't checkbox tests: a regression
/// here (a descriptor writing `local`, or Ollama losing its required
/// base_url) breaks local chat *silently* — the failure mode is a quiet
/// fall-through to OpenRouter or a request-time "Unknown provider", not
/// a save-time error.
@Suite struct LocalModelProvidersTests {

    // MARK: - Provider IDs and ordering

    @Test func tablePinsExactProviderIDsInStableOrder() {
        // Order is a deliberate UX decision (most-common-first, custom
        // last) that T3 renders verbatim — pinned, not just membership.
        #expect(LocalModelProvider.all.map(\.providerID) == [
            "ollama", "lmstudio", "vllm", "llamacpp", "custom",
        ])
    }

    @Test func providerIDLocalIsNeverUsed() {
        // "local" is a catalog-side alias target only. At request time
        // resolve_provider("local") raises "Unknown provider" — the
        // runtime alias table maps vllm/llamacpp to "custom", never
        // "local" (auth.py:1560-1564).
        #expect(!LocalModelProvider.all.contains { $0.providerID == "local" })
        #expect(LocalModelProvider.descriptor(for: "local") == nil)
    }

    @Test func providerIDsAreUnique() {
        let ids = LocalModelProvider.all.map(\.providerID)
        #expect(Set(ids).count == ids.count)
    }

    @Test func descriptorLookupIsCaseAndWhitespaceInsensitive() {
        #expect(LocalModelProvider.descriptor(for: " Ollama ")?.providerID == "ollama")
        #expect(LocalModelProvider.descriptor(for: "LMSTUDIO")?.providerID == "lmstudio")
        #expect(LocalModelProvider.descriptor(for: "not-a-local-provider") == nil)
    }

    @Test func descriptorLookupHonorsTheRuntimeSpellingAliases() {
        // auth.py:1560-1564 accepts these spellings in config.yaml — a
        // CLI-written `model.provider: llama.cpp` is a working local setup
        // and the UI must classify it as one, not as an unknown provider.
        #expect(LocalModelProvider.descriptor(for: "lm-studio")?.providerID == "lmstudio")
        #expect(LocalModelProvider.descriptor(for: "lm_studio")?.providerID == "lmstudio")
        #expect(LocalModelProvider.descriptor(for: "llama.cpp")?.providerID == "llamacpp")
        #expect(LocalModelProvider.descriptor(for: "llama-cpp")?.providerID == "llamacpp")
        // But not the runtime's non-local aliases sharing the prefix.
        #expect(LocalModelProvider.descriptor(for: "ollama_cloud") == nil)
        #expect(LocalModelProvider.descriptor(for: "ollama-cloud") == nil)
    }

    // MARK: - base_url contract

    @Test func ollamaAlwaysWritesBaseURLWithTheV1Default() {
        // Hermes has NO built-in Ollama URL and never reads OLLAMA_HOST.
        // Without model.base_url a bare-ollama chat silently falls
        // through to OpenRouter (runtime_provider.py:970-976) — so the
        // descriptor must both require the key and carry the default the
        // UI writes unprompted.
        let ollama = LocalModelProvider.descriptor(for: "ollama")
        #expect(ollama?.baseURLRequired == true)
        #expect(ollama?.defaultBaseURL == "http://127.0.0.1:11434/v1")
    }

    @Test func vllmAndLlamacppRequireBaseURLWithNoDefault() {
        // Runtime-aliased to custom; no assumed endpoint of their own.
        // A defaultBaseURL here would invent a runtime behavior that
        // doesn't exist — the user must supply the URL.
        for id in ["vllm", "llamacpp"] {
            let p = LocalModelProvider.descriptor(for: id)
            #expect(p?.baseURLRequired == true)
            #expect(p?.defaultBaseURL == nil)
        }
    }

    @Test func lmstudioBaseURLIsOptionalWithTheRegistryDefault() {
        // PROVIDER_REGISTRY["lmstudio"] ships the 127.0.0.1:1234/v1
        // default and the LM_BASE_URL env override — the only local
        // provider that works with zero config keys beyond the model.
        let lm = LocalModelProvider.descriptor(for: "lmstudio")
        #expect(lm?.baseURLRequired == false)
        #expect(lm?.defaultBaseURL == "http://127.0.0.1:1234/v1")
    }

    @Test func customRequiresBaseURL() {
        #expect(LocalModelProvider.descriptor(for: "custom")?.baseURLRequired == true)
    }

    @Test func everyDescriptorCarriesABaseURLPlaceholder() {
        for p in LocalModelProvider.all {
            #expect(!p.baseURLPlaceholder.isEmpty, "placeholder missing for \(p.providerID)")
        }
    }

    // MARK: - API key contract

    @Test func onlyCustomSupportsAnAPIKey() {
        // The runtime substitutes "no-key-required" (LM Studio:
        // "dummy-lm-api-key") on its own — writing model.api_key for the
        // named local providers is at best noise. Only the custom
        // endpoint accepts an optional inline key.
        for p in LocalModelProvider.all {
            #expect(p.supportsAPIKey == (p.providerID == "custom"),
                    "supportsAPIKey wrong for \(p.providerID)")
        }
    }

    @Test func everyDescriptorExplainsTheNoKeyStory() {
        for p in LocalModelProvider.all {
            #expect(!p.credentialInstruction.isEmpty,
                    "credentialInstruction missing for \(p.providerID)")
        }
    }

    // MARK: - api_mode validation

    @Test func onlyCustomSupportsAPIMode() {
        for p in LocalModelProvider.all {
            #expect(p.supportsAPIMode == (p.providerID == "custom"),
                    "supportsAPIMode wrong for \(p.providerID)")
        }
    }

    @Test func validAPIModesMatchTheRuntimeSetVerbatim() {
        // _VALID_API_MODES (runtime_provider.py:255-268), including the
        // codex_app_server runtime opt-in added 2026-05 — the runtime
        // HONORS that one, so the validator must not reject it. Hermes
        // silently ignores anything else, so this list is the UI's only
        // gate.
        #expect(LocalModelProvider.validAPIModes == [
            "chat_completions",
            "codex_responses",
            "anthropic_messages",
            "bedrock_converse",
            "codex_app_server",
        ])
    }

    @Test func pickerAPIModesAreTheTransportSubset() {
        // The picker hides codex_app_server (an openai/openai-codex
        // runtime opt-in, meaningless for a local endpoint) but every
        // offered mode must be valid.
        #expect(LocalModelProvider.pickerAPIModes == [
            "chat_completions",
            "codex_responses",
            "anthropic_messages",
            "bedrock_converse",
        ])
        for mode in LocalModelProvider.pickerAPIModes {
            #expect(LocalModelProvider.isValidAPIMode(mode))
        }
    }

    @Test func apiModeValidationMirrorsTheRuntimeNormalization() {
        for mode in LocalModelProvider.validAPIModes {
            #expect(LocalModelProvider.isValidAPIMode(mode))
        }
        // _parse_api_mode does raw.strip().lower() — whitespace and case
        // are both normalized before the set lookup, so these are honored
        // at runtime and must pass.
        #expect(LocalModelProvider.isValidAPIMode("  chat_completions  "))
        #expect(LocalModelProvider.isValidAPIMode("Chat_Completions"))
        #expect(LocalModelProvider.isValidAPIMode("ANTHROPIC_MESSAGES"))
        // No fuzzy-matching beyond that: a near-miss saved to config.yaml
        // is silently ignored — the trap this validator exists to close.
        #expect(!LocalModelProvider.isValidAPIMode("chat-completions"))
        #expect(!LocalModelProvider.isValidAPIMode("responses"))
        #expect(!LocalModelProvider.isValidAPIMode("openai"))
    }

    @Test func blankAPIModeMeansUnsetAndIsValid() {
        // Unset is fine — the runtime falls back to URL auto-detect,
        // then chat_completions.
        #expect(LocalModelProvider.isValidAPIMode(""))
        #expect(LocalModelProvider.isValidAPIMode("   \n"))
    }

    // MARK: - Managed config keys (the explicit write contract)

    @Test func everyDescriptorAlwaysManagesModelDefaultAndProvider() {
        for p in LocalModelProvider.all {
            #expect(p.configKeysWritten.contains("model.default"),
                    "model.default missing for \(p.providerID)")
            #expect(p.configKeysWritten.contains("model.provider"),
                    "model.provider missing for \(p.providerID)")
        }
    }

    @Test func configKeysWrittenPinsTheExactPerProviderSets() {
        // base_url iff (required || default exists) — today that's every
        // descriptor; api_key/api_mode only for the custom endpoint.
        // A drift here silently breaks the picker's clear-on-switch rule
        // (LocalModelConfigPlan derives its writes from these sets).
        #expect(LocalModelProvider.descriptor(for: "ollama")?.configKeysWritten
                == ["model.default", "model.provider", "model.base_url"])
        #expect(LocalModelProvider.descriptor(for: "lmstudio")?.configKeysWritten
                == ["model.default", "model.provider", "model.base_url"])
        #expect(LocalModelProvider.descriptor(for: "vllm")?.configKeysWritten
                == ["model.default", "model.provider", "model.base_url"])
        #expect(LocalModelProvider.descriptor(for: "llamacpp")?.configKeysWritten
                == ["model.default", "model.provider", "model.base_url"])
        #expect(LocalModelProvider.descriptor(for: "custom")?.configKeysWritten
                == ["model.default", "model.provider", "model.base_url",
                    "model.api_key", "model.api_mode"])
    }

    @Test func configKeysWrittenFollowsTheDescriptorFlags() {
        for p in LocalModelProvider.all {
            #expect(p.configKeysWritten.contains("model.base_url")
                    == (p.baseURLRequired || p.defaultBaseURL != nil),
                    "base_url rule wrong for \(p.providerID)")
            #expect(p.configKeysWritten.contains("model.api_key") == p.supportsAPIKey,
                    "api_key rule wrong for \(p.providerID)")
            #expect(p.configKeysWritten.contains("model.api_mode") == p.supportsAPIMode,
                    "api_mode rule wrong for \(p.providerID)")
        }
    }

    // MARK: - Model auto-detect and enumeration

    @Test func onlyCustomAllowsAnEmptyModelOnLoopback() {
        // Hermes auto-detects a single loaded model via GET
        // <base_url>/v1/models only on the bare-custom path with a
        // loopback host (runtime_provider.py:206-213).
        for p in LocalModelProvider.all {
            #expect(p.allowsEmptyModelWhenLoopback == (p.providerID == "custom"),
                    "allowsEmptyModelWhenLoopback wrong for \(p.providerID)")
        }
    }

    @Test func enumerationHintsMatchEachServersListingEndpoint() {
        #expect(LocalModelProvider.descriptor(for: "ollama")?.enumerationHint == .ollamaTags)
        for id in ["lmstudio", "vllm", "llamacpp", "custom"] {
            #expect(LocalModelProvider.descriptor(for: id)?.enumerationHint == .openAIModels,
                    "enumeration hint wrong for \(id)")
        }
    }

    // MARK: - Hermes-table isolation

    @Test func localTableStaysOutOfTheSyncedOverlayTable() {
        // check-hermes-tables.py lane 3 fails for any overlayOnlyProviders
        // key that isn't a Hermes HERMES_OVERLAYS entry. The local IDs
        // (other than lmstudio, which Hermes itself ships as an overlay)
        // must never leak into that table — local surfacing is UI-level
        // grouping only.
        for p in LocalModelProvider.all where p.providerID != "lmstudio" {
            #expect(ModelCatalogService.overlayOnlyProviders[p.providerID] == nil,
                    "\(p.providerID) must not enter the synced overlay table")
        }
    }
}
