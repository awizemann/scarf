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

    /// Provider vars that are also general-purpose tokens: a `GITHUB_TOKEN`
    /// for the GitHub tools or an `HF_TOKEN` for downloads sits in many
    /// shells and `.env` files without meaning the model provider is set up.
    /// Hermes lists them for its setup check, but never picks Copilot from
    /// the environment on its own (`_NO_AUTO_DETECT_PROVIDERS`,
    /// `hermes_cli/auth.py:1453` @ v2026.9.24), so they count for the hint
    /// only when the main model's provider is the one they belong to.
    public static let providerScopedVars: [String: String] = [
        "GH_TOKEN": "copilot", "GITHUB_TOKEN": "copilot", "HF_TOKEN": "huggingface",
    ]

    /// Whether `key` counts as a configured provider for a main model whose
    /// provider is `provider` (see ``providerScopedVars``).
    static func counts(_ key: String, provider: String?) -> Bool {
        guard providerEnvVarSet.contains(key) else { return false }
        guard let owner = providerScopedVars[key] else { return true }
        return provider?.trimmingCharacters(in: .whitespaces).lowercased() == owner
    }

    /// True when `env` holds a non-empty value for any provider var.
    /// `provider` is the main model's `model.provider`, if known.
    public static func environmentHasProviderKey(_ env: [String: String], provider: String? = nil) -> Bool {
        providerEnvVars.contains { counts($0, provider: provider) && !(env[$0] ?? "").isEmpty }
    }

    /// True when a `.env` file assigns a non-empty value to any provider var.
    /// Line for line the rule of Hermes' `_dotenv_has_provider_key`
    /// (`hermes_cli/main.py:1012-1030` @ v2026.9.24): skip comments, drop an
    /// `export ` prefix, split on the first `=`, and strip whitespace and
    /// quotes from the value. The one difference is ``providerScopedVars``.
    public static func dotEnvHasProviderKey(_ text: String, provider: String? = nil) -> Bool {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || !line.contains("=") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if counts(key, provider: provider) && !value.isEmpty { return true }
        }
        return false
    }

    /// True when the main model points at an endpoint that needs no key
    /// Scarf can see:
    /// - one of ``keylessProviders``;
    /// - a custom endpoint — `custom` with a `model.base_url`, or a named
    ///   `custom:<name>` provider, whose endpoint lives in config (Hermes
    ///   allows both without a key);
    /// - any provider whose `model.base_url` is on this machine or a private
    ///   network (Ollama, LM Studio, vLLM, llama.cpp under whatever id).
    ///
    /// A public `base_url` alone does NOT count: Hermes' setup writes one
    /// for nearly every provider (`hermes_cli/model_setup_flows.py:75,581`
    /// @ v2026.9.24), so treating it as keyless would hide the hint for an
    /// OpenRouter or DeepSeek user whose key is actually missing.
    public static func modelUsesKeylessEndpoint(provider: String, baseURL: String) -> Bool {
        let id = provider.trimmingCharacters(in: .whitespaces).lowercased()
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        if keylessProviders.contains(id) || id.hasPrefix("custom:") { return true }
        if id == "custom" && !url.isEmpty { return true }
        return isLocalOrPrivate(url)
    }

    /// True for a URL whose host is loopback, link-local, an RFC 1918
    /// private address, a `.local`/`.lan`/`.internal` name, or Docker's
    /// `host.docker.internal`.
    static func isLocalOrPrivate(_ urlString: String) -> Bool {
        guard !urlString.isEmpty,
              let host = URLComponents(string: urlString)?.host?.lowercased(),
              !host.isEmpty else { return false }
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" || h == "0.0.0.0" || h == "host.docker.internal" { return true }
        if h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".lan")
            || h.hasSuffix(".internal") || h.hasSuffix(".home.arpa") { return true }
        if h.contains(":") && (h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd")) { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // CGNAT / Tailscale
        default: return false
        }
    }
}
