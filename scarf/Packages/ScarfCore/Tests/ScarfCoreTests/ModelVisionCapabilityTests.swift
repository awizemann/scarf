import Foundation
import Testing
@testable import ScarfCore

/// t-31img / gh#113 — the composer's "this model can't see images"
/// heads-up. Three pieces under test:
///
/// 1. `ModelCatalogService.visionCapability` — three-state parse of the
///    models.dev cache. Fixtures pin the REAL 2026-07 cache shape
///    (every entry carries `modalities.input` + a legacy `attachment`
///    bool; Hermes prefers modalities, falls back to attachment).
/// 2. `RichChatViewModel.resolveActiveModel` — preset override beats
///    the config.yaml global default (the ChatModelBadge resolution).
/// 3. `RichChatViewModel.shouldShowNonVisionImageHint` — the pure
///    "should warn" decision (attachment present × capability state).
@Suite struct ModelVisionCapabilityTests {

    /// Write a fixture catalog to a unique tmp path. Unique per call —
    /// `visionCapability` memoizes per (path, provider, model), so
    /// distinct paths keep tests independent.
    private func makeCatalog(_ json: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-vision-\(UUID().uuidString).json")
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }

    /// The real cache shape: `modalities.input` present on every entry,
    /// plus the legacy `attachment` bool. `claude-vision` mirrors a
    /// verified anthropic entry (`input: [text, image, pdf]`,
    /// `attachment: true`); `text-only` mirrors a verified deepseek
    /// entry (`input: [text]`, `attachment: false`).
    private let realShapeJSON = """
    {
      "anthropic": {
        "id": "anthropic",
        "name": "Anthropic",
        "models": {
          "claude-vision": {
            "name": "Claude Vision",
            "attachment": true,
            "modalities": { "input": ["text", "image", "pdf"], "output": ["text"] },
            "limit": { "context": 200000, "output": 64000 }
          },
          "text-only": {
            "name": "Text Only",
            "attachment": false,
            "modalities": { "input": ["text"], "output": ["text"] }
          },
          "stale-attachment-flag": {
            "name": "Stale Attachment Flag",
            "attachment": true,
            "modalities": { "input": ["text"], "output": ["text"] }
          },
          "attachment-only-yes": {
            "name": "Attachment Only Yes",
            "attachment": true
          },
          "attachment-only-no": {
            "name": "Attachment Only No",
            "attachment": false
          },
          "no-signal": {
            "name": "No Signal"
          }
        }
      },
      "openai": {
        "id": "openai",
        "name": "OpenAI",
        "models": {
          "gpt-4o": {
            "name": "GPT-4o",
            "attachment": true,
            "modalities": { "input": ["text", "image", "pdf"], "output": ["text"] }
          }
        }
      }
    }
    """

    // MARK: - Capability parse (three states)

    @Test func modalitiesShapedVisionModelIsYes() throws {
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "claude-vision") == .yes)
    }

    @Test func modalitiesShapedTextOnlyModelIsNo() throws {
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "text-only") == .no)
    }

    @Test func modalitiesWinOverStaleAttachmentFlag() throws {
        // Hermes prefers `modalities.input` and only falls back to
        // `attachment` when modalities are absent — a text-only
        // modalities list beats `attachment: true`.
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "stale-attachment-flag") == .no)
    }

    @Test func attachmentFlagShapedEntriesFallBack() throws {
        // Older cache shape: no modalities at all — the attachment bool
        // decides (Hermes's documented fallback).
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "attachment-only-yes") == .yes)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "attachment-only-no") == .no)
    }

    @Test func entryWithNeitherFieldIsConfidentNo() throws {
        // Hermes coerces a missing `attachment` to False → text
        // pipeline WILL fire, so this is a warnable .no, not .unknown.
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "no-signal") == .no)
    }

    @Test func modelAbsentFromCatalogIsUnknown() throws {
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "brand-new-model") == .unknown)
    }

    @Test func providerAbsentFromCatalogIsUnknown() throws {
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "nous", modelID: "hermes-4-405b") == .unknown)
    }

    @Test func missingCacheFileIsUnknown() {
        let svc = ModelCatalogService(path: "/tmp/scarf-vision-nonexistent-\(UUID().uuidString).json")
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "claude-vision") == .unknown)
    }

    @Test func localModelsAreUnknownNotNo() throws {
        // Ollama tags are absent from models.dev — `ollama` aliases to
        // `custom`, which never appears in the cache. Must be .unknown
        // (llama3.2-vision exists; a false "can't see images" would be
        // wrong), never a confident .no.
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "ollama", modelID: "llama3.2-vision") == .unknown)
        #expect(svc.visionCapability(providerID: "custom", modelID: "whatever") == .unknown)
    }

    @Test func emptyInputsAreUnknown() throws {
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "", modelID: "claude-vision") == .unknown)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "   ") == .unknown)
    }

    // MARK: - Provider mapping

    @Test func providerAliasResolvesBeforeLookup() throws {
        // `claude` is a providers.py alias for `anthropic`.
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "claude", modelID: "claude-vision") == .yes)
    }

    @Test func openAIVariantsResolveToOpenAICacheKey() throws {
        // Bare `openai` aliases to `openrouter` for inference routing,
        // but Hermes's capability lookup (PROVIDER_TO_MODELS_DEV)
        // resolves it — and the openai-codex variant — against the
        // models.dev `openai` entry. `openai-api` is a deliberate
        // Scarf EXTENSION (Hermes's map has no such key and resolves
        // no metadata there): mapping it to the same catalog keeps the
        // heads-up truthful for text-only models and merely suppressed
        // for vision models — never falsely shown.
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "openai", modelID: "gpt-4o") == .yes)
        #expect(svc.visionCapability(providerID: "openai-api", modelID: "gpt-4o") == .yes)
        #expect(svc.visionCapability(providerID: "openai-codex", modelID: "gpt-4o") == .yes)
    }

    /// The two PROVIDER_TO_MODELS_DEV entries whose models.dev cache
    /// key differs from the Hermes wire ID (`novita` → `novita-ai`,
    /// `fireworks` → `fireworks-ai`). Before the audit fix Scarf looked
    /// up the bare wire ID, found nothing, and resolved `.unknown` —
    /// silently disabling the heads-up for two real providers (the
    /// live cache carries 105 novita-ai models).
    @Test func novitaAndFireworksResolveToTheirModelsDevKeys() throws {
        let json = """
        {
          "novita-ai": {
            "id": "novita-ai", "name": "NovitaAI",
            "models": {
              "deepseek/deepseek-v3": {
                "name": "DeepSeek V3", "attachment": false,
                "modalities": { "input": ["text"], "output": ["text"] }
              }
            }
          },
          "fireworks-ai": {
            "id": "fireworks-ai", "name": "Fireworks",
            "models": {
              "qwen-vl": {
                "name": "Qwen VL", "attachment": true,
                "modalities": { "input": ["text", "image"], "output": ["text"] }
              }
            }
          }
        }
        """
        let tmp = try makeCatalog(json)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "novita", modelID: "deepseek/deepseek-v3") == .no)
        // The models.dev-key spelling (a providers.py alias for
        // `novita`) must land on the same entry.
        #expect(svc.visionCapability(providerID: "novita-ai", modelID: "deepseek/deepseek-v3") == .no)
        #expect(svc.visionCapability(providerID: "fireworks", modelID: "qwen-vl") == .yes)
        #expect(svc.visionCapability(providerID: "fireworks-ai", modelID: "qwen-vl") == .yes)
    }

    @Test func aliasSpellingsReachCapabilityOverrides() throws {
        // Hermes normalizes provider aliases BEFORE its
        // PROVIDER_TO_MODELS_DEV lookup: `grok-oauth` → `xai-oauth` →
        // models.dev `xai`. Scarf must chain the same way (alias
        // resolution, then the capability override for the canonical
        // ID).
        let json = """
        {
          "xai": {
            "id": "xai", "name": "xAI",
            "models": {
              "grok-4.3": {
                "name": "Grok 4.3", "attachment": true,
                "modalities": { "input": ["text", "image", "pdf"], "output": ["text"] }
              }
            }
          }
        }
        """
        let tmp = try makeCatalog(json)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "grok-oauth", modelID: "grok-4.3") == .yes)
        #expect(svc.visionCapability(providerID: "x-ai-oauth", modelID: "grok-4.3") == .yes)
    }

    @Test func redundantProviderPrefixOnModelIDIsStripped() throws {
        // config.yaml's model.default sometimes carries a provider
        // prefix (`anthropic/claude-vision` under provider anthropic).
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "anthropic/claude-vision") == .yes)
        // A foreign prefix must NOT strip — no confident answer.
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "xai/claude-vision") == .unknown)
    }

    // MARK: - Memoization

    @Test func lookupIsMemoizedPerProviderModel() throws {
        // Second lookup must come from the in-memory memo, not disk:
        // rewrite the file with the capability flipped and expect the
        // first answer to stick (per-app-run stability is documented).
        let tmp = try makeCatalog(realShapeJSON)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let svc = ModelCatalogService(path: tmp.path)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "claude-vision") == .yes)

        let flipped = realShapeJSON.replacingOccurrences(
            of: "\"input\": [\"text\", \"image\", \"pdf\"]",
            with: "\"input\": [\"text\"]"
        )
        try flipped.write(to: tmp, atomically: true, encoding: .utf8)
        #expect(svc.visionCapability(providerID: "anthropic", modelID: "claude-vision") == .yes)
    }

    // MARK: - Active-model resolution precedence

    @Test func presetOverridesGlobalDefault() {
        let preset = ModelPreset(name: "Fast", modelID: "grok-4.3", providerID: "xai")
        let resolved = RichChatViewModel.resolveActiveModel(
            preset: preset,
            configProvider: "anthropic",
            configModel: "claude-vision"
        )
        #expect(resolved?.providerID == "xai")
        #expect(resolved?.modelID == "grok-4.3")
    }

    @Test func globalDefaultUsedWhenNoPreset() {
        let resolved = RichChatViewModel.resolveActiveModel(
            preset: nil,
            configProvider: " anthropic ",
            configModel: "claude-vision"
        )
        #expect(resolved?.providerID == "anthropic")
        #expect(resolved?.modelID == "claude-vision")
    }

    @Test func unsetConfigResolvesToNil() {
        // "" and the YAML parser's "unknown" fallback both mean unset
        // (ModelPreflight semantics). Also covers the Local tab's legal
        // empty-model.default auto-detect config — must resolve nil
        // (capability-unknown), never a warnable model.
        #expect(RichChatViewModel.resolveActiveModel(
            preset: nil, configProvider: "custom", configModel: ""
        ) == nil)
        #expect(RichChatViewModel.resolveActiveModel(
            preset: nil, configProvider: "unknown", configModel: "claude-vision"
        ) == nil)
        #expect(RichChatViewModel.resolveActiveModel(
            preset: nil, configProvider: "", configModel: ""
        ) == nil)
    }

    // MARK: - Should-warn decision

    @Test func warnsOnlyWithAttachmentsAndConfidentNo() {
        typealias VC = ModelCatalogService.VisionCapability
        // attachment present × capability matrix
        #expect(RichChatViewModel.shouldShowNonVisionImageHint(attachmentCount: 1, capability: VC.no))
        #expect(RichChatViewModel.shouldShowNonVisionImageHint(attachmentCount: 3, capability: VC.no))
        #expect(!RichChatViewModel.shouldShowNonVisionImageHint(attachmentCount: 1, capability: VC.yes))
        #expect(!RichChatViewModel.shouldShowNonVisionImageHint(attachmentCount: 1, capability: VC.unknown))
        #expect(!RichChatViewModel.shouldShowNonVisionImageHint(attachmentCount: 0, capability: VC.no))
        #expect(!RichChatViewModel.shouldShowNonVisionImageHint(attachmentCount: 0, capability: VC.yes))
        #expect(!RichChatViewModel.shouldShowNonVisionImageHint(attachmentCount: 0, capability: VC.unknown))
    }

    @Test func hintCopyNamesTheModelAndTheFallback() {
        let hint = RichChatViewModel.nonVisionImageHint(modelDisplayName: "deepseek-v4-flash")
        #expect(hint.hasPrefix("deepseek-v4-flash "))
        #expect(hint.contains("vision fallback"))
        #expect(hint.contains("Pick a vision model"))
    }

    // MARK: - Config-override suppression (audit fix)

    /// `agent.image_input_mode: native` and a true-token
    /// `model.supports_vision` both flip Hermes to native pixel
    /// routing BEFORE any models.dev lookup — a catalog `.no` under
    /// either would be exactly the false warning t-31img forbids.
    /// Token sets mirror `image_routing.py` (`_coerce_mode`,
    /// `_TRUE_TOKENS`).
    @Test func configOverridesSuppressTheHint() {
        #expect(RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "agent:\n  image_input_mode: native\n"))
        #expect(RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "agent:\n  image_input_mode: \"native\"\n"))
        #expect(RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "model:\n  supports_vision: true\n"))
        #expect(RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "model:\n  supports_vision: \"yes\"\n"))
        #expect(RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "model:\n  supports_vision: 1\n"))
    }

    @Test func nonOverridingConfigsDoNotSuppress() {
        // auto/text modes leave the capability verdict authoritative
        // (text mode makes the fallback copy TRUE, not false), and a
        // false-token supports_vision matches the catalog's own .no.
        #expect(!RichChatViewModel.nonVisionHintSuppressedByConfig(configYAML: ""))
        #expect(!RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "agent:\n  image_input_mode: auto\n"))
        #expect(!RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "agent:\n  image_input_mode: text\n"))
        #expect(!RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "model:\n  supports_vision: false\n"))
        #expect(!RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "model:\n  supports_vision: banana\n"))
        #expect(!RichChatViewModel.nonVisionHintSuppressedByConfig(
            configYAML: "model:\n  default: claude-sonnet-4-5\n  provider: anthropic\n"))
    }
}
