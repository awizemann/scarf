import Testing
import Foundation
@testable import ScarfCore

/// Whole-surface audit P13 — provider-alias resolution in
/// `ModelCatalogService` (finding 8).
///
/// Hermes keeps **two** provider tables and they answer different questions:
///
/// - `hermes_cli/providers.py` `ALIASES` — inference ROUTING. Scarf mirrors
///   it in `providerAliases` and `scripts/check-hermes-tables.py` lane 1
///   gates the mirror.
/// - `agent/models_dev.py` `PROVIDER_TO_MODELS_DEV` — capability METADATA,
///   i.e. which models.dev catalog a provider's models live in. Scarf
///   mirrors the entries that diverge from the alias resolution in
///   `capabilityProviderOverrides`, and this suite plus the new
///   `models-dev` lane of the same script gate that mirror.
///
/// The two tables disagree on purpose (`openai` routes to `openrouter` but
/// resolves metadata against models.dev's `openai`), which is why a single
/// "canonicalise everything" pass is the wrong shape — see
/// `canonicalisationNeverMovesACanonicalProvider`.
struct ModelCatalogAliasParityP13Tests {

    /// Non-identity entries of `PROVIDER_TO_MODELS_DEV`, transcribed
    /// verbatim from `git show v2026.9.7:agent/models_dev.py` (`:107-130`).
    /// Every one of these must survive `modelsDevProviderKey` — through
    /// `capabilityProviderOverrides`, through `providerAliases`, or both.
    private static let hermesModelsDevMap: [String: String] = [
        "novita": "novita-ai",
        "openai-api": "openai",
        "openai-codex": "openai",
        "kimi": "kimi-for-coding",
        "kimi-coding": "kimi-for-coding",
        "moonshot": "kimi-for-coding",
        "kimi-coding-cn": "kimi-for-coding",
        "minimax-oauth": "minimax",
        "qwen-oauth": "alibaba",
        "copilot": "github-copilot",
        "ai-gateway": "vercel",
        "opencode-zen": "opencode",
        "opencode-free": "opencode",
        "kilocode": "kilo",
        "fireworks": "fireworks-ai",
        "gemini": "google",
        "xai-oauth": "xai",
        "meta-ai": "meta",
    ]

    /// The drift alarm. Fails the moment Scarf's two tables stop resolving a
    /// Hermes `PROVIDER_TO_MODELS_DEV` entry the way Hermes does — which is
    /// how `meta-ai` and `opencode-free` were missing: neither is a
    /// `providers.py` alias, so `canonicalProviderID` left them alone and
    /// their capability lookup fell through to the generic default (a 256K
    /// context and no vision, for a 1M-context vision model).
    @Test func modelsDevProviderKeyMirrorsHermes() {
        for (hermesID, modelsDevID) in Self.hermesModelsDevMap {
            #expect(
                ModelCatalogService.modelsDevProviderKey(for: hermesID) == modelsDevID,
                "\(hermesID) resolves to \(ModelCatalogService.modelsDevProviderKey(for: hermesID)) — Hermes says \(modelsDevID)"
            )
        }
    }

    /// The identity entries matter too: a provider Hermes maps to itself
    /// must not be moved by Scarf's alias table. `openai` is the one that
    /// bites — `providers.py` ALIASES routes bare `openai` to `openrouter`,
    /// while `PROVIDER_TO_MODELS_DEV["openai"] == "openai"`.
    @Test func identityEntriesStayPut() {
        for id in ["openai", "openrouter", "anthropic", "zai", "stepfun",
                   "minimax", "minimax-cn", "deepseek", "alibaba", "xai",
                   "opencode-go", "huggingface", "google", "xiaomi", "nvidia",
                   "meta", "groq", "mistral", "togetherai", "perplexity",
                   "cohere", "ollama-cloud"] {
            #expect(ModelCatalogService.modelsDevProviderKey(for: id) == id, "\(id) moved")
        }
    }

    /// Catalog lookups resolve an alias ONLY when the raw spelling is not in
    /// the catalog. This is the property that makes the change safe under
    /// charter C1: a user whose `model.provider` already names a catalog
    /// entry sees byte-identical results.
    @Test func canonicalisationNeverMovesACanonicalProvider() throws {
        let (svc, cleanup) = try Self.fixture()
        defer { cleanup() }

        // `openai` IS in the catalog, and `providerAliases["openai"] ==
        // "openrouter"` — resolving it would hand the user OpenRouter's
        // catalog instead of OpenAI's.
        #expect(svc.loadModels(for: "openai").map(\.modelID) == ["gpt-5"])
        #expect(svc.providerByID("openai")?.providerName == "OpenAI")
        #expect(svc.model(providerID: "openai", modelID: "gpt-5")?.modelName == "GPT-5")
    }

    /// …and an alias spelling that is NOT in the catalog now resolves,
    /// where it used to return an empty list / nil. `grok`, `claude` and
    /// `hf` are all legal `model.provider` values Hermes accepts
    /// (`providers.py` ALIASES) and Scarf's picker silently could not reach.
    @Test func aliasSpellingsReachTheirCatalog() throws {
        let (svc, cleanup) = try Self.fixture()
        defer { cleanup() }

        #expect(svc.loadModels(for: "claude").map(\.modelID) == ["claude-4.7-opus"])
        #expect(svc.loadModels(for: "grok").map(\.modelID) == ["grok-4.3"])
        #expect(svc.model(providerID: "claude", modelID: "claude-4.7-opus") != nil)
        #expect(svc.providerByID("grok")?.providerName == "xAI")
        // The reported providerID stays the CALLER's spelling — the config's
        // own value — so nothing downstream starts writing a different one.
        #expect(svc.providerByID("grok")?.providerID == "grok")
        #expect(svc.loadModels(for: "claude").allSatisfy { $0.providerID == "claude" })
    }

    /// `validateModel` used to block a save under an alias spelling: the
    /// provider's model list came back empty, the provider was not an
    /// overlay, so a perfectly valid model was reported `.unknownProvider`.
    @Test func validateModelAcceptsAliasSpellings() throws {
        let (svc, cleanup) = try Self.fixture()
        defer { cleanup() }
        #expect(svc.validateModel("claude-4.7-opus", for: "claude") == .valid)
        #expect(svc.validateModel("grok-4.3", for: "x-ai") == .valid)
        // A genuinely wrong model under a resolvable alias is still blocked.
        if case .invalid = svc.validateModel("gpt-5", for: "claude") {} else {
            Issue.record("gpt-5 is not an Anthropic model and must not validate")
        }
    }

    /// Model-rename aliases are keyed by the CANONICAL provider id, so a
    /// config spelling the provider `grok` or `x-ai` missed every entry.
    @Test func modelAliasesResolveThroughProviderAliases() throws {
        let (svc, cleanup) = try Self.fixture()
        defer { cleanup() }
        // Registered as `xai/grok-3` → `grok-4.3`.
        #expect(svc.resolveModelAlias(providerID: "xai", modelID: "grok-3") == "grok-4.3")
        #expect(svc.resolveModelAlias(providerID: "grok", modelID: "grok-3") == "grok-4.3")
        #expect(svc.resolveModelAlias(providerID: "x-ai", modelID: "grok-3") == "grok-4.3")
        // Unknown pairs pass through untouched.
        #expect(svc.resolveModelAlias(providerID: "grok", modelID: "grok-4.3") == "grok-4.3")
    }

    /// `providerDisplayNameOverrides` was applied on 2 of 5 paths, so the
    /// same provider read "Qwen Cloud" in the provider list and "alibaba" in
    /// the detail row it opened.
    @Test func displayNameOverridesApplyOnEveryPath() throws {
        let (svc, cleanup) = try Self.fixture()
        defer { cleanup() }
        #expect(svc.loadProviders().first { $0.providerID == "alibaba" }?.providerName == "Qwen Cloud")
        #expect(svc.loadModels(for: "alibaba").first?.providerName == "Qwen Cloud")
        #expect(svc.providerByID("alibaba")?.providerName == "Qwen Cloud")
        #expect(svc.provider(for: "qwen4-max")?.providerName == "Qwen Cloud")
        #expect(svc.model(providerID: "alibaba", modelID: "qwen4-max")?.providerName == "Qwen Cloud")
    }

    // MARK: - Fixture

    private static func fixture() throws -> (ModelCatalogService, () -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-alias-catalog-\(UUID().uuidString).json")
        let json = """
        {
          "anthropic": { "id": "anthropic", "name": "Anthropic", "models": {
            "claude-4.7-opus": { "name": "Claude Opus 4.7" } } },
          "openai": { "id": "openai", "name": "OpenAI", "models": {
            "gpt-5": { "name": "GPT-5" } } },
          "openrouter": { "id": "openrouter", "name": "OpenRouter", "models": {
            "x-ai/grok-4.20": { "name": "Grok 4.20" } } },
          "xai": { "id": "xai", "name": "xAI", "models": {
            "grok-4.3": { "name": "Grok 4.3" } } },
          "alibaba": { "id": "alibaba", "name": "Alibaba", "models": {
            "qwen4-max": { "name": "Qwen4 Max" } } }
        }
        """
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        return (ModelCatalogService(path: tmp.path), { try? FileManager.default.removeItem(at: tmp) })
    }
}
