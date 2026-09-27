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
        ("  HF_TOKEN = 'hf_abc'  ", true),
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
        // Any base_url: Ollama, LM Studio, vLLM, a custom endpoint.
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(
            provider: "custom", baseURL: "http://localhost:11434/v1"))
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "custom:my-vllm", baseURL: ""))
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "lmstudio", baseURL: ""))
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "Bedrock", baseURL: ""))
        #expect(HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "vertex", baseURL: " "))
        // A keyed provider with no key is still "missing".
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "anthropic", baseURL: ""))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "unknown", baseURL: ""))
        #expect(!HermesProviderCredentials.modelUsesKeylessEndpoint(provider: "custom", baseURL: ""))
    }
}
