import Foundation

/// `hermes webhook subscribe --signature` choices
/// (`hermes_cli/subcommands/webhook.py:31` @ v0.23.4). New routes default to
/// `generic` (`_route_signature`, `hermes_cli/webhook.py:180` @ v0.23.4).
public enum HermesWebhookSignature: String, CaseIterable, Sendable, Identifiable {
    case generic, github, gitlab, linear
    public var id: String { rawValue }
}

/// Argv builder + create-output parsing for `hermes webhook subscribe`.
public enum HermesWebhookSubscribe {

    /// File the CLI persists routes (and their full HMAC secrets) to:
    /// `_SUBSCRIPTIONS_FILENAME` under `get_hermes_home()`
    /// (`hermes_cli/webhook.py:21,32-34` @ v0.23.4).
    public static let subscriptionsFilename = "webhook_subscriptions.json"

    public nonisolated static func subscriptionsPath(home: String) -> String {
        (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/" + subscriptionsFilename
    }

    /// Build the argv. `signature` is passed ONLY when `capabilities.hasWebhookSignatureOption`
    /// — pre-v0.23.2 argparse has no `--signature`, so older hosts get the exact argv they always did.
    public nonisolated static func argv(
        name: String, prompt: String, events: String, description: String, skills: String,
        deliver: String, chatID: String, secret: String,
        signature: HermesWebhookSignature?, capabilities: HermesCapabilities
    ) -> [String] {
        var args = ["webhook", "subscribe"]
        if !prompt.isEmpty { args += ["--prompt", prompt] }
        if !events.isEmpty { args += ["--events", events] }
        if !description.isEmpty { args += ["--description", description] }
        if !skills.isEmpty { args += ["--skills", skills] }
        if !deliver.isEmpty { args += ["--deliver", deliver] }
        if !chatID.isEmpty { args += ["--deliver-chat-id", chatID] }
        if !secret.isEmpty { args += ["--secret", secret] }
        if capabilities.hasWebhookSignatureOption, let signature {
            args += ["--signature", signature.rawValue]
        }
        args += ["--", name]
        return args
    }

    /// What the `Secret:` line carried.
    public enum PrintedSecret: Sendable, Equatable {
        /// Pre-v0.23.2: the full value.
        case plain(String)
        /// v0.23.2+: `Secret: <mask_secret> (full value in <home>/webhook_subscriptions.json)`
        /// (`hermes_cli/webhook.py:325` @ v0.23.4). Payload is the display path the CLI printed.
        case masked(displayPath: String)
    }

    public struct Created: Sendable, Equatable {
        public let url: String
        public let secret: PrintedSecret
    }

    /// Parse `URL:` / `Secret:` from the create output; `nil` when no `Secret:` line
    /// (every failure path prints none). Detection of the masked form is by its
    /// `(full value in …)` suffix, not by host version.
    public nonisolated static func parseCreated(_ output: String) -> Created? {
        var secretLine = ""
        var url = ""
        for raw in output.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if secretLine.isEmpty, trimmed.hasPrefix("Secret:") {
                secretLine = String(trimmed.dropFirst("Secret:".count)).trimmingCharacters(in: .whitespaces)
            } else if url.isEmpty, trimmed.hasPrefix("URL:") {
                url = String(trimmed.dropFirst("URL:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !secretLine.isEmpty else { return nil }
        if let open = secretLine.range(of: "(full value in "), secretLine.hasSuffix(")") {
            let path = secretLine[open.upperBound..<secretLine.index(before: secretLine.endIndex)]
            return Created(url: url, secret: .masked(displayPath: String(path)))
        }
        return Created(url: url, secret: .plain(secretLine))
    }

    /// Read route `name`'s `secret` from the subscriptions file contents — a JSON
    /// object of name → route dict, each route carrying `"secret"`
    /// (`_save_subscriptions_unlocked` / `route = {… "secret": secret …}`,
    /// `hermes_cli/webhook.py:70-73,267-270` @ v0.23.4). `nil` on any mismatch.
    public nonisolated static func secret(fromSubscriptionsJSON data: Data, name: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = obj[name] as? [String: Any],
              let secret = route["secret"] as? String, !secret.isEmpty
        else { return nil }
        return secret
    }

    public enum ResolvedSecret: Sendable, Equatable {
        case value(String)
        /// Masked on stdout and the subscriptions file couldn't be read/decoded.
        case unreadable(path: String)
    }

    /// Plain → as printed. Masked → read `subscriptionsPath` (through the server's
    /// transport, via `readData`) and pull route `name`'s secret; on any failure
    /// report the path instead of the mask. The secret is never logged here.
    public nonisolated static func resolveSecret(
        _ printed: PrintedSecret, name: String, subscriptionsPath: String,
        readData: (String) -> Data?
    ) -> ResolvedSecret {
        switch printed {
        case .plain(let secret):
            return .value(secret)
        case .masked(let displayPath):
            if !subscriptionsPath.isEmpty, let data = readData(subscriptionsPath),
               let secret = secret(fromSubscriptionsJSON: data, name: name) {
                return .value(secret)
            }
            return .unreadable(path: subscriptionsPath.isEmpty ? displayPath : subscriptionsPath)
        }
    }
}
