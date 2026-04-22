import Foundation
import ScarfCore
import AppKit
import os

/// Shared helpers used by every per-platform setup view model.
///
/// Each platform form follows the same pattern:
/// 1. Load current values from `.env` + config.yaml into local `@Observable` state.
/// 2. Present them in a form where changes happen in-memory.
/// 3. On save, write env vars via `HermesEnvService.setMany` and config.yaml keys
///    via `hermes config set`, then surface a success/error toast.
///
/// Putting the save logic here keeps each per-platform VM focused on its own
/// field set without re-implementing the write plumbing 12 times.
@MainActor
enum PlatformSetupHelpers {
    static let logger = Logger(subsystem: "com.scarf", category: "PlatformSetup")

    /// Apply a form save in one atomic batch against a specific server.
    ///
    /// - `context`: the server whose `.env` and `config.yaml` we're writing.
    ///   Local goes through `LocalTransport`; remote rounds through ssh+scp.
    /// - `envPairs`: values to write into `.env`. Empty strings trigger `unset()`
    ///   (commenting the line out) rather than storing a literal empty value.
    /// - `configKV`: scalar config.yaml paths to set via `hermes config set`.
    ///   Empty strings still produce a `config set <key> ""` call because
    ///   some fields accept an explicit empty string (e.g., `display.skin: ""`).
    ///
    /// Returns a user-facing summary message.
    @discardableResult
    static func saveForm(context: ServerContext, envPairs: [String: String], configKV: [String: String]) -> String {
        let envService = HermesEnvService(context: context)

        // Split env pairs into set vs. unset.
        var toSet: [String: String] = [:]
        var toUnset: [String] = []
        for (k, v) in envPairs {
            if v.isEmpty {
                toUnset.append(k)
            } else {
                toSet[k] = v
            }
        }

        var envOK = true
        if !toSet.isEmpty {
            envOK = envService.setMany(toSet)
        }
        for key in toUnset {
            _ = envService.unset(key)
        }

        var configFailures: [String] = []
        for (key, value) in configKV {
            let result = runHermesCLI(context: context, args: ["config", "set", key, value])
            if result.exitCode != 0 {
                configFailures.append(key)
                logger.warning("hermes config set \(key) failed: \(result.output)")
            }
        }

        if !envOK { return "Failed to write .env" }
        if !configFailures.isEmpty { return "Saved, but failed to update: \(configFailures.joined(separator: ", "))" }
        return "Saved — restart gateway to apply"
    }

    /// Synchronous hermes CLI invocation against the given server. Use only
    /// for fast commands like `config set`; longer commands should use
    /// `HermesFileService.runHermesCLI` from a `Task.detached`.
    static func runHermesCLI(context: ServerContext, args: [String], timeout: TimeInterval = 15) -> (exitCode: Int32, output: String) {
        HermesFileService(context: context).runHermesCLI(args: args, timeout: timeout)
    }

    /// Ask the user's default browser to open a URL (typically a hermes doc page
    /// or a platform developer portal).
    static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Bool <-> "true"/"false" round-trip for env vars. Hermes accepts both
    /// "true"/"false" and "1"/"0"; we emit the string form for readability.
    static func envBool(_ on: Bool) -> String { on ? "true" : "false" }

    /// Parse an env string as a bool. Treats missing/empty as `false`.
    /// "true", "1", "yes", "on" (case-insensitive) are true.
    static func parseEnvBool(_ s: String?) -> Bool {
        guard let s else { return false }
        switch s.lowercased() {
        case "true", "1", "yes", "on": return true
        default: return false
        }
    }
}
