import Testing
import Foundation
@testable import ScarfCore

/// S15-F4: the chat's "No AI provider credentials detected" hint follows
/// Hermes' own `_has_any_provider_configured` (`hermes_cli/main.py:1052` @
/// v2026.9.24) instead of an 11-key hand list.
///
/// The `.env` cases below were also run through Hermes' own
/// `_dotenv_has_provider_key` from the tagged source, with the same verdicts.
@Suite struct HermesProviderCredentialsTests {

    @Test func tableIsHermesProviderEnvVars() {
        let vars = Set(HermesProviderCredentials.providerEnvVars)
        #expect(vars.count == HermesProviderCredentials.providerEnvVars.count, "no duplicates")
        #expect(vars.count == 54, "the v2026.9.24 set; re-derive it when Hermes adds providers")
        // The providers the audit found missing from the old list.
        for key in ["DEEPSEEK_API_KEY", "KIMI_API_KEY", "ZAI_API_KEY", "GLM_API_KEY",
                    "MINIMAX_API_KEY", "HF_TOKEN", "NVIDIA_API_KEY", "DASHSCOPE_API_KEY",
                    "COPILOT_GITHUB_TOKEN", "AI_GATEWAY_API_KEY", "KILOCODE_API_KEY"] {
            #expect(vars.contains(key), "\(key)")
        }
        // Hermes counts a bare OPENAI_BASE_URL (keyless vLLM / llama.cpp).
        #expect(vars.contains("OPENAI_BASE_URL"))
        // Not Hermes providers at this tag.
        #expect(!vars.contains("GROQ_API_KEY"))
        #expect(!vars.contains("MISTRAL_API_KEY"))
    }

    @Test(arguments: [
        ("DEEPSEEK_API_KEY=sk-live", true),
        ("export KIMI_API_KEY=\"abc\"", true),
        ("  MINIMAX_API_KEY = 'abc'  ", true),
        ("OPENAI_BASE_URL=http://127.0.0.1:8000/v1", true),
        ("DEEPSEEK_API_KEY=", false),
        ("DEEPSEEK_API_KEY=\"\"", false),
        ("# DEEPSEEK_API_KEY=sk-live", false),
        ("GROQ_API_KEY=gsk", false),
        ("TELEGRAM_BOT_TOKEN=123:abc", false),
        ("DEEPSEEK_API_KEY", false),
    ])
    func dotEnvLine(line: String, expected: Bool) {
        #expect(HermesProviderCredentials.dotEnvHasProviderKey("# header\n\(line)\n") == expected)
    }

    @Test func dotEnvWithCRLFLineEndings() {
        #expect(HermesProviderCredentials.dotEnvHasProviderKey("FOO=1\r\nMINIMAX_API_KEY=k\r\n"))
    }

    @Test func environmentCheck() {
        #expect(HermesProviderCredentials.environmentHasProviderKey(["ZAI_API_KEY": "k"]))
        #expect(!HermesProviderCredentials.environmentHasProviderKey(["ZAI_API_KEY": ""]))
        #expect(!HermesProviderCredentials.environmentHasProviderKey(["PATH": "/usr/bin", "GROQ_API_KEY": "x"]))
    }

    @Test func keylessEndpoints() {
        // Keyless provider ids, and custom endpoints.
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "lmstudio", baseURL: ""))
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "Bedrock", baseURL: ""))
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "vertex", baseURL: " "))
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "custom:my-vllm", baseURL: ""))
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(
            provider: "custom", baseURL: "https://llm.example.com/v1"))
        // A local or private base_url under any provider id.
        for url in ["http://localhost:11434/v1", "http://127.0.0.1:8000/v1", "http://[::1]:1234/v1",
                    "http://192.168.1.20:1234/v1", "http://10.0.0.5/v1", "http://172.20.0.2:8080",
                    "http://gpu-box.local:8000/v1", "http://host.docker.internal:11434/v1",
                    "http://100.101.102.103:11434"] {
            #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "ollama", baseURL: url), "\(url)")
        }
        // Hermes' setup writes a PUBLIC base_url for keyed providers, so that
        // alone must not hide a missing key.
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(
            provider: "openrouter", baseURL: "https://openrouter.ai/api/v1"))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(
            provider: "deepseek", baseURL: "https://api.deepseek.com/v1"))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(
            provider: "openai-api", baseURL: "http://172.32.0.1/v1"))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(
            provider: "openai-api", baseURL: "https://fcbank.example/v1"))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "anthropic", baseURL: ""))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "unknown", baseURL: ""))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "custom", baseURL: ""))
    }

    /// GITHUB_TOKEN / GH_TOKEN / HF_TOKEN are everyday tokens; they count
    /// only for the provider they belong to.
    @Test func generalPurposeTokensCountOnlyForTheirProvider() {
        #expect(!HermesProviderCredentials.dotEnvHasProviderKey("GITHUB_TOKEN=ghp_real\n", provider: "anthropic"))
        #expect(!HermesProviderCredentials.dotEnvHasProviderKey("GITHUB_TOKEN=ghp_real\n"))
        #expect(HermesProviderCredentials.dotEnvHasProviderKey("GITHUB_TOKEN=ghp_real\n", provider: "copilot"))
        #expect(!HermesProviderCredentials.environmentHasProviderKey(["GH_TOKEN": "x", "HF_TOKEN": "y"], provider: "openrouter"))
        #expect(HermesProviderCredentials.environmentHasProviderKey(["HF_TOKEN": "y"], provider: "HuggingFace"))
        // COPILOT_GITHUB_TOKEN is Copilot-only by name, so it always counts.
        #expect(HermesProviderCredentials.environmentHasProviderKey(["COPILOT_GITHUB_TOKEN": "x"]))
    }
}
