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

    var pools: [HermesCredentialPool] = []
    var isLoading = false
    var message: String?

    /// Driver for the OAuth flow. Uses Process + pipes (not SwiftTerm) so we
    /// can extract the authorization URL, pop it open with an explicit button,
    /// and feed the code back via stdin. See OAuthFlowController for why we
    /// moved off the embedded-terminal approach.
    let oauthFlow = OAuthFlowController()
    var oauthProvider: String = ""
    /// Convenience — the sheet keys a lot of UI off "is the flow running?".
    var oauthInProgress: Bool { oauthFlow.isRunning }

    let strategyOptions = ["fill_first", "round_robin", "least_used", "random"]

    /// Source of truth is `~/.hermes/auth.json`. Parsing box-drawn `hermes auth list`
    /// output is fragile — the JSON file is structured, stable, and already stores
    /// exactly the pool data the UI needs. We never display full tokens.
    func load() {
        isLoading = true
        defer { isLoading = false }

        let authPath = HermesPaths.home + "/auth.json"
        let strategies = parseStrategies()

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)) else {
            pools = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode(AuthFile.self, from: data)
            pools = Self.buildPools(from: decoded, strategies: strategies)
        } catch {
            logger.error("Failed to decode auth.json: \(error.localizedDescription)")
            pools = []
        }
    }

    /// The `credential_pool_strategies:` map lives in config.yaml as `<provider>: <strategy>`.
    private func parseStrategies() -> [String: String] {
        guard let yaml = try? String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8) else { return [:] }
        let parsed = HermesFileService.parseNestedYAML(yaml)
        return parsed.maps["credential_pool_strategies"] ?? [:]
    }

    private static func buildPools(from auth: AuthFile, strategies: [String: String]) -> [HermesCredentialPool] {
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
    private static func tail(of token: String) -> String {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HermesPaths.hermesBinary)
        process.arguments = arguments
        process.environment = HermesFileService.enrichedEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
        } catch {
            return ("", -1)
        }
    }
}

// MARK: - auth.json decoding
// Shape verified against a real `~/.hermes/auth.json` — see sample in plan notes.
// All fields are optional because the format evolves and we want decoding to
// succeed even if hermes adds new keys or omits some for certain auth types.

private struct AuthFile: Decodable {
    let credential_pool: [String: [AuthEntry]]
}

private struct AuthEntry: Decodable {
    let id: String?
    let label: String?
    let auth_type: String?
    let source: String?
    let access_token: String?
    let last_status: String?
    let request_count: Int?
}
