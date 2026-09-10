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
    nonisolated static let logger = Logger(subsystem: "com.scarf", category: "PlatformSetup")

    /// A save's user-facing result. See ``OutcomeMessage`` — the app-wide
    /// outcome-typed channel this and every other save bar now share
    /// (GW-F4). Kept as a nested alias so existing `saveForm` call sites
    /// read unchanged.
    typealias SaveOutcome = OutcomeMessage

    /// Read `.env` for a setup form, distinguishing "nothing is set yet"
    /// from "we couldn't read it" (GW-F6 / audit DI L10).
    ///
    /// Every platform form used to open on `HermesEnvService.load()`, whose
    /// `?? [:]` collapsed those two into an empty form. The fields then
    /// rendered blank over live values, and ``saveForm(context:envPairs:configKV:)``
    /// treats a blank field as an `unset` — so a Save on a form the user
    /// never touched commented out working credentials. The dictionary is
    /// unchanged on both healthy paths; the second element is the sentence
    /// the form puts in its (already outcome-typed, GW-F4) message bar when
    /// the fields it is about to show are not the file's contents.
    nonisolated static func loadEnv(context: ServerContext) -> (env: [String: String], failure: String?) {
        do {
            return (try HermesEnvService(context: context).loadProven(), nil)
        } catch {
            return ([:], error.localizedDescription)
        }
    }

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
    /// Returns a user-facing summary message and whether it is a failure.
    /// `nonisolated`: the body is pure transport I/O (env writes + one
    /// `hermes config set` process per key) and touches no MainActor state,
    /// so callers can — and now do — run it from a `Task.detached` instead of
    /// freezing the window for a round-trip per key.
    @discardableResult
    nonisolated static func saveForm(
        context: ServerContext,
        envPairs: [String: String],
        configKV: [String: String],
        runner: HermesCLIRunner? = nil
    ) -> SaveOutcome {
        let envService = HermesEnvService(context: context)
        // `runner` is the C10 test seam (see `HermesCLIRunner`): production
        // passes nil and gets the context's own spawn, a test passes a fake
        // that records `Thread.isMainThread`. The timeout stays this site's
        // own 15 s cap either way.
        let run = runner ?? context.cliRunner

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
            // The result is no longer decorative: `unset` returns `false` when
            // the guarded reader REFUSED (the .env is there and unreadable),
            // which means the key is still live in the file. Dropping that on
            // the floor would report "Saved" over a save that did not happen.
            if !envService.unset(key) { envOK = false }
        }

        var configFailures: [String] = []
        for (key, value) in configKV {
            // `hermes config set` takes exactly ONE key/value pair at
            // v2026.9.7 (`hermes_cli/config.py::_cmd_config_set`, dispatched
            // from `_CONFIG_SUBCOMMANDS`) — there is no batch form, so the
            // loop stays one spawn per key. It is the whole reason this
            // function must not run on the main actor.
            let result = run(["config", "set", key, value], configSetTimeout)
            if result.exitCode != 0 {
                configFailures.append(key)
                logger.warning("hermes config set \(key) failed: \(result.output)")
            }
        }

        // A partial save is a FAILURE for outcome purposes: some of what the
        // user typed is not in the file, and a green checkmark over that is
        // the exact misreport GW-F4 exists to end.
        if !envOK { return .failure(String(localized: "Failed to write .env")) }
        if !configFailures.isEmpty {
            return .failure(String(localized: "Saved, but failed to update: \(configFailures.joined(separator: ", "))"))
        }
        return .success(String(localized: "Saved — restart gateway to apply"))
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

    /// Per-key timeout for the `hermes config set` spawns a form save makes.
    nonisolated static let configSetTimeout: TimeInterval = 15

    /// What a setup form's `load()` reads off disk, gathered in ONE off-main
    /// pass so the form can commit it all in a single main-actor hop.
    struct FormSnapshot: Sendable {
        var env: [String: String] = [:]
        /// Non-nil when `.env` exists but could not be read (GW-F6 / DI L10).
        var envFailure: String?
        /// `nil` when the caller asked for env only.
        var config: HermesConfig?
        /// Raw config.yaml text — only for the one form that needs a key
        /// `HermesConfig` does not model (see `EmailSetupViewModel.load`).
        var rawConfigText: String?
    }

    /// Run `work` off the main actor and commit its result back on it.
    ///
    /// Charter C10: a setup form's load is an `.env` read plus a config.yaml
    /// read, and its save is an `.env` write plus one `hermes config set`
    /// spawn per key — on an ssh context every one of those is a network
    /// round-trip. Running them inline froze the window for the whole batch.
    /// `Task.detached` (not `Task { }`) is required: these view models are
    /// `@MainActor`, so a plain child task would inherit that isolation and
    /// run the I/O right back on the main actor.
    static func detached<T: Sendable>(
        _ work: @escaping @Sendable () -> T,
        then commit: @escaping @MainActor (T) -> Void
    ) {
        Task { @MainActor in
            let value = await Task.detached { work() }.value
            commit(value)
        }
    }

    /// Read a setup form's `.env` and/or config.yaml off the main actor.
    ///
    /// `includeEnv` / `includeConfig` exist so a form only pays for the files
    /// it reads: the whatsapp_cloud form is config-only, several others are
    /// env-only, and an unnecessary read is a whole extra SFTP round-trip on
    /// a remote host.
    static func loadForm(
        context: ServerContext,
        includeEnv: Bool = true,
        includeConfig: Bool = true,
        includeRawConfigText: Bool = false,
        then commit: @escaping @MainActor (FormSnapshot) -> Void
    ) {
        detached({
            var snapshot = FormSnapshot()
            if includeEnv {
                let (env, failure) = loadEnv(context: context)
                snapshot.env = env
                snapshot.envFailure = failure
            }
            if includeConfig {
                snapshot.config = HermesFileService(context: context).loadConfig()
            }
            if includeRawConfigText {
                snapshot.rawConfigText = context.readText(context.paths.configYAML) ?? ""
            }
            return snapshot
        }, then: commit)
    }

    /// Apply a form save off the main actor and commit the outcome back on it.
    /// See ``saveForm(context:envPairs:configKV:runner:)`` for the write rules.
    static func save(
        context: ServerContext,
        envPairs: [String: String],
        configKV: [String: String],
        runner: HermesCLIRunner? = nil,
        then commit: @escaping @MainActor (SaveOutcome) -> Void
    ) {
        detached({
            saveForm(context: context, envPairs: envPairs, configKV: configKV, runner: runner)
        }, then: commit)
    }

}


/// The shared load/save choreography every per-platform setup form uses.
///
/// Charter C10: the I/O both halves do (an `.env` read/write, a config.yaml
/// read, one `hermes config set` spawn per key) is a network round-trip each
/// on an ssh context, so neither half may run on the main actor. Hoisting the
/// choreography here keeps that single-sourced instead of 14 hand-written
/// `Task.detached` blocks, and carries the two invariants the detachment
/// introduces:
///
/// - A load that lands while a save is in flight must NOT overwrite the
///   values being committed (the same guard `GatewayBehaviorViewModel` has).
/// - A save must not run while the first load is still in flight. The form is
///   rendering its pre-load blanks then, and `saveForm` treats a blank field
///   as an `unset` — so saving from an unhydrated form would comment live
///   credentials out of `.env`. This is GW-F6 / DI L10 reached through the
///   other door.
@MainActor
protocol PlatformSetupForm: OutcomeMessageHosting {
    /// The server whose `.env` and config.yaml this form reads and writes.
    var context: ServerContext { get }
    /// C10 test seam — nil in production (see ``HermesCLIRunner``).
    var cliRunner: HermesCLIRunner? { get }
    /// True while the initial (or a re-entered) load is in flight.
    var isLoading: Bool { get set }
    /// True while a save is in flight.
    var isSaving: Bool { get set }
}

extension PlatformSetupForm {
    /// True while either half is in flight — what a view disables Save on.
    var isBusy: Bool { isLoading || isSaving }

    /// Read this form's files off the main actor, then hand the snapshot to
    /// `apply` back on it. `apply` assigns the form's fields and nothing else.
    func loadSnapshot(
        includeEnv: Bool = true,
        includeConfig: Bool = true,
        includeRawConfigText: Bool = false,
        apply: @escaping @MainActor (PlatformSetupHelpers.FormSnapshot) -> Void
    ) {
        // One load at a time, and never one on top of a save: two overlapping
        // loads would commit in completion order (last writer wins
        // arbitrarily), and a load landing on a save would undo it.
        guard !isBusy else { return }
        isLoading = true
        PlatformSetupHelpers.loadForm(
            context: context,
            includeEnv: includeEnv,
            includeConfig: includeConfig,
            includeRawConfigText: includeRawConfigText
        ) { [weak self] snapshot in
            guard let self else { return }
            self.isLoading = false
            guard !self.isSaving else { return }
            // GW-F6 / DI L10: absent `.env` is an empty form (nothing is set
            // yet); UNREADABLE says so, because a Save from the blank form it
            // would otherwise render comments the live keys out.
            if let failure = snapshot.envFailure { self.showSaveFailure(failure) }
            apply(snapshot)
        }
    }

    /// Write this form off the main actor and put the outcome on the save bar.
    func commitSave(envPairs: [String: String], configKV: [String: String]) {
        guard !isBusy else { return }
        isSaving = true
        PlatformSetupHelpers.save(
            context: context,
            envPairs: envPairs,
            configKV: configKV,
            runner: cliRunner
        ) { [weak self] outcome in
            guard let self else { return }
            self.isSaving = false
            self.applySaveOutcome(outcome)
        }
    }
}
