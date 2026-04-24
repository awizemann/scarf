import Testing
import Foundation
@testable import scarf

/// Tests that ``CredentialPoolsOAuthGate`` steers each known provider to
/// the right OAuth flow. The regression this prevents: a user hitting the
/// "Start OAuth" button for nous / openai-codex / qwen-oauth /
/// google-gemini-cli / copilot-acp and watching the UI stall silently.
@Suite struct CredentialPoolsGatingTests {

    /// Synthesize a ModelCatalogService over a minimal fixture cache so
    /// tests don't depend on the live `~/.hermes/models_dev_cache.json`.
    private func makeCatalog() throws -> ModelCatalogService {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-cpgate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("models_dev_cache.json").path
        // Include anthropic so the .ok path has a recognizable provider.
        let json = """
        {
          "anthropic": {
            "name": "Anthropic",
            "models": { "claude-sonnet-4-5": { "name": "Claude Sonnet 4.5" } }
          }
        }
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return ModelCatalogService(path: path)
    }

    @Test func nousRoutesToDedicatedSignInFlow() throws {
        let catalog = try makeCatalog()
        #expect(CredentialPoolsOAuthGate.resolve(providerID: "nous", catalog: catalog) == .useNousSignIn)
        // Whitespace + case insensitivity should also work — users who type
        // "Nous " shouldn't fall through to the generic flow.
        #expect(CredentialPoolsOAuthGate.resolve(providerID: "  Nous  ", catalog: catalog) == .useNousSignIn)
    }

    @Test func deviceCodeAndExternalProvidersRouteToCLI() throws {
        let catalog = try makeCatalog()
        // `openai-codex` is .oauthExternal in the overlay table.
        if case .useCLI(let provider) = CredentialPoolsOAuthGate.resolve(providerID: "openai-codex", catalog: catalog) {
            #expect(provider == "openai-codex")
        } else {
            Issue.record("openai-codex should route to .useCLI")
        }
        // `qwen-oauth` is .oauthExternal.
        if case .useCLI = CredentialPoolsOAuthGate.resolve(providerID: "qwen-oauth", catalog: catalog) {
            // ok
        } else {
            Issue.record("qwen-oauth should route to .useCLI")
        }
        // `google-gemini-cli` is .oauthExternal.
        if case .useCLI = CredentialPoolsOAuthGate.resolve(providerID: "google-gemini-cli", catalog: catalog) {
            // ok
        } else {
            Issue.record("google-gemini-cli should route to .useCLI")
        }
        // `copilot-acp` is .externalProcess.
        if case .useCLI = CredentialPoolsOAuthGate.resolve(providerID: "copilot-acp", catalog: catalog) {
            // ok
        } else {
            Issue.record("copilot-acp should route to .useCLI")
        }
    }

    @Test func pkceProvidersPassThroughAsOK() throws {
        let catalog = try makeCatalog()
        // Anthropic is a standard PKCE provider in Hermes — must not be gated.
        #expect(CredentialPoolsOAuthGate.resolve(providerID: "anthropic", catalog: catalog) == .ok)
    }

    @Test func unknownProvidersDefaultToOK() throws {
        let catalog = try makeCatalog()
        // Providers we don't know about shouldn't be blocked — users with
        // custom setups need the escape hatch.
        #expect(CredentialPoolsOAuthGate.resolve(providerID: "custom-provider-xyz", catalog: catalog) == .ok)
    }

    @Test func emptyProviderReturnsProviderEmpty() throws {
        let catalog = try makeCatalog()
        #expect(CredentialPoolsOAuthGate.resolve(providerID: "", catalog: catalog) == .providerEmpty)
        #expect(CredentialPoolsOAuthGate.resolve(providerID: "   ", catalog: catalog) == .providerEmpty)
    }
}
