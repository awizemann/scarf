import Foundation

/// The `model.provider` values Hermes can actually route (S06-F1).
///
/// The models.dev cache Scarf's picker reads lists ~220 providers, but
/// Hermes only routes the ones its own registry knows. Anything else fails
/// at `auth.resolve_provider` with "Unknown provider '<id>'"
/// (`hermes_cli/auth.py:1500-1509` @ `v2026.9.24`) before any API key is
/// looked up, so saving `mistral` or `groq` looks fine and every chat then
/// fails (or silently runs on some other provider).
///
/// `providerIDs` is every spelling `resolve_runtime_provider`
/// (`hermes_cli/runtime_provider.py:975-1005`) accepts from the name alone:
/// - `PROVIDER_REGISTRY` keys: the `_REGISTRY_ROWS` built-ins plus the
///   bundled `plugins/model-providers/*` profiles and aliases that
///   `sync_plugin_provider_registry` mirrors in
///   (`hermes_cli/auth_plugin_providers.py:45-89,107-137`);
/// - every `_plugin_aliases()` key whose target is a registry key,
///   `openrouter` or `custom` (`hermes_cli/auth.py:1300-1349`);
/// - `openrouter`, `custom`, `auto`, `moa`, the `_VERTEX_NAMES`
///   shortcuts (`runtime_provider.py:855`) and `_DIRECT_API_BASE_URLS`
///   (`openai` becomes a `custom` endpoint first,
///   `hermes_cli/runtime_provider_custom.py:464-481`).
///
/// Named `providers:` / `custom_providers:` entries and `custom:<name>`
/// depend on config.yaml, so they are handled by the callers, not listed.
/// A user plugin under `$HERMES_HOME/plugins/model-providers` can add names
/// Scarf can't see; that is why the preflight check only warns.
///
/// `providerIDs` is the CURRENT band (v0.21.4+), generated from Hermes and
/// kept honest by `scripts/check-hermes-tables.py` lane 8 (FAILs both ways).
/// Older hosts get the same bug (a models.dev-only provider fails with
/// "Unknown provider" at every tag since v0.6), so ``olderBands`` rebuilds
/// each older version's set as reverse deltas from it. Those were measured
/// by calling each tag's own `resolve_runtime_provider` on every candidate
/// name (`scripts/probe-hermes-routable-bands.py`, which also re-checks
/// this table); released tags never change, so the bands are frozen.
/// Applies on hosts with ``HermesCapabilities/hasRoutableProviderTable``.
public enum HermesRoutableProviders {
    static let providerIDs: Set<String> = [
        "aci", "actual", "actual-computer", "actualcomputer", "ai-gateway", "ai_gateway",
        "aigateway", "alibaba", "alibaba-cloud", "alibaba-cloud-cn", "alibaba-cn",
        "alibaba-coding", "alibaba-coding-cn", "alibaba-coding-plan", "alibaba-coding-plan-cn",
        "alibaba-token-plan", "alibaba-token-plan-cn", "alibaba_coding", "alibaba_coding_plan",
        "aliyun", "amazon", "amazon-bedrock", "anthropic", "arcee", "arcee-ai", "arceeai", "auto",
        "aws", "aws-bedrock", "azure", "azure-ai", "azure-ai-foundry", "azure-foundry", "bedrock",
        "build-nvidia", "chatgpt", "chatgpt-codex", "claude", "claude-code", "claude-oauth",
        "codex", "commandcode", "commandcode-anthropic", "commandcode-chat", "commandcode-claude",
        "copilot", "copilot-acp", "copilot-acp-agent", "custom", "dashscope", "dashscope-cn",
        "dashscope-coding", "dashscope-coding-cn", "dashscope-token-plan",
        "dashscope-token-plan-cn", "deep-infra", "deep-seek", "deepinfra", "deepinfra-ai",
        "deepseek", "deepseek-chat", "fireworks", "fireworks-ai", "fw", "gcp-vertex", "gemini",
        "github", "github-copilot", "github-copilot-acp", "github-model", "github-models", "glm",
        "gmi", "gmi-cloud", "gmicloud", "go", "google", "google-ai-studio", "google-gemini",
        "google-vertex", "grok", "grok-oauth", "hf", "hugging-face", "huggingface",
        "huggingface-hub", "kilo", "kilo-code", "kilo-gateway", "kilocode", "kimi", "kimi-cn",
        "kimi-coding", "kimi-coding-cn", "kimi-for-coding", "llama-cpp", "llama.cpp", "llamacpp",
        "lm-studio", "lm_studio", "lmstudio", "local", "meta", "meta-ai", "mimo", "mini-max",
        "minimax", "minimax-china", "minimax-cn", "minimax-global", "minimax-oauth",
        "minimax-oauth-io", "minimax-portal", "minimax_cn", "minimax_oauth", "moa", "model-api",
        "moonshot", "moonshot-cn", "msl", "muse", "muse-spark", "nebius", "nebius-tf",
        "nebius-token-factory", "nebius-tokenfactory", "nemotron", "nim", "nous", "nous-portal",
        "nousresearch", "novita", "novita-ai", "novitaai", "nvidia", "nvidia-nim", "ollama",
        "ollama-cloud", "ollama_cloud", "openai", "openai-api", "openai-codex", "openai_codex",
        "opencode", "opencode-go", "opencode-go-sub", "opencode-zen", "opencode_go",
        "opencode_zen", "openrouter", "or", "qwen", "qwen-cli", "qwen-dashscope", "qwen-oauth",
        "qwen-portal", "ramp", "ramp-router", "router", "router.com", "solar", "step", "stepfun",
        "stepfun-coding-plan", "tencent", "tencent-cloud", "tencent-lkeap", "tencent-tokenhub",
        "tencent-tokenplan", "tencentmaas", "token-factory", "tokenfactory", "tokenhub",
        "tokenplan", "upstage", "vercel", "vercel-ai-gateway", "vertex", "vertex-ai", "vertexai",
        "vllm", "x-ai", "x-ai-oauth", "x.ai", "xai", "xai-grok-oauth", "xai-oauth", "xiaomi",
        "xiaomi-mimo", "z-ai", "z.ai", "zai", "zen", "zhipu"
    ]

    /// One version floor at which the routable set changed: `added` names
    /// first route at `below` (the tag's version), `removed` stop routing
    /// there. Newest first.
    struct Band: Sendable {
        let below: HermesCapabilities.SemVer
        let tag: String
        let added: [String]
        let removed: [String]
    }

    /// The oldest Hermes the bands were measured for (v2026.3.30). Scarf's
    /// supported floor; below it (and for an undetected host) nothing is
    /// filtered.
    static let oldestBandVersion = HermesCapabilities.SemVer(major: 0, minor: 6, patch: 0)

    /// Reverse deltas from `providerIDs`, newest first. A host below
    /// `below` routes the next-newer set minus `added` plus `removed`.
    /// Generated by `scripts/probe-hermes-routable-bands.py`; do not edit
    /// by hand.
    static let olderBands: [Band] = [
        Band(
            below: .init(major: 0, minor: 21, patch: 4), tag: "v2026.9.21",
            added: [
                "chatgpt", "chatgpt-codex", "openai"
            ],
            removed: [
                "free", "opencode-free", "opencode_free"
            ]
        ),
        Band(
            below: .init(major: 0, minor: 21, patch: 3), tag: "v2026.9.14",
            added: [
                "aliyun", "build-nvidia", "deep-seek", "nemotron", "nim"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 21, patch: 0), tag: "v2026.8.31",
            added: [
                "alibaba-cloud-cn", "alibaba-cn", "alibaba-coding-cn", "alibaba-coding-plan-cn",
                "alibaba-token-plan", "alibaba-token-plan-cn", "dashscope-cn", "dashscope-coding-cn",
                "dashscope-token-plan", "dashscope-token-plan-cn", "nebius", "nebius-tf",
                "nebius-token-factory", "nebius-tokenfactory", "ramp", "ramp-router", "router",
                "router.com", "tencent-lkeap", "tencent-tokenplan", "token-factory", "tokenfactory",
                "tokenplan"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 20, patch: 5), tag: "v2026.8.19",
            added: [
                "free", "opencode-free", "opencode_free"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 20, patch: 4), tag: "v2026.8.18",
            added: [
                "meta", "meta-ai", "model-api", "msl", "muse", "muse-spark"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 20, patch: 3), tag: "v2026.8.16.2",
            added: [
                "commandcode", "commandcode-anthropic", "commandcode-chat", "commandcode-claude"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 20, patch: 1), tag: "v2026.8.13",
            added: [
                "aci", "actual", "actual-computer", "actualcomputer"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 19, patch: 1), tag: "v2026.7.30",
            added: [
                "ai-gateway", "ai_gateway", "aigateway", "vercel", "vercel-ai-gateway"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 19, patch: 0), tag: "v2026.7.20",
            added: [
                "deep-infra", "deepinfra", "deepinfra-ai", "fireworks", "fireworks-ai", "fw", "solar",
                "upstage"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 18, patch: 0), tag: "v2026.7.1",
            added: [
                "gcp-vertex", "google-vertex", "moa", "vertex", "vertex-ai", "vertexai"
            ],
            removed: [
                "gemini-cli", "gemini-oauth", "google-gemini-cli"
            ]
        ),
        Band(
            below: .init(major: 0, minor: 15, patch: 0), tag: "v2026.5.28",
            added: [
                "openai-api"
            ],
            removed: [
                "ai-gateway", "ai_gateway", "aigateway", "vercel", "vercel-ai-gateway"
            ]
        ),
        Band(
            below: .init(major: 0, minor: 14, patch: 0), tag: "v2026.5.16",
            added: [
                "grok-oauth", "novita", "novita-ai", "novitaai", "x-ai-oauth", "xai-grok-oauth",
                "xai-oauth"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 13, patch: 0), tag: "v2026.5.7",
            added: [
                "ai_gateway", "alibaba-cloud", "azure", "azure-ai", "azure-ai-foundry", "claude-oauth",
                "codex", "dashscope", "dashscope-coding", "deepseek-chat", "local", "mini-max",
                "minimax-oauth-io", "nous-portal", "nousresearch", "nvidia-nim", "openai_codex",
                "opencode_go", "opencode_zen", "or", "qwen", "qwen-dashscope"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 12, patch: 0), tag: "v2026.4.30",
            added: [
                "alibaba-coding", "alibaba-coding-plan", "alibaba_coding", "alibaba_coding_plan",
                "azure-foundry", "gmi", "gmi-cloud", "gmicloud", "minimax-global", "minimax-oauth",
                "minimax-portal", "minimax_oauth", "tencent", "tencent-cloud", "tencent-tokenhub",
                "tencentmaas", "tokenhub"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 11, patch: 0), tag: "v2026.4.23",
            added: [
                "gemini-cli", "gemini-oauth", "google-gemini-cli", "nvidia", "step", "stepfun",
                "stepfun-coding-plan"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 10, patch: 0), tag: "v2026.4.16",
            added: [
                "amazon", "amazon-bedrock", "arcee", "arcee-ai", "arceeai", "aws", "aws-bedrock",
                "bedrock", "grok", "ollama-cloud", "ollama_cloud", "x-ai", "x.ai"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 9, patch: 0), tag: "v2026.4.13",
            added: [
                "kimi-cn", "kimi-coding-cn", "kimi-for-coding", "mimo", "moonshot-cn", "qwen-cli",
                "qwen-oauth", "qwen-portal", "xai", "xiaomi", "xiaomi-mimo"
            ],
            removed: []
        ),
        Band(
            below: .init(major: 0, minor: 8, patch: 0), tag: "v2026.4.8",
            added: [
                "gemini", "google", "google-ai-studio", "google-gemini"
            ],
            removed: []
        ),
    ]

    /// The names Hermes `version` routes, or nil below ``oldestBandVersion``.
    /// A build between tags reports the last tag's version (Hermes bumps
    /// pyproject at release), so it gets that tag's band; a provider added
    /// on `main` since then stays hidden until the next tag.
    static func providerIDs(for version: HermesCapabilities.SemVer) -> Set<String>? {
        guard version >= oldestBandVersion else { return nil }
        var ids = providerIDs
        for band in olderBands where version < band.below {
            ids.subtract(band.added)
            ids.formUnion(band.removed)
        }
        return ids
    }

    /// Whether Hermes can route `providerID`, or nil when Scarf has no table
    /// for this host (undetected, or older than v0.6) — callers then behave
    /// exactly as before.
    public static func isRoutable(
        _ providerID: String, capabilities: HermesCapabilities
    ) -> Bool? {
        guard capabilities.hasRoutableProviderTable, let version = capabilities.semver,
              let ids = providerIDs(for: version) else { return nil }
        return isRoutable(providerID, in: ids)
    }

    /// Lookup in the current band. Case-insensitive and trimmed, like
    /// `resolve_requested_provider` (`runtime_provider.py:482-486`).
    static func isRoutable(_ providerID: String) -> Bool {
        isRoutable(providerID, in: providerIDs)
    }

    /// `custom:<name>` always passes: it names a config entry Scarf doesn't
    /// validate here.
    static func isRoutable(_ providerID: String, in ids: Set<String>) -> Bool {
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return false }
        return id.hasPrefix("custom:") || ids.contains(id)
    }
}
