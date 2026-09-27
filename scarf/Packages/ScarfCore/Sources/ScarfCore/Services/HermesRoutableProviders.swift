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
/// Generated from Hermes and kept honest by `scripts/check-hermes-tables.py`
/// lane 8 (FAILs both ways). Applies only on hosts with
/// ``HermesCapabilities/hasRoutableProviderTable``.
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

    /// Whether Hermes can route `providerID`, or nil when this host is not
    /// one the table was derived for (older or undetected) — callers then
    /// behave exactly as before.
    public static func isRoutable(
        _ providerID: String, capabilities: HermesCapabilities
    ) -> Bool? {
        guard capabilities.hasRoutableProviderTable else { return nil }
        return isRoutable(providerID)
    }

    /// Table lookup without the host gate. Case-insensitive and trimmed,
    /// like `resolve_requested_provider` (`runtime_provider.py:482-486`).
    static func isRoutable(_ providerID: String) -> Bool {
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return false }
        return id.hasPrefix("custom:") || providerIDs.contains(id)
    }
}
