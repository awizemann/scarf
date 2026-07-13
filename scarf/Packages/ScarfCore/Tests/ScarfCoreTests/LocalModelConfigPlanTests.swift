import Testing
import Foundation
@testable import ScarfCore

/// Pins the exact ordered `hermes config set` operations a model-picker
/// save performs — the write plan is the ONLY thing standing between the
/// UI and the silent-failure modes the T1 audit documented (stale
/// base_url redirecting a new provider, GH #27132 class; bare ollama
/// falling through to OpenRouter; a blanked API-key field leaving the
/// old secret in config.yaml).
///
/// Ordering is deliberate and crash/abort-safe (T4 audit): the executor
/// runs one `hermes config set` process per operation and aborts on the
/// first failure, so every PREFIX of a plan is a config some chat may
/// run against. Local plans commit `model.provider` LAST (base_url et
/// al. are in place before the provider flips); remote plans clear the
/// stale local keys LAST (never `provider: ollama` with a cleared
/// base_url — the silent-OpenRouter state).
@Suite struct LocalModelConfigPlanTests {

    private typealias Op = LocalModelConfigPlan.Operation

    // MARK: - Local selections

    @Test func ollamaAlwaysWritesItsBaseURLAndClearsTheRest() {
        // Cloud → ollama. base_url MUST be written even though the user
        // never touched the field (nil baseURL → descriptor default) —
        // omitting it silently routes chats to OpenRouter. base_url
        // lands BEFORE model.provider: no abort prefix ever reads as
        // provider=ollama without its endpoint.
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "ollama", modelID: "llama3:8b"
        ))
        #expect(ops == [
            .clear(key: "model.api_key"),
            .clear(key: "model.api_mode"),
            .set(key: "model.base_url", value: "http://127.0.0.1:11434/v1"),
            .set(key: "model.default", value: "llama3:8b"),
            .set(key: "model.provider", value: "ollama"),
        ])
    }

    @Test func explicitBaseURLWinsOverTheDescriptorDefault() {
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "ollama", modelID: "llama3:8b", baseURL: "http://192.168.1.20:11434/v1"
        ))
        #expect(ops.contains(.set(key: "model.base_url", value: "http://192.168.1.20:11434/v1")))
        #expect(!ops.contains(.set(key: "model.base_url", value: "http://127.0.0.1:11434/v1")))
    }

    @Test func lmstudioWritesItsDefaultBaseURLToo() {
        // base_url is optional at runtime for lmstudio (registry default)
        // but the descriptor manages the key (defaultBaseURL != nil), so
        // the save pins it explicitly — an honest config beats an
        // implicit fallback.
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "lmstudio", modelID: "qwen2.5-coder-14b"
        ))
        #expect(ops == [
            .clear(key: "model.api_key"),
            .clear(key: "model.api_mode"),
            .set(key: "model.base_url", value: "http://127.0.0.1:1234/v1"),
            .set(key: "model.default", value: "qwen2.5-coder-14b"),
            .set(key: "model.provider", value: "lmstudio"),
        ])
    }

    @Test func vllmWithoutABaseURLWritesNoBaseURLKey() {
        // No runtime default exists to fall back to; the UI gates submit
        // on a non-empty URL, but the plan must not invent one. The
        // unwritten base_url is then cleared, not left stale.
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "vllm", modelID: "meta-llama/Llama-3-8B"
        ))
        #expect(ops == [
            .clear(key: "model.base_url"),
            .clear(key: "model.api_key"),
            .clear(key: "model.api_mode"),
            .set(key: "model.default", value: "meta-llama/Llama-3-8B"),
            .set(key: "model.provider", value: "vllm"),
        ])
    }

    @Test func customWritesEveryKeyItWasGiven() {
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "custom",
            modelID: "my-model",
            baseURL: "http://10.0.0.5:8000/v1",
            apiKey: "sk-local-123",
            apiMode: "anthropic_messages"
        ))
        #expect(ops == [
            .set(key: "model.base_url", value: "http://10.0.0.5:8000/v1"),
            .set(key: "model.api_key", value: "sk-local-123"),
            .set(key: "model.api_mode", value: "anthropic_messages"),
            .set(key: "model.default", value: "my-model"),
            .set(key: "model.provider", value: "custom"),
        ])
    }

    @Test func customWithBlankedOptionalFieldsClearsThem() {
        // custom → custom re-save with the API key field emptied: the
        // old secret must be cleared, not left behind.
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "custom",
            modelID: "my-model",
            baseURL: "http://127.0.0.1:8000/v1",
            apiKey: "   ",
            apiMode: ""
        ))
        #expect(ops == [
            .clear(key: "model.api_key"),
            .clear(key: "model.api_mode"),
            .set(key: "model.base_url", value: "http://127.0.0.1:8000/v1"),
            .set(key: "model.default", value: "my-model"),
            .set(key: "model.provider", value: "custom"),
        ])
    }

    @Test func customEmptyModelOnLoopbackClearsModelDefault() {
        // Hermes only auto-detects the single loaded model when
        // model.default is EMPTY — a stale value would pin it.
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "custom", modelID: "", baseURL: "http://127.0.0.1:8000/v1"
        ))
        #expect(ops.contains(.clear(key: "model.default")))
        #expect(!ops.contains { if case .set(key: "model.default", value: _) = $0 { return true } else { return false } })
    }

    @Test func everyLocalPlanCommitsTheProviderLast() {
        // Crash-safety invariant (T4): for ANY local selection, the
        // `model.provider` write is the final operation — a crash or
        // per-op failure abort can never leave the new local provider
        // active without the keys it needs (no base_url → the runtime
        // silently falls through to OpenRouter).
        for descriptor in LocalModelProvider.all {
            let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
                providerID: descriptor.providerID,
                modelID: "m",
                baseURL: descriptor.defaultBaseURL ?? "http://127.0.0.1:9999/v1"
            ))
            #expect(ops.last == .set(key: "model.provider", value: descriptor.providerID),
                    "provider write must be last for \(descriptor.providerID)")
        }
    }

    @Test func invalidAPIModeIsNeverWritten() {
        // Hermes silently ignores invalid modes — writing one would save
        // fine and misbehave at request time. The plan drops it AND
        // clears the key.
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "custom",
            modelID: "m",
            baseURL: "http://127.0.0.1:8000/v1",
            apiMode: "chat-completions" // near-miss spelling
        ))
        #expect(ops.contains(.clear(key: "model.api_mode")))
    }

    @Test func apiModeIsNormalizedLikeTheRuntime() {
        // _parse_api_mode does strip().lower() — write the canonical form.
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "custom",
            modelID: "m",
            baseURL: "http://127.0.0.1:8000/v1",
            apiMode: "  Anthropic_Messages "
        ))
        #expect(ops.contains(.set(key: "model.api_mode", value: "anthropic_messages")))
    }

    @Test func spellingAliasesCanonicalizeTheWrittenProvider() {
        // A round-tripped `llama.cpp` from a CLI-written config saves
        // back as the canonical table ID.
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "llama.cpp", modelID: "m", baseURL: "http://127.0.0.1:8080/v1"
        ))
        #expect(ops.contains(.set(key: "model.provider", value: "llamacpp")))
    }

    @Test func apiKeyOnANonCustomProviderIsDroppedAndCleared() {
        // Descriptor contract: only custom supports an inline key — the
        // runtime supplies its own placeholder for the others.
        let ops = LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "ollama", modelID: "llama3:8b", apiKey: "should-not-write"
        ))
        #expect(ops.contains(.clear(key: "model.api_key")))
        #expect(!ops.contains(.set(key: "model.api_key", value: "should-not-write")))
    }

    @Test func nonLocalProviderYieldsAnEmptyLocalPlan() {
        #expect(LocalModelConfigPlan.operations(selecting: LocalModelSelection(
            providerID: "anthropic", modelID: "claude-opus-4-6"
        )).isEmpty)
    }

    // MARK: - Remote selections (clear-on-switch)

    @Test func localToCloudSwitchClearsAllLocalManagedKeys() {
        // Clears TRAIL the provider/model writes: clearing base_url
        // while model.provider is still `ollama` would be the
        // silent-OpenRouter state if the sequence aborts in between.
        let ops = LocalModelConfigPlan.operations(
            selectingRemoteModel: "claude-opus-4-6",
            provider: "anthropic",
            currentProvider: "ollama"
        )
        #expect(ops == [
            .set(key: "model.provider", value: "anthropic"),
            .set(key: "model.default", value: "claude-opus-4-6"),
            .clear(key: "model.base_url"),
            .clear(key: "model.api_key"),
            .clear(key: "model.api_mode"),
        ])
    }

    @Test func cloudToCloudSwitchAlsoClears() {
        // The rule is ANY provider switch — a stale base_url from a
        // hand-edited config must not survive an anthropic → openai hop.
        let ops = LocalModelConfigPlan.operations(
            selectingRemoteModel: "gpt-5",
            provider: "openai",
            currentProvider: "anthropic"
        )
        #expect(Array(ops.suffix(3)) == [
            .clear(key: "model.base_url"),
            .clear(key: "model.api_key"),
            .clear(key: "model.api_mode"),
        ])
    }

    @Test func knownAbsentLocalKeysAreNotReCleared() {
        // A user who never touched a local provider (all three current
        // values known-empty) gets exactly the classic two-op write —
        // no junk empty keys in config.yaml, no extra SSH round-trips.
        let ops = LocalModelConfigPlan.operations(
            selectingRemoteModel: "gpt-5",
            provider: "openai",
            currentProvider: "anthropic",
            currentBaseURL: "",
            currentAPIKey: "",
            currentAPIMode: ""
        )
        #expect(ops == [
            .set(key: "model.provider", value: "openai"),
            .set(key: "model.default", value: "gpt-5"),
        ])
    }

    @Test func onlyThePresentLocalKeysAreCleared() {
        // ollama → anthropic with a real base_url but no key/mode:
        // clear exactly what exists.
        let ops = LocalModelConfigPlan.operations(
            selectingRemoteModel: "claude-opus-4-6",
            provider: "anthropic",
            currentProvider: "ollama",
            currentBaseURL: "http://127.0.0.1:11434/v1",
            currentAPIKey: "",
            currentAPIMode: ""
        )
        #expect(ops == [
            .set(key: "model.provider", value: "anthropic"),
            .set(key: "model.default", value: "claude-opus-4-6"),
            .clear(key: "model.base_url"),
        ])
    }

    @Test func unknownCurrentValuesClearConservatively() {
        // nil (caller doesn't know the config) must behave like the
        // pre-parameter API: clear everything on a switch.
        let ops = LocalModelConfigPlan.operations(
            selectingRemoteModel: "gpt-5",
            provider: "openai",
            currentProvider: "anthropic",
            currentBaseURL: nil,
            currentAPIKey: nil,
            currentAPIMode: nil
        )
        #expect(ops.filter { if case .clear = $0 { return true } else { return false } }.count == 3)
    }

    @Test func sameProviderModelChangeDoesNotClear() {
        // Re-picking a model within one provider must not destroy a
        // hand-maintained model.base_url (MiniMax China endpoint class).
        let ops = LocalModelConfigPlan.operations(
            selectingRemoteModel: "claude-haiku-4-5",
            provider: "anthropic",
            currentProvider: "anthropic"
        )
        #expect(ops == [
            .set(key: "model.provider", value: "anthropic"),
            .set(key: "model.default", value: "claude-haiku-4-5"),
        ])
    }

    @Test func providerComparisonFoldsCaseWhitespaceAndSpellingAliases() {
        // `llama.cpp` in config vs `llamacpp` from the picker is NOT a
        // switch; ` Anthropic ` vs `anthropic` is NOT a switch.
        let viaAlias = LocalModelConfigPlan.operations(
            selectingRemoteModel: "m", provider: "llamacpp", currentProvider: "llama.cpp"
        )
        #expect(!viaAlias.contains(.clear(key: "model.base_url")))
        let viaCase = LocalModelConfigPlan.operations(
            selectingRemoteModel: "m", provider: "anthropic", currentProvider: " Anthropic "
        )
        #expect(!viaCase.contains(.clear(key: "model.base_url")))
    }

    @Test func emptyProviderKeepsCurrentProviderAndNeverClears() {
        // Custom catalog entry without a provider prefix: the host keeps
        // the current provider, so there is no switch to clean up after.
        let ops = LocalModelConfigPlan.operations(
            selectingRemoteModel: "some/model",
            provider: "",
            currentProvider: "ollama"
        )
        #expect(ops == [.set(key: "model.default", value: "some/model")])
    }

    @Test func emptyModelClearsModelDefault() {
        // Subscription providers (Nous) submit with an empty model and
        // the UI promises "leave blank for the provider's default" —
        // the previous provider's model.default must be CLEARED, not
        // left pinned (skipping the write was the T3 behavior; it kept
        // e.g. a stale claude-* model.default under provider=nous).
        let ops = LocalModelConfigPlan.operations(
            selectingRemoteModel: "",
            provider: "nous",
            currentProvider: "ollama",
            currentBaseURL: "", currentAPIKey: "", currentAPIMode: ""
        )
        #expect(ops == [
            .set(key: "model.provider", value: "nous"),
            .clear(key: "model.default"),
        ])
    }

    @Test func emptyModelAndProviderIsANoOpPlan() {
        #expect(LocalModelConfigPlan.operations(
            selectingRemoteModel: "", provider: "", currentProvider: "anthropic"
        ).isEmpty)
    }

    // MARK: - Wire format

    @Test func operationsMapToHermesConfigSetArgv() {
        #expect(Op.set(key: "model.provider", value: "ollama").cliArguments
                == ["config", "set", "model.provider", "ollama"])
        // Clear IS `set <key> ""` — Hermes v0.17 has no `config unset`;
        // the runtime reader treats empty strings as unset for all three
        // local-managed keys (see LocalModelConfigPlan doc).
        #expect(Op.clear(key: "model.base_url").cliArguments
                == ["config", "set", "model.base_url", ""])
    }
}
