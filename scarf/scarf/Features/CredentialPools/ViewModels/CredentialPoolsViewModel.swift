import Foundation
import AppKit
import os

/// A single pooled credential for a provider (rotation entry).
struct HermesCredential: Identifiable, Sendable, Equatable {
    var id: String { "\(provider):\(index):\(internalID)" }
    let internalID: String      // Stable id from auth.json (e.g. "9f8d9b")
    let provider: String
    let index: Int              // 0-based index in the provider's pool
    let label: String           // Human label ("OPENROUTER_API_KEY")
    let authType: String        // "api_key" | "oauth"
    let source: String          // "env:OPENROUTER_API_KEY" | "gh_cli" | "file:..."
    let tokenTail: String       // Last 4 chars of the token — NEVER store full token in UI state
    let lastStatus: String      // "ok" | "cooldown" | "exhausted" | ""
    let requestCount: Int
}

/// Summary of one provider's pool with its rotation strategy.
struct HermesCredentialPool: Identifiable, Sendable {
    var id: String { provider }
    let provider: String
    let strategy: String        // "fill_first" | "round_robin" | "least_used" | "random"
    let credentials: [HermesCredential]
}

@Observable
@MainActor
final class CredentialPoolsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "CredentialPoolsViewModel")
    let context: ServerContext

    init(context: ServerContext = .local) {
        self.context = context
        self.oauthFlow = OAuthFlowController(context: context)
    }

    var pools: [HermesCredentialPool] = []
    var isLoading = false
    var message: String?

    /// Driver for the OAuth flow. Uses Process + pipes (not SwiftTerm) so we
    /// can extract the authorization URL, pop it open with an explicit button,
    /// and feed the code back via stdin. See OAuthFlowController for why we
    /// moved off the embedded-terminal approach.
    let oauthFlow: OAuthFlowController
    var oauthProvider: String = ""
    /// Convenience — the sheet keys a lot of UI off "is the flow running?".
    var oauthInProgress: Bool { oauthFlow.isRunning }

    let strategyOptions = ["fill_first", "round_robin", "least_used", "random"]

    /// Source of truth is `~/.hermes/auth.json`. Parsing box-drawn `hermes auth list`
    /// output is fragile — the JSON file is structured, stable, and already stores
    /// exactly the pool data the UI needs. We never display full tokens.
    ///
    /// Runs the file reads on a detached task so the synchronous SSH calls
    /// (which can block for hundreds of milliseconds even with ControlMaster
    /// multiplexing) don't freeze the main thread / spin the beach ball.
    func load() {
        isLoading = true
        let ctx = context
        Task.detached { [weak self] in
            let authData = ctx.readData(ctx.paths.authJSON)
            let yaml = ctx.readText(ctx.paths.configYAML) ?? ""
            let strategies = Self.parseStrategies(from: yaml)

            let decodedPools: [HermesCredentialPool]
            if let data = authData,
               let decoded = try? JSONDecoder().decode(AuthFile.self, from: data) {
                decodedPools = Self.buildPools(from: decoded, strategies: strategies)
            } else {
                decodedPools = []
            }

            await MainActor.run { [weak self] in
                self?.pools = decodedPools
                self?.isLoading = false
            }
        }
    }

    /// The `credential_pool_strategies:` map lives in config.yaml as `<provider>: <strategy>`.
    /// Pure-function form so it's safe to call from the detached load task.
    nonisolated private static func parseStrategies(from yaml: String) -> [String: String] {
        guard !yaml.isEmpty else { return [:] }
        let parsed = HermesFileService.parseNestedYAML(yaml)
        return parsed.maps["credential_pool_strategies"] ?? [:]
    }

    nonisolated private static func buildPools(from auth: AuthFile, strategies: [String: String]) -> [HermesCredentialPool] {
        auth.credential_pool.keys.sorted().map { provider in
            let entries = auth.credential_pool[provider] ?? []
            let creds = entries.enumerated().map { index, entry in
                HermesCredential(
                    internalID: entry.id ?? "",
                    provider: provider,
                    index: index,
                    label: entry.label ?? entry.source ?? "",
                    authType: entry.auth_type ?? "",
                    source: entry.source ?? "",
                    tokenTail: Self.tail(of: entry.access_token ?? ""),
                    lastStatus: entry.last_status ?? "",
                    requestCount: entry.request_count ?? 0
                )
            }
            return HermesCredentialPool(
                provider: provider,
                strategy: strategies[provider] ?? "fill_first",
                credentials: creds
            )
        }
    }

    /// Return last 4 chars prefixed with "…", or "" if the token is too short.
    /// Callers MUST NOT pass the full token anywhere user-visible beyond this.
    nonisolated private static func tail(of token: String) -> String {
        guard token.count >= 4 else { return "" }
        return "…" + String(token.suffix(4))
    }

    // MARK: - Mutations (all routed through the hermes CLI so hermes stays authoritative)

    func setStrategy(_ strategy: String, for provider: String) {
        let result = runHermes(["config", "set", "credential_pool_strategies.\(provider)", strategy])
        if result.exitCode == 0 {
            message = "Strategy updated for \(provider)"
            load()
        } else {
            message = "Failed to update strategy"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.message = nil
        }
    }

    /// Add an API-key credential to a provider's pool. Runs non-interactively.
    ///
    /// **Critical:** we must pass `--type api-key` in addition to `--api-key`.
    /// Without `--type`, hermes falls back to the provider's default (OAuth for
    /// Anthropic, etc.) and launches the browser flow even though the user
    /// just gave us a key.
    func addAPIKey(provider: String, apiKey: String, label: String) {
        var args = ["auth", "add", provider, "--type", "api-key", "--api-key", apiKey]
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        if !trimmedLabel.isEmpty {
            args += ["--label", trimmedLabel]
        }
        let result = runHermes(args)
        if result.exitCode == 0 {
            message = "Credential added"
            load()
        } else {
            logger.warning("Add credential failed: \(result.output)")
            message = "Add failed: \(result.output.prefix(160))"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }

    /// Kick off the OAuth flow. Uses OAuthFlowController (Process + pipes) so
    /// we can detect the authorization URL from hermes's output, open the
    /// browser ourselves, and feed the code back via stdin — avoiding the
    /// subprocess-can't-open-browser problem SwiftTerm had.
    func startOAuth(provider: String, label: String) {
        guard !provider.isEmpty else { return }
        oauthProvider = provider

        oauthFlow.onExit = { [weak self] _ in
            guard let self else { return }
            self.message = self.oauthFlow.succeeded
                ? "OAuth login succeeded"
                : (self.oauthFlow.errorMessage ?? "OAuth login failed or cancelled")
            // Reload regardless — hermes may have written a partial credential
            // even on a soft failure, and we want the list to reflect truth.
            self.load()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.message = nil
            }
        }

        oauthFlow.start(provider: provider, label: label)
    }

    /// Submit the authorization code the user pasted into the form's text
    /// field. Writes it to hermes's stdin.
    func submitOAuthCode(_ code: String) {
        oauthFlow.submitCode(code)
    }

    /// Cancel an in-progress OAuth attempt (e.g., user closed the sheet).
    func cancelOAuth() {
        oauthFlow.stop()
    }

    func removeCredential(provider: String, index: Int) {
        // The CLI uses 1-based indexing ("#1", "#2" in `hermes auth list`); our
        // stored `index` is 0-based, so add 1 when handing to the CLI.
        let result = runHermes(["auth", "remove", provider, String(index + 1)])
        if result.exitCode == 0 {
            message = "Credential removed"
            load()
        } else {
            message = "Remove failed"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.message = nil
        }
    }

    func resetProvider(_ provider: String) {
        let result = runHermes(["auth", "reset", provider])
        message = result.exitCode == 0 ? "Cooldowns cleared for \(provider)" : "Reset failed"
        load()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.message = nil
        }
    }

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        context.runHermes(arguments)
    }
}

// MARK: - auth.json decoding
// Shape verified against a real `~/.hermes/auth.json` — see sample in plan notes.
// All fields are optional because the format evolves and we want decoding to
// succeed even if hermes adds new keys or omits some for certain auth types.

// Hand-written `init(from:)` so Swift 6 doesn't synthesize a MainActor-
// isolated conformance — auth.json decode runs in `load()`'s detached task.
private struct AuthFile: Decodable, Sendable {
    nonisolated let credential_pool: [String: [AuthEntry]]

    enum CodingKeys: String, CodingKey { case credential_pool }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.credential_pool = try c.decode([String: [AuthEntry]].self, forKey: .credential_pool)
    }
}

private struct AuthEntry: Decodable, Sendable {
    nonisolated let id: String?
    nonisolated let label: String?
    nonisolated let auth_type: String?
    nonisolated let source: String?
    nonisolated let access_token: String?
    nonisolated let last_status: String?
    nonisolated let request_count: Int?

    enum CodingKeys: String, CodingKey {
        case id, label, auth_type, source, access_token, last_status, request_count
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id            = try c.decodeIfPresent(String.self, forKey: .id)
        self.label         = try c.decodeIfPresent(String.self, forKey: .label)
        self.auth_type     = try c.decodeIfPresent(String.self, forKey: .auth_type)
        self.source        = try c.decodeIfPresent(String.self, forKey: .source)
        self.access_token  = try c.decodeIfPresent(String.self, forKey: .access_token)
        self.last_status   = try c.decodeIfPresent(String.self, forKey: .last_status)
        self.request_count = try c.decodeIfPresent(Int.self, forKey: .request_count)
    }
}
