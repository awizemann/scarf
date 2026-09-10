import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Tests that ``CredentialPoolsOAuthGate`` steers each known provider to
/// the right OAuth flow. The regression this prevents: a user hitting the
/// "Start OAuth" button for nous / openai-codex / qwen-oauth /
/// copilot-acp and watching the UI stall silently.
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
        // `moa` is .virtual (v0.18) — no credentials at all, so it must
        // NOT route to the CLI gate. (google-gemini-cli, the old
        // .oauthExternal case here, was removed in Hermes v0.18.)
        #expect(CredentialPoolsOAuthGate.resolve(providerID: "moa", catalog: catalog) == .ok)
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

/// v0.21.1 pool administration argv. The contract worth pinning is the two
/// index bases inside one command: `hermes auth priority` resolves its
/// `target` 1-based (`CredentialPool.resolve_target` enumerates from 1, like
/// `auth remove`) while `priority` is 0-based ("0 = tried first"). Scarf
/// stores a 0-based index, so exactly one of the two gets +1.
@Suite struct CredentialPoolsAdminArgvTests {

    @MainActor
    @Test func priorityArgvSendsOneBasedTargetAndZeroBasedDestination() {
        // Second credential in the pool (index 1) promoted to the front.
        #expect(CredentialPoolsViewModel.priorityArgv(provider: "openrouter", index: 1, to: 0)
                == ["auth", "priority", "--", "openrouter", "2", "0"])
        // Move-down from the front: target #1, destination 1.
        #expect(CredentialPoolsViewModel.priorityArgv(provider: "anthropic", index: 0, to: 1)
                == ["auth", "priority", "--", "anthropic", "1", "1"])
    }

    @MainActor
    @Test func refreshAndResetTargetOneCredential() {
        #expect(CredentialPoolsViewModel.refreshArgv(provider: "nous", index: 2)
                == ["auth", "refresh", "--", "nous", "3"])
        // The target is what makes this a per-credential reset; without it
        // Hermes clears the whole pool.
        #expect(CredentialPoolsViewModel.resetCredentialArgv(provider: "nous", index: 0)
                == ["auth", "reset", "--", "nous", "1"])
        #expect(CredentialPoolsViewModel.resetCredentialArgv(provider: "nous", index: 0).count == 5)
    }

    // MARK: - Target encoding: stable id beats the numeric index

    /// Hermes resolves `<target>` id-first, then by unique LABEL, and only
    /// then as a 1-based index (`agent/credential_pool_admin.py:87`
    /// `resolve_target` at v2026.9.7 — `:94` id, `:97` label, `:106`
    /// `raw.isdigit()`). So a bare `"2"` lands on a credential LABELLED "2"
    /// whenever one exists, not on the second entry. Every mutation sends
    /// the stable auth.json id instead when Scarf has one.
    @MainActor
    @Test func argvSendsTheStableIDRatherThanACollidableIndex() {
        #expect(CredentialPoolsViewModel.credentialTarget(index: 1, internalID: "9f8d9b") == "9f8d9b")
        #expect(CredentialPoolsViewModel.priorityArgv(
            provider: "openrouter", index: 1, internalID: "9f8d9b", to: 0)
                == ["auth", "priority", "--", "openrouter", "9f8d9b", "0"])
        #expect(CredentialPoolsViewModel.refreshArgv(provider: "nous", index: 2, internalID: "a1b2c3")
                == ["auth", "refresh", "--", "nous", "a1b2c3"])
        #expect(CredentialPoolsViewModel.resetCredentialArgv(provider: "nous", index: 0, internalID: "a1b2c3")
                == ["auth", "reset", "--", "nous", "a1b2c3"])
        #expect(CredentialPoolsViewModel.removeArgv(provider: "nous", index: 0, internalID: "a1b2c3")
                == ["auth", "remove", "--", "nous", "a1b2c3"])
    }

    /// auth.json entries without an `id` still have to be addressable — the
    /// 1-based index stays the fallback, and whitespace-only is not an id.
    @MainActor
    @Test func argvFallsBackToTheOneBasedIndexWithoutAnID() {
        #expect(CredentialPoolsViewModel.credentialTarget(index: 0, internalID: "") == "1")
        #expect(CredentialPoolsViewModel.credentialTarget(index: 4, internalID: "   ") == "5")
        #expect(CredentialPoolsViewModel.removeArgv(provider: "nous", index: 1)
                == ["auth", "remove", "--", "nous", "2"])
    }
}
