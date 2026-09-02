import Foundation
import ScarfCore
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
    /// OAuth access-token expiry. Populated from `expires_at_ms` (epoch ms,
    /// preferred) or `expires_at` (ISO8601). Nil for API-key entries and
    /// for OAuth providers that haven't yet recorded an expiry.
    let expiresAt: Date?
    /// When the current Nous agent key was minted — surfaced so users can
    /// tell whether a recent rotation has gone through. Nil for non-Nous
    /// providers and for older Nous entries without the field.
    let agentKeyObtainedAt: Date?

    /// Display-time badge for expiry. Recomputed against `Date()` on each
    /// render so the label stays current without needing a timer.
    enum ExpiryBadge: Equatable {
        case expired
        case expiringSoon(days: Int)
    }

    /// Returns a badge when expiry is within 7 days or already past. Nil
    /// means "not worth flagging" — either expiry is unknown or still far
    /// enough out that a warning would be noise.
    func expiryBadge(now: Date = Date()) -> ExpiryBadge? {
        guard let expiresAt else { return nil }
        if expiresAt <= now { return .expired }
        let seconds = expiresAt.timeIntervalSince(now)
        let days = Int(seconds / 86_400)
        if days <= 7 { return .expiringSoon(days: max(1, days)) }
        return nil
    }
}

/// Summary of one provider's pool with its rotation strategy.
struct HermesCredentialPool: Identifiable, Sendable {
    var id: String { provider }
    let provider: String
    let strategy: String        // "fill_first" | "round_robin" | "least_used" | "random"
    let credentials: [HermesCredential]
}

/// OAuth-authed provider parsed from `auth.json.providers.<name>`. Distinct
/// from `HermesCredentialPool` because OAuth providers don't pool — one
/// active token per provider, refresh handled by Hermes. Nous, Spotify,
/// GitHub Copilot ACP, Qwen, Gemini all land here.
struct HermesOAuthProvider: Identifiable, Sendable, Equatable {
    var id: String { provider }
    let provider: String         // "nous" | "spotify" | ...
    let tokenTail: String        // last 4 of access_token, never the full token
    let hasAccessToken: Bool
    let hasRefreshToken: Bool
    let expiresAt: Date?
    let portalURL: String?       // "portal_base_url" — Nous-specific but generic-shaped
    let updatedAt: Date?
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
    /// OAuth-authed providers from `auth.json.providers.<name>` (Nous,
    /// Spotify, etc.). These have a different shape from `credential_pool`
    /// entries — one access token per provider, no rotation strategy —
    /// so they render in a parallel section rather than as a single-entry
    /// pool. Without this, OAuth providers were invisible in the UI even
    /// after a successful sign-in.
    var oauthProviders: [HermesOAuthProvider] = []
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

            // OAuth providers are a parallel surface — different shape, so
            // we parse via `JSONSerialization` instead of folding into the
            // strict `AuthFile` decoder. A malformed `providers` block is
            // a non-fatal shrug: empty list, no banner.
            let oauth = Self.parseOAuthProviders(from: authData)

            await MainActor.run { [weak self] in
                self?.pools = decodedPools
                self?.oauthProviders = oauth
                self?.isLoading = false
            }
        }
    }

    /// Pull `providers.<name>` entries out of `auth.json` and shape them
    /// for the UI. Returns an empty array when the file is missing,
    /// unparseable, or has no `providers` key.
    nonisolated private static func parseOAuthProviders(from data: Data?) -> [HermesOAuthProvider] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any]
        else { return [] }

        return providers.keys.sorted().compactMap { name in
            guard let entry = providers[name] as? [String: Any] else { return nil }
            let access = entry["access_token"] as? String ?? ""
            let refresh = entry["refresh_token"] as? String ?? ""
            // Worth surfacing if there's ANY token shape — pre-mint
            // refresh-only entries shouldn't be hidden.
            guard !access.isEmpty || !refresh.isEmpty else { return nil }

            let expiresAt: Date? = {
                if let ms = entry["expires_at_ms"] as? Double, ms > 0 {
                    return Date(timeIntervalSince1970: ms / 1000.0)
                }
                if let secs = entry["expires_at"] as? Double, secs > 0 {
                    // Hermes' Nous flow writes epoch seconds as a Double here.
                    return Date(timeIntervalSince1970: secs)
                }
                if let iso = entry["expires_at"] as? String {
                    return Self.parseISO8601(iso)
                }
                return nil
            }()

            let updatedAt: Date? = {
                if let iso = entry["obtained_at"] as? String {
                    return Self.parseISO8601(iso)
                }
                return nil
            }()

            return HermesOAuthProvider(
                provider: name,
                tokenTail: Self.tail(of: access.isEmpty ? refresh : access),
                hasAccessToken: !access.isEmpty,
                hasRefreshToken: !refresh.isEmpty,
                expiresAt: expiresAt,
                portalURL: entry["portal_base_url"] as? String,
                updatedAt: updatedAt
            )
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
                    requestCount: entry.request_count ?? 0,
                    expiresAt: Self.resolveExpiry(msField: entry.expires_at_ms, isoField: entry.expires_at),
                    agentKeyObtainedAt: Self.parseISO8601(entry.agent_key_obtained_at)
                )
            }
            return HermesCredentialPool(
                provider: provider,
                strategy: strategies[provider] ?? "fill_first",
                credentials: creds
            )
        }
    }

    /// Prefer `expires_at_ms` (integer epoch ms — unambiguous) over
    /// `expires_at` (ISO8601 string). Hermes writes whichever format the
    /// upstream provider returned; new entries almost always carry the ms
    /// form, older Nous entries may only have the ISO form.
    nonisolated private static func resolveExpiry(msField: Double?, isoField: String?) -> Date? {
        if let ms = msField, ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000.0)
        }
        return parseISO8601(isoField)
    }

    nonisolated private static func parseISO8601(_ str: String?) -> Date? {
        guard let s = str, !s.isEmpty else { return nil }
        // Fractional seconds are present on Nous tokens; plain seconds on
        // most OAuth providers. Try the fractional parser first, fall back
        // to the strict one.
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// Return last 4 chars prefixed with "…", or "" if the token is too short.
    /// Callers MUST NOT pass the full token anywhere user-visible beyond this.
    nonisolated private static func tail(of token: String) -> String {
        guard token.count >= 4 else { return "" }
        return "…" + String(token.suffix(4))
    }

    // MARK: - Mutations (all routed through the hermes CLI so hermes stays authoritative)

    func setStrategy(_ strategy: String, for provider: String) {
        // Defensive: `provider` is normally a fixed Hermes provider id with
        // no dot, but interpolating it unescaped into a dotted config key
        // would corrupt config.yaml on any host if that ever changes (or a
        // custom-provider name with a dot reaches this call). Same shared
        // helper as the quick-commands writer — see ConfigDottedKeySegment.
        let caps = HermesVersionCache.shared.cached(for: context) ?? .empty
        let sanitizedProvider = ConfigDottedKeySegment.escaped(provider, capabilities: caps)
        let result = runHermes(["config", "set", "credential_pool_strategies.\(sanitizedProvider)", strategy])
        if result.exitCode == 0 {
            message = "Strategy updated for \(provider)"
            load()
        } else {
            // Shared `hermes config set` failure builder — surfaces the
            // CLI's own reason rather than a generic string.
            message = SettingsViewModel.saveFailureMessage(
                key: "credential_pool_strategies.\(sanitizedProvider)",
                output: result.output
            )
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
    ///
    /// **Why the key stays in argv.** The audit proposed dropping
    /// `--api-key` and feeding the value to the CLI's prompt over stdin, to
    /// keep the secret out of a remote `/proc/<pid>/cmdline`. Checked
    /// against Hermes v2026.8.31 and it does not hold: with `--api-key`
    /// absent, `auth_commands.py` calls `masked_secret_prompt`, which for a
    /// non-tty stdin falls through to `getpass.getpass` — and getpass reads
    /// **`/dev/tty`**, not stdin, whenever a controlling terminal exists.
    /// Scarf launched from a terminal inherits one, so a piped key would be
    /// ignored and the command would block on the tty until the timeout.
    /// Keeping argv is the deliberate choice: a wedged credential dialog is
    /// a certainty, the /proc read needs an already-present local attacker
    /// on the host. Revisit if the CLI grows `--api-key-stdin`.
    /// The provider id and the key itself are trimmed of surrounding
    /// WHITESPACE AND NEWLINES here rather than at the call site: a key
    /// pasted from a provider dashboard or a `cat`-ed file routinely carries
    /// a trailing newline, and the Add button's own `.disabled` check only
    /// trimmed `.whitespaces` (which excludes `\n`), so a newline-only field
    /// still armed the button and the newline went straight into argv —
    /// Hermes then stored a credential that fails every request with an
    /// opaque 401. Trimming in the VM covers every present and future caller.
    func addAPIKey(provider: String, apiKey: String, label: String) {
        let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !apiKey.isEmpty else {
            message = "Provider and API key are required"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.message = nil
            }
            return
        }
        var args = ["auth", "add", provider, "--type", "api-key", "--api-key", apiKey]
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Remove an OAuth provider from `auth.json`. Maps to
    /// `hermes auth logout <provider>` — Hermes' canonical verb for
    /// dropping the access + refresh token entries from
    /// `providers.<name>` while leaving the upstream account intact.
    /// User-initiated; the credential pool view's trash button on
    /// each OAuth row routes here after a confirmation dialog.
    func removeOAuthProvider(_ provider: String) {
        let result = runHermes(["auth", "logout", provider])
        if result.exitCode == 0 {
            message = "Removed OAuth provider \(provider)"
            load()
        } else {
            // Surface the first output line in the toast so the user
            // can tell whether the verb is missing on this Hermes
            // version (older builds may not have `auth logout`) vs.
            // an actual failure. `runHermes` returns combined output
            // (stdout + stderr) in `output`; first non-empty line is
            // the most useful tail.
            let detail = result.output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? "exit \(result.exitCode)"
            message = "Remove failed: \(detail)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
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
    /// Epoch milliseconds. Double (not Int64) because some Nous entries
    /// round-trip through JS and end up as `1780339200000.0`. Decoding as
    /// Int would throw on the fractional zero.
    nonisolated let expires_at_ms: Double?
    /// ISO8601 — fallback when `expires_at_ms` isn't present.
    nonisolated let expires_at: String?
    /// Nous-specific — when the current agent key was issued. Surfaced as
    /// "Agent key rotated Nh ago" so the user can tell if a recent manual
    /// rotation has taken effect.
    nonisolated let agent_key_obtained_at: String?

    enum CodingKeys: String, CodingKey {
        case id, label, auth_type, source, access_token, last_status, request_count
        case expires_at_ms, expires_at, agent_key_obtained_at
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
        self.expires_at_ms = try c.decodeIfPresent(Double.self, forKey: .expires_at_ms)
        self.expires_at    = try c.decodeIfPresent(String.self, forKey: .expires_at)
        self.agent_key_obtained_at = try c.decodeIfPresent(String.self, forKey: .agent_key_obtained_at)
    }
}
