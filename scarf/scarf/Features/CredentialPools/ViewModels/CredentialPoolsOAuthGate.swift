import Foundation

/// Describes whether Credential Pools' generic OAuth flow
/// (``OAuthFlowController``) can handle a given provider.
///
/// Hermes supports four OAuth styles, and only **PKCE** is driven by the
/// generic controller:
///
/// | Style | Works via `OAuthFlowController`? | Example providers |
/// |---|---|---|
/// | PKCE | ✅ Yes | anthropic, github-copilot |
/// | Device-code | ❌ No — stalls silently | nous |
/// | External OAuth | ❌ No — needs a terminal | openai-codex, qwen-oauth, google-gemini-cli |
/// | External process | ❌ No — uses an agent bridge | copilot-acp |
///
/// Routing a non-PKCE provider through the generic controller silently
/// fails: the PKCE URL regex in ``OAuthFlowController/extractAuthURL`` only
/// matches `client_id=…&redirect_uri=…` -shaped strings, and nothing else
/// hermes prints for the other styles matches that. This gate closes the
/// dead end by steering the user to the right flow for each style.
///
/// `.ok` is the default for unknown providers so existing PKCE-based
/// flows (anthropic, etc.) keep working — this gate is strictly additive.
enum CredentialPoolsOAuthGate: Equatable {
    /// The standard PKCE flow works for this provider — show the normal
    /// "Start OAuth" button and let ``OAuthFlowController`` handle it.
    case ok
    /// User hasn't typed a provider ID yet. Disable the button.
    case providerEmpty
    /// Route Nous Portal through ``NousSignInSheet`` instead of the
    /// generic flow, since Nous uses device-code.
    case useNousSignIn
    /// Hermes knows how to sign in to this provider but Scarf doesn't yet
    /// have a dedicated UI for it. Point the user to `hermes auth add
    /// <provider>` in a terminal.
    case useCLI(provider: String)

    /// Compute the gate for a typed provider ID. Consults the Hermes
    /// overlay table via ``ModelCatalogService/overlayMetadata(for:)`` to
    /// decide which OAuth style applies.
    static func resolve(providerID rawID: String, catalog: ModelCatalogService) -> CredentialPoolsOAuthGate {
        let id = rawID.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty else { return .providerEmpty }
        if id == "nous" { return .useNousSignIn }
        switch catalog.overlayMetadata(for: id)?.authType {
        case .oauthDeviceCode, .oauthExternal, .externalProcess:
            return .useCLI(provider: id)
        default:
            return .ok
        }
    }
}
