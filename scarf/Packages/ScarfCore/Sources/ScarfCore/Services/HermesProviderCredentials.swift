import Foundation

/// The pieces of Hermes' own "is any provider configured?" check that Scarf
/// can evaluate from files, used by the chat's "No AI provider credentials
/// detected" hint.
///
/// Hermes answers the question in `_has_any_provider_configured`
/// (`hermes_cli/main.py:1052-1150` @ v2026.9.24). Its first test is "any
/// provider env var is set, in the process env or in `.env`", where the var
/// set is a fixed handful plus every `api_key_env_vars` entry of every
/// `api_key` row in `PROVIDER_REGISTRY` (`hermes_cli/auth.py:171-260`, plus
/// the provider plugins mirrored in by `sync_plugin_provider_registry`). The
/// hand-kept list Scarf used before named 11 of those 54 vars, so a DeepSeek,
/// Kimi, Z.AI, MiniMax or Hugging Face key in `.env` showed the banner even
/// though chat worked (S15-F4).
public enum HermesProviderCredentials {

    /// Every env var Hermes counts as "a provider is configured", as printed
    /// by running this against the tagged source (v2026.9.24, 0.21.5):
    ///
    ///     s = {"OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
    ///          "ANTHROPIC_TOKEN", "OPENAI_BASE_URL"}
    ///     for p in PROVIDER_REGISTRY.values():
    ///         if p.auth_type == "api_key": s.update(p.api_key_env_vars)
    ///
    /// `OPENAI_BASE_URL` is on the list on purpose: Hermes treats it alone as
    /// configured, because a local server (vLLM, llama.cpp) needs no key.
    /// When a new Hermes release adds a provider, re-run the snippet and
    /// update this list.
    public static let providerEnvVars: [String] = [
        "ACTUAL_API_KEY", "AI_GATEWAY_API_KEY", "ALIBABA_CODING_PLAN_API_KEY",
        "ALIBABA_CODING_PLAN_CN_API_KEY", "ALIBABA_TOKEN_PLAN_API_KEY",
        "ALIBABA_TOKEN_PLAN_CN_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN",
        "ARCEEAI_API_KEY", "AZURE_FOUNDRY_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
        "COMMANDCODE_API_KEY", "COPILOT_GITHUB_TOKEN", "DASHSCOPE_API_KEY",
        "DEEPINFRA_API_KEY", "DEEPSEEK_API_KEY", "FIREWORKS_API_KEY", "GEMINI_API_KEY",
        "GH_TOKEN", "GITHUB_TOKEN", "GLM_API_KEY", "GMI_API_KEY", "GOOGLE_API_KEY",
        "HF_TOKEN", "KILOCODE_API_KEY", "KIMI_API_KEY", "KIMI_CN_API_KEY",
        "KIMI_CODING_API_KEY", "LM_API_KEY", "META_API_KEY", "META_MODEL_API_KEY",
        "MINIMAX_API_KEY", "MINIMAX_CN_API_KEY", "MODEL_API_KEY", "NEBIUS_API_KEY",
        "NEBIUS_TOKEN_FACTORY_API_KEY", "NOVITA_API_KEY", "NVIDIA_API_KEY",
        "OLLAMA_API_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENCODE_GO_API_KEY",
        "OPENCODE_ZEN_API_KEY", "OPENROUTER_API_KEY", "RAMP_ROUTER_API_KEY",
        "ROUTER_API_KEY", "STEPFUN_API_KEY", "TOKENHUB_API_KEY", "TOKENPLAN_API_KEY",
        "UPSTAGE_API_KEY", "XAI_API_KEY", "XIAOMI_API_KEY", "ZAI_API_KEY", "Z_AI_API_KEY",
    ]

    private static let providerEnvVarSet = Set(providerEnvVars)

    /// Providers whose credentials are not an env var or an `auth.json`
    /// token, so a missing key says nothing about whether chat will work:
    /// AWS Bedrock (`aws_sdk`), Vertex (`vertex`, Google ADC), Copilot ACP
    /// (`external_process`), and LM Studio, which runs keyless and falls back
    /// to a no-auth placeholder (`hermes_cli/auth.py:2148` @ v2026.9.24).
    public static let keylessProviders: Set<String> = [
        "bedrock", "vertex", "copilot-acp", "lmstudio",
    ]

    /// True when `env` holds a non-empty value for any provider var.
    public static func environmentHasProviderKey(_ env: [String: String]) -> Bool {
        providerEnvVars.contains { !(env[$0] ?? "").isEmpty }
    }

    /// True when a `.env` file assigns a non-empty value to any provider var.
    /// Line for line the rule of Hermes' `_dotenv_has_provider_key`
    /// (`hermes_cli/main.py:1012-1030` @ v2026.9.24): skip comments, drop an
    /// `export ` prefix, split on the first `=`, and strip whitespace and
    /// quotes from the value.
    public static func dotEnvHasProviderKey(_ text: String) -> Bool {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || !line.contains("=") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if providerEnvVarSet.contains(key) && !value.isEmpty { return true }
        }
        return false
    }

    /// True when the main model points at an endpoint that needs no key
    /// Scarf can see: a `model.base_url` (Ollama, LM Studio, vLLM, llama.cpp
    /// or any custom endpoint — Hermes counts a `base_url` as configured,
    /// `hermes_cli/main.py:1107-1112`), a named custom provider
    /// (`custom:<name>`, whose endpoint lives in config), or one of
    /// ``keylessProviders``.
    public static func modelUsesKeylessEndpoint(provider: String, baseURL: String) -> Bool {
        if !baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let id = provider.trimmingCharacters(in: .whitespaces).lowercased()
        if id.hasPrefix("custom:") { return true }
        return keylessProviders.contains(id)
    }
}
