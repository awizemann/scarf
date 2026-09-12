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

        // `t-6fa3fc84`. A `_SHARED_KEYS` member does NOT reach the adapter
        // from whichever section the form happens to spell: `platform_section`
        // (`gateway/config_loader.py:171-180` @ v2026.9.7) picks ONE section
        // to bridge from, and a top-level `<platform>:` block REPLACES the
        // nested one as that source rather than out-ranking it key by key. So
        // `platforms.slack.require_mention` written onto a config that also
        // carries a top-level `slack:` block is bridged from nowhere and read
        // by nobody (`_slack_require_mention` reads `config.extra`,
        // `plugins/platforms/slack/adapter.py:5917-5926`) — while the save bar
        // said "Saved".
        //
        // Resolved HERE, at the single `config set` site, rather than in each
        // of the fifteen forms: the forms keep their literal keys (which is
        // what keeps them visible to the write/read parity gate) and this
        // rewrites the shared ones against the config.yaml actually on the
        // host. One extra read per save, off the main actor, and only when
        // the batch contains a shared key at all.
        let configKV = resolveSharedKeys(configKV, context: context)

        var configFailures: [String] = []
        for (key, value) in configKV {
            // `hermes config set` takes exactly ONE key/value pair at
            // v2026.9.7 (`hermes_cli/config.py::_cmd_config_set`, dispatched
            // from `_CONFIG_SUBCOMMANDS`) — there is no batch form, so the
            // loop stays one spawn per key. It is the whole reason this
            // function must not run on the main actor.
            //
            // P39: judged by OUTPUT, not the exit code. `set_config_value`'s
            // managed-install arm prints to stderr and `return`s
            // (`hermes_cli/config.py:3450-3452` @ v2026.9.7), which Python
            // exits 0 — so all fifteen platform-setup forms banner'd
            // "Saved — restart gateway to apply" over a config.yaml the host
            // never wrote. Same `HermesConfigSet` judge Settings uses.
            let result = run(HermesConfigSet.argv(key: key, value: value), configSetTimeout)
            if !HermesConfigSet.judge(output: result.output, exitCode: result.exitCode).succeeded {
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

    /// Resolve every `_SHARED_KEYS` member in a save batch onto the section
    /// Hermes bridges it from. See the call site in ``saveForm`` for why.
    ///
    /// Reads config.yaml only when the batch actually contains a shared key,
    /// so the fourteen saves that carry none pay nothing. An UNREADABLE
    /// config.yaml leaves the batch untouched: that is the pre-P44 behaviour,
    /// and guessing a spelling off a file we could not read would be a worse
    /// answer than the literal the form chose. (A form whose load could not
    /// prove config.yaml never reaches here anyway — `commitSave` bounces it
    /// off the latched `loadRefusal`.)
    nonisolated static func resolveSharedKeys(
        _ configKV: [String: String],
        context: ServerContext
    ) -> [String: String] {
        guard configKV.keys.contains(where: { HermesPlatformSharedKeys.split(key: $0) != nil })
        else { return configKV }
        guard let proven = try? HermesFileService(context: context).loadConfigProven()
        else { return configKV }
        return HermesPlatformSharedKeys.resolved(configKV, configText: proven.rawText)
    }

    /// Ask the user's default browser to open a URL (typically a hermes doc page
    /// or a platform developer portal).
    static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Label of the first `(label, value)` pair whose value would reach
    /// config.yaml carrying a control character, or `nil` when all are clean.
    ///
    /// **Round-5, P51 — round-4 decision 9's rule, reaching the platform
    /// setup forms.** The MCP entry editor and the reasoning-override editor
    /// have refused these since P41; the fifteen forms never did, although
    /// three of them put free text into config.yaml through the same door.
    ///
    /// This is the VISIBILITY guard, not the parse guard, and the reason is
    /// the EMITTER: a form's config keys go out through `hermes config set`,
    /// so HERMES writes them with PyYAML's own emitter
    /// (`hermes_cli/config.py:2307` `save_config` → `utils.py:262`
    /// `atomic_yaml_write` = `yaml.dump` @ `v2026.9.7`), which represents a
    /// control losslessly as a double-quoted escape. The file stays loadable;
    /// what the user gets is a value they cannot see and Hermes will never
    /// match — a `reply_prefix` with a pasted ESC in it, a channel id that
    /// silently belongs to no channel. Refusing up front beats writing a
    /// value whose damage is invisible on both sides.
    ///
    /// Checked on the value as the save WRITES it. The three call sites pass
    /// raw text because `saveForm` writes these scalars untrimmed — P41b's
    /// "a refusal must run on the value the WRITER emits", in the direction
    /// that keeps the check from being stricter than the write.
    /// Ordered by LABEL, not by the caller's iteration order: the batch
    /// arrives as a `Dictionary`, whose order is unspecified and changes
    /// between runs, so a form with two bad fields would otherwise name a
    /// different one each time the user pressed Save.
    static func controlCharacterFieldLabel(_ fields: [(String, String)]) -> String? {
        for (label, value) in fields.sorted(by: { $0.0 < $1.0 })
        where YAMLScalar.containsControlCharacter(value) {
            return label
        }
        return nil
    }

    /// One sentence naming the host, or `nil` on a local context: why an
    /// interactive pairing step is unavailable from this window.
    ///
    /// **Round-5 decision 15.** `EmbeddedSetupTerminal` is a
    /// `LocalProcessTerminalView` — it spawns on THIS Mac, always, with no
    /// transport in the path. On a remote context that made three buttons
    /// lie in three different ways:
    ///
    /// * WhatsApp's "Start Pairing" ran `context.paths.hermesBinary`, i.e.
    ///   the REMOTE absolute path, as a local executable — usually "no such
    ///   file", and on a Mac that happens to have hermes at the same path,
    ///   a QR code that pairs the WRONG agent.
    /// * Signal's "Link Device" and "Start Daemon" ran the local
    ///   `signal-cli` and wrote the link to the LOCAL `~/.hermes`, which the
    ///   remote gateway never reads — the pairing appeared to succeed and
    ///   the platform stayed dead.
    /// * `signalCLIInstalled` probes the local login shell's PATH, so the
    ///   buttons' own enablement was answering about the wrong machine.
    ///
    /// The posture is `SettingsViewModel.runBackup`'s: the gesture is a
    /// LOCAL-only affordance, so on a remote context say plainly where the
    /// work has to happen instead of failing in the terminal pane. The
    /// buttons are disabled and this sentence sits under them.
    static func remoteOnlyHostNotice(_ context: ServerContext) -> String? {
        guard context.isRemote else { return nil }
        let host = context.displayName
        return String(localized: "Pairing needs a terminal on \(host), where Hermes runs — run this step there over SSH.")
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
        /// `nil` when the caller asked for env only, and also when the
        /// config.yaml read was REFUSED — see ``configFailure``. A form's
        /// `apply` already treats nil as "leave the fields alone", which is
        /// exactly right for an unproven read.
        var config: HermesConfig?
        /// Non-nil when config.yaml exists but could not be read (GW-F6 /
        /// DI L10, round-3 P33). The other half of ``envFailure``: a setup
        /// form reads BOTH files, and proving only one of them still leaves
        /// the blank-form-over-live-values hole open through the other door.
        var configFailure: String?
        /// Raw config.yaml text — only for the one form that needs a key
        /// `HermesConfig` does not model (see `EmailSetupViewModel.load`).
        /// `nil` (never `""`) when the read was refused, for the same reason.
        var rawConfigText: String?

        /// The first refusal either half produced, or `nil` when both reads
        /// are proven. This is what gates a save.
        var loadFailure: String? { envFailure ?? configFailure }
    }

    /// Run `work` off the main actor and commit its result back on it.
    ///
    /// Charter C10: a setup form's load is an `.env` read plus a config.yaml
    /// read, and its save is an `.env` write plus one `hermes config set`
    /// spawn per key — on an ssh context every one of those is a network
    /// round-trip. Running them inline froze the window for the whole batch.
    /// Getting off the main actor is only half of it, and `Task.detached` is
    /// only that half: these view models are `@MainActor`, so a plain child
    /// task would inherit that isolation and run the I/O right back on the
    /// main actor — but a DETACHED task still runs on the cooperative pool,
    /// one thread per core, and every one of these reads blocks its thread.
    /// ``OffPool/run(_:)`` gives the blocking work a thread of its own
    /// (round-5 P52).
    static func detached<T: Sendable>(
        _ work: @escaping @Sendable () -> T,
        then commit: @escaping @MainActor (T) -> Void
    ) {
        Task { @MainActor in
            let value = await OffPool.run(work)
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
            // ONE proven read serves both consumers: `loadConfig()` and a
            // second `readText` were two separate round-trips of the same
            // file that could disagree, and neither could tell an ABSENT
            // config.yaml (a fresh host — an empty form is the truth, and
            // Save must stay allowed) from an unreadable one.
            if includeConfig || includeRawConfigText {
                do {
                    let proven = try HermesFileService(context: context).loadConfigProven()
                    if includeConfig { snapshot.config = proven.config }
                    if includeRawConfigText { snapshot.rawConfigText = proven.rawText }
                } catch {
                    snapshot.configFailure = error.localizedDescription
                }
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
/// - A save must not run when a load COMPLETED without proving what it read.
///   Same hazard, slower fuse: a `.env` or config.yaml that is there and
///   unreadable arrives as an empty form, and the next Save publishes those
///   blanks. Both halves are proved (`HermesEnvService.loadProven`,
///   `HermesFileService.loadConfigProven`) and either one's refusal latches
///   ``loadRefusal``, which ``commitSave(envPairs:configKV:)`` bounces off.
///   An ABSENT file is NOT a refusal — a fresh host with no `.env` and no
///   config.yaml genuinely has nothing set, the empty form is the truth, and
///   Save has to work or first-run setup is impossible.
///
/// ## Why a setup form writes the resolved default and Settings does not
///
/// Round-3 product decision 9 (`.memory/decisions/hermes-v0-21-1-compatibility-decisions.md`).
/// The two config-writing surfaces have deliberately opposite postures on a
/// key the user never touched, and this is the rule:
///
/// - **A platform setup form is a "set up this platform" gesture.** It writes
///   the WHOLE block explicitly, resolved defaults included — `api_version:
///   "v20.0"`, `dm_policy: "open"`, `enabled: true|false`. The user's mental
///   model is "these are my WhatsApp Cloud settings, save them", the block is
///   authored as a unit, and a partly-written platform block is a platform
///   that half-starts. Writing the default it is showing is therefore the
///   truthful thing: the form is the record of the decision.
/// - **Settings edits ONE key at a time**, and there absence is a SENTINEL
///   ("Host default") that must survive an unrelated save — writing the
///   resolved default would freeze today's Hermes default into the file and
///   silently opt the user out of the host's future one. So Settings writes
///   nothing for an untouched key, and a sentinel row is a no-op.
///
/// One rule, stated once, because the two look inconsistent from the outside
/// and the inconsistency is intentional. No behaviour change is implied by
/// this comment; if a form ever needs Settings' posture, it needs a sentinel
/// of its own first.
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
    /// Non-nil when the last load could NOT prove one of the two files it
    /// reads, so the fields on screen may be blanks over live values. Owned
    /// by ``loadSnapshot(includeEnv:includeConfig:includeRawConfigText:apply:)``
    /// and read by ``commitSave(envPairs:configKV:)``, which refuses while
    /// it is set. See the type's doc comment.
    var loadRefusal: String? { get set }
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
            // GW-F6 / DI L10: an ABSENT `.env` or config.yaml is an empty
            // form (nothing is set yet); UNREADABLE says so and LATCHES,
            // because a Save from the blank form it would otherwise render
            // comments the live keys out — or, for a config-only form like
            // whatsapp_cloud, writes `""` over the access token.
            self.loadRefusal = snapshot.loadFailure
            if let failure = snapshot.loadFailure { self.showSaveFailure(failure) }
            // P37 finding 5: do NOT apply when the `.env` half was refused.
            // `apply` assigns every field from the snapshot, and on an
            // `envFailure` the snapshot's `env` is `[:]` — so every
            // `env["…"] ?? ""` overwrote a live credential with a blank. The
            // latched refusal already stopped the blanks reaching disk
            // (`commitSave` refuses while `loadRefusal` is set), but the user
            // still watched their token disappear with no way to know it was
            // safe on the host, and the obvious next move — retype it — is
            // exactly the wrong one.
            //
            // The guard is on `envFailure`, NOT on `loadFailure`, because the
            // two halves are not symmetric. `config` / `rawConfigText` are
            // `nil` on a refusal and every form's `apply` either opens with
            // `guard let cfg = snapshot.config?.<platform> else { return }`
            // or (`NtfySetupViewModel`, P51; `MattermostSetupViewModel`,
            // P51b) binds it optionally and applies
            // the proven `.env` half first, so the config half declines
            // itself either way. `env` is `[:]`, which is
            // indistinguishable from "nothing is set yet", so only it needs
            // stopping here. Guarding on `loadFailure` would suppress a
            // PROVEN `.env` because the OTHER file was unreadable — which is
            // this finding's own failure mode through the other door.
            guard snapshot.envFailure == nil else { return }
            apply(snapshot)
        }
    }

    /// Write this form off the main actor and put the outcome on the save bar.
    func commitSave(envPairs: [String: String], configKV: [String: String]) {
        guard !isBusy else { return }
        // The load landed but could not prove one of its two files, so the
        // fields below may be blanks over live values. Re-state the reason
        // rather than failing silently: the Save button is enabled (the form
        // is not busy) and a press that did nothing at all would read as a
        // bug. Cleared by the next proven load — the message names Reload.
        if let refusal = loadRefusal {
            showSaveFailure(refusal)
            return
        }
        // Round-4 decision 9's control-character refusal, reaching the setup
        // forms (P51). Placed HERE, at the one door all fifteen SETUP FORMS
        // share, rather than in the three forms the finding named: the hazard
        // is a property of "free text into a config.yaml scalar", and a
        // per-form check would be fifteen chances to forget the sixteenth.
        //
        // "All fifteen" is the honest scope and not "every config write in
        // the app" (P51b finding 5): `GatewayBehaviorViewModel.save` calls
        // `PlatformSetupHelpers.saveForm` directly, because its save is two
        // steps (a direct-YAML list write, then the scalars) and it is not a
        // `PlatformSetupForm`. It is the ONLY production caller of `saveForm`
        // outside this door — pinned by
        // `GatewayBehaviourIsTheOnlyDirectSaveFormCallerP51bTests` — and the
        // scalars it sends are booleans (`PlatformSetupHelpers.envBool`), so
        // no free text reaches `hermes config set` through it. Its free-text
        // half is the allowlist, which goes to `GatewayConfigWriter.saveList`
        // and is a different write path with its own quoting.
        //
        // The `.env` half is NOT checked — `HermesEnvService` is a different file format with
        // its own quoting, and no finding has been made against it.
        //
        // The key is the label because it is the truthful one: these values
        // arrive here as a `[key: value]` batch with the form's field names
        // already gone. See
        // ``PlatformSetupHelpers/controlCharacterFieldLabel(_:)`` for why this
        // is a visibility guard and not a parse guard.
        if let key = PlatformSetupHelpers.controlCharacterFieldLabel(
            configKV.map { ($0.key, $0.value) }
        ) {
            showSaveFailure(String(localized: "“\(key)” contains a control character. Hermes would store it as an invisible escape that never matches — remove it and save again."))
            return
        }
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
