import Foundation
import Testing
import ScarfCore
@testable import scarf

// MARK: - P47 / round-5 decision 1: the Plugins pane under the managed lock

/// Decision 1 folds this pane's half of `t-8f55df7d`. Activation is a config
/// write — `cmd_enable` (`hermes_cli/plugins_cmd.py:987`) and `cmd_disable`
/// (`:1182`) call `_save_plugin_sets` (`:1022`, `:1196`) → `_save_enabled_set`
/// / `_save_disabled_set` (`:910`, `:906`) → `_write_config_value`
/// (`:115-120`) → `save_config`, whose managed arm refuses at exit 0 and lets
/// the caller print its success line anyway (`hermes_cli/config.py:2315-2318`
/// @ `v2026.9.7`) — so on a managed host every Enable/Disable click ended in
/// the same refusal. (`_set_plugin_enabled`, `:944`, is a sibling caller of
/// the same door, not a link in this chain — P47b review, finding 2.)
@Suite("P47 · the Plugins managed lock")
struct PluginsManagedLockP47Tests {

    @MainActor private static func viewModel(
        managed: String?, returning output: String = "", exitCode: Int32 = 0
    ) -> PluginsViewModel {
        let vm = PluginsViewModel(
            context: .local,
            cliRunner: { _, _ in (output, exitCode) }
        )
        vm.managedInstall = HermesManagedInstall(system: managed)
        return vm
    }

    @MainActor private static func plugin(_ name: String) -> HermesPlugin {
        HermesPlugin(
            name: name, source: name, activation: .enabled,
            description: "", version: "", path: "", toolOverride: false
        )
    }

    // MARK: the banner

    /// One banner per surface, naming the package manager — "use your package
    /// manager" is useless without it (the P39 rule).
    @MainActor @Test func theBannerNamesThePackageManager() throws {
        let vm = Self.viewModel(managed: "nixos")
        let text = try #require(vm.managedBannerText)
        #expect(text.contains("nixos"))
        #expect(vm.isManagedHost)
    }

    /// Charter C1: a host with no `.managed` marker renders byte-identical to
    /// the previous release — no banner, no lock.
    @MainActor @Test func anUnmanagedHostHasNoBannerAndNoLock() {
        let vm = Self.viewModel(managed: nil)
        #expect(vm.managedBannerText == nil)
        #expect(vm.isManagedHost == false)
    }

    // MARK: the local refusal

    /// The bug: `enable` shelled the command and reported whatever the
    /// exit-0 refusal printed. It refuses locally now — the `.disabled`
    /// control is the primary door, this is the keyboard/programmatic one.
    @MainActor @Test func enableRefusesLocallyOnAManagedHost() {
        let vm = Self.viewModel(managed: "home-manager")
        vm.enable(Self.plugin("weather"))
        #expect(vm.messageIsFailure)
        #expect(vm.message?.contains("home-manager") == true)
    }

    /// Lesson 3 of the round-5 addendum — walk the sibling. `disable` is the
    /// same door in the other direction.
    @MainActor @Test func disableRefusesLocallyOnAManagedHost() {
        let vm = Self.viewModel(managed: "home-manager")
        vm.disable(Self.plugin("weather"))
        #expect(vm.messageIsFailure)
        #expect(vm.message?.contains("home-manager") == true)
    }

    // MARK: the fallthrough (the env-var-only managed host)

    /// `HERMES_MANAGED` belongs to the systemd service, not to the shell
    /// Scarf's transport opens, so the marker probe cannot see it and the
    /// lock never arms. `--enable` then really does reach `save_config`'s
    /// refusal — under a `✓ Plugin <name> enabled.` line, at exit 0. Never
    /// "Installed and enabled".
    @MainActor @Test func aRefusedEnableOnAnUndetectedManagedHostIsNotReportedAsEnabled() async {
        let vm = Self.viewModel(managed: nil, returning: """
        ✓ Installed widget
        Cannot save configuration: this Hermes Agent installation is managed by NixOS.
        ✓ Plugin widget enabled.
        """, exitCode: 0)
        vm.install("widget", enable: true)
        let message = await Self.awaitMessage(on: vm)
        #expect(message?.contains("Installed and enabled") == false)
        #expect(message?.contains("could not be enabled") == true)
        #expect(message?.contains("Cannot save configuration") == true)
    }

    /// C1 again: an ordinary host's clean install is unchanged.
    @MainActor @Test func aCleanInstallStillSaysInstalledAndEnabled() async {
        let vm = Self.viewModel(managed: nil, returning: """
        ✓ Installed widget
        ✓ Plugin widget enabled.
        """, exitCode: 0)
        vm.install("widget", enable: true)
        let message = await Self.awaitMessage(on: vm)
        #expect(message == "Installed and enabled")
        #expect(vm.messageIsFailure == false)
    }

    @MainActor private static func awaitMessage(on vm: PluginsViewModel) async -> String? {
        for _ in 0..<400 {
            if let message = vm.message, !message.hasPrefix("Installing") { return message }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return vm.message
    }

    // MARK: where the lock sits, and where it deliberately does not

    /// The P39c lesson: a lock scoped by "does Hermes refuse it" must exclude
    /// what Hermes never sees. Install, Update and Remove work on the plugin
    /// DIRECTORY (`_install_plugin_core`, the `git pull` in `cmd_update`,
    /// `_remove_plugin_core` — `hermes_cli/plugins_cmd.py:740`, `:794-830`,
    /// `:887-898` @ `v2026.9.7`), which `is_managed()` never guards. Only the
    /// activation control and the install sheet's enable toggle are locked.
    @Test func theLockCoversActivationAndNotTheDirectoryActions() throws {
        let source = try Self.source("scarf/Features/Plugins/Views/PluginsView.swift")
        // Exactly two `.disabled(viewModel.isManagedHost)` sites: the row's
        // Enable/Disable button and the install sheet's toggle.
        let hits = source.components(separatedBy: ".disabled(viewModel.isManagedHost)").count - 1
        #expect(hits == 2)
        // Reload, Update and Remove are not among them.
        #expect(source.contains("Button(\"Update\") { viewModel.update(plugin) }\n                .controlSize(.small)\n                .accessibilityLabel"))
        #expect(source.contains("Button(\"Reload\") { viewModel.load(force: true) }"))
        // One banner, rendered once.
        #expect(source.components(separatedBy: "private var managedBanner").count - 1 == 1)
    }

    /// A `.disabled` toggle keeps the value it held, and this one defaults to
    /// ON — so the binding has to read `false` on a managed host or a greyed
    /// switch would still send `--enable`. Belt: the call site too.
    @Test func theEnableToggleCannotSendEnableOnAManagedHost() throws {
        let source = try Self.source("scarf/Features/Plugins/Views/PluginsView.swift")
        #expect(source.contains("get: { viewModel.isManagedHost ? false : enableOnInstall }"))
        #expect(source.contains("enable: enableOnInstall && !viewModel.isManagedHost"))
    }

    /// The probe is read on ONE production hop — `load()`'s detached task —
    /// and nowhere else, so the internal setter that the behaviour tests above
    /// use cannot quietly become a second writer.
    @Test func theProbeIsReadInLoadAndNowhereElse() throws {
        let source = try Self.source("scarf/Features/Plugins/ViewModels/PluginsViewModel.swift")
        #expect(source.components(separatedBy: "HermesManagedInstallCache.shared").count - 1 == 1)
        #expect(source.components(separatedBy: "self?.managedInstall = managed").count - 1 == 1)
    }

    static func source(_ relative: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("scarf").appendingPathComponent(relative),
            encoding: .utf8
        )
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }
}

// MARK: - P47: the exit-0 verdicts at their real call sites

@Suite("P47 · CLI verdict call sites")
struct CLIVerdictCallSitesP47Tests {

    /// `sessions optimize`'s failure arm exits 0
    /// (`hermes_cli/sessions_cmd.py:815` @ `v2026.9.7`), so the Health pane
    /// must not key its summary on the exit code.
    @Test func healthJudgesSessionsOptimizeByOutput() throws {
        let source = try PluginsManagedLockP47Tests
            .source("scarf/Features/Health/ViewModels/HealthViewModel.swift")
        #expect(source.contains("HermesSessionsOptimizeVerdict.judge("))
        #expect(source.contains("args: HermesSessionsOptimizeVerdict.argv"))
        // The old exit-code branch is gone: nothing on this path may claim a
        // summary just because the process finished.
        #expect(source.contains("[\"sessions\", \"optimize\"]") == false)
    }

    /// Decision 2 at its call site.
    @Test func credentialPoolsJudgesAuthLogoutByOutput() throws {
        let source = try PluginsManagedLockP47Tests
            .source("scarf/Features/CredentialPools/ViewModels/CredentialPoolsViewModel.swift")
        #expect(source.contains("HermesAuthLogoutVerdict.argv(provider: provider)"))
        #expect(source.contains("HermesAuthLogoutVerdict.judge("))
        #expect(source.contains("[\"auth\", \"logout\", provider]") == false)
    }

    /// Decision 3 on BOTH platforms — lesson 5, grep both targets.
    @Test(arguments: [
        "scarf/Features/Memory/Views/MemoryView.swift",
        "Scarf iOS/Memory/MemoryListView.swift",
    ])
    func bothMemoryResetSitesJudgeByOutput(_ relative: String) throws {
        let source = try PluginsManagedLockP47Tests.source(relative)
        #expect(source.contains("HermesMemoryResetVerdict.judge("))
        #expect(source.contains("HermesMemoryResetVerdict.argv"))
        #expect(source.contains("\"memory\", \"reset\", \"--yes\"") == false)
        #expect(source.contains("memory reset --yes\"") == false)
    }
}

// MARK: - P47: `--` before the positionals

/// argparse reads everything after the first `--` as a positional, so a
/// session id, provider, or route name beginning with a dash exited 2 instead
/// of being acted on. Each verb's parser was opened at `v2026.9.7`:
/// `sessions rename` (`subcommands/sessions.py:210-213`),
/// `sessions delete` (`:100-102`), `auth logout` (`subcommands/auth.py:59-61`),
/// `auth reset` (`:40-45`), `webhook remove` (`subcommands/webhook.py:42-43`),
/// `webhook test` (`:45-48`) — every one a plain positional with no
/// `nargs=REMAINDER`, which is what makes `--` safe.
@Suite("P47 · the positional separator")
struct PositionalSeparatorP47Tests {

    @Test func sessionsDeleteAndRenameShareOneArgvBuilder() {
        #expect(SessionsViewModel.deleteArgv(sessionId: "-abc")
            == ["sessions", "delete", "--yes", "--", "-abc"])
        #expect(SessionsViewModel.renameArgv(sessionId: "-abc", title: "-x")
            == ["sessions", "rename", "--", "-abc", "-x"])
    }

    /// The flag comes FIRST and the separator after it: `--yes` appended past
    /// the `--` would be read as a positional and exit 2.
    @Test func theSeparatorFollowsTheFlagNotPrecedesIt() throws {
        let argv = SessionsViewModel.deleteArgv(sessionId: "s1")
        let yes = try #require(argv.firstIndex(of: "--yes"))
        let sep = try #require(argv.firstIndex(of: "--"))
        #expect(yes < sep)
    }

    /// The Chat pane built its rename argv by hand and was the only site
    /// without the separator — the same rename worked from the Sessions pane
    /// and failed from Chat.
    @Test func chatRenameUsesTheSharedBuilder() throws {
        let source = try PluginsManagedLockP47Tests
            .source("scarf/Features/Chat/ViewModels/ChatViewModel.swift")
        #expect(source.contains("SessionsViewModel.renameArgv(sessionId: sessionId, title: trimmed)"))
        #expect(source.contains("[\"sessions\", \"rename\", sessionId, trimmed]") == false)
        #expect(source.contains("[\"sessions\", \"delete\", \"--yes\", sessionId]") == false)
    }

    /// **Moved, not lost (P54).** Round-6 gave both webhook verbs a verdict,
    /// and the argv moved onto it so the separator and the markers it is
    /// judged by cannot drift apart. The guarantee P47 wrote is unchanged —
    /// `webhook remove|test` still carry `--` before their positional — so
    /// this follows the argv to its new home rather than being deleted.
    @Test func theWebhookAndAuthResetPositionalsAreSeparated() throws {
        let webhooks = try PluginsManagedLockP47Tests
            .source("scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift")
        #expect(webhooks.contains("HermesWebhookRemoveVerdict.argv(name: webhook.name)"))
        #expect(webhooks.contains("HermesWebhookTestVerdict.argv(name: webhook.name)"))
        // The separator itself, asserted where it now lives.
        #expect(HermesWebhookRemoveVerdict.argv(name: "ci") == ["webhook", "remove", "--", "ci"])
        #expect(HermesWebhookTestVerdict.argv(name: "ci") == ["webhook", "test", "--", "ci"])
        let pools = try PluginsManagedLockP47Tests
            .source("scarf/Features/CredentialPools/ViewModels/CredentialPoolsViewModel.swift")
        #expect(pools.contains("[\"auth\", \"reset\", \"--\", provider]"))
    }

    /// **P60: the three `profile` verbs.** `profile_name` / `old_name` /
    /// `new_name` are plain positionals
    /// (`hermes_cli/subcommands/profile.py:19`, `:41`, `:77`, `:79` @
    /// `v2026.9.7`), and P47 gave `rename` and `delete` their separator and
    /// left `create` — on both the Mac VM and `BotsService.Lifecycle`, whose
    /// three argvs had none at all (`BotModePhaseAB0Tests` covers those).
    /// A bot or profile name beginning with `-` exits 2 with a usage block.
    @Test func theProfileCreatePositionalIsSeparated() throws {
        let source = try PluginsManagedLockP47Tests
            .source("scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift")
        // The name is no longer glued to the verb…
        #expect(!source.contains("[\"profile\", \"create\", name]"))
        // …and the separator is appended after every option, before it.
        #expect(source.contains("args += [\"--\", name]"))
        // Its two siblings, unchanged.
        #expect(source.contains("[\"profile\", \"rename\", \"--\", profile.name, newName]"))
        #expect(source.contains("[\"profile\", \"delete\", \"-y\", \"--\", profile.name]"))
    }

    /// `skills update` has no `--yes` flag — `name` (optional) and `--force`
    /// are its whole parser (`hermes_cli/subcommands/skills.py:79-83` @
    /// `v2026.9.7`). The code was right; the iOS doc comment was not.
    @Test func theIOSSkillsDocNoLongerClaimsAYesFlag() throws {
        let source = try PluginsManagedLockP47Tests.source("Scarf iOS/Skills/SkillsView.swift")
        #expect(source.contains("skills update --yes") == false)
        #expect(source.contains("There is no `--yes` on either verb"))
    }
}

// MARK: - P47: the new user-facing strings are in the catalogue

/// `LocalizationCatalogTests` gates the catalogue internally only; nothing
/// proves a `String(localized:)` in the sources HAS a row (the P39b finding,
/// general gate filed as `t-3bcd1d7f`).
@Suite("P47 · catalogue coverage")
struct CatalogueCoverageP47Tests {

    @Test(arguments: [
        "This Hermes is managed by %@. Enabling and disabling plugins is read-only here — change it in your package manager's configuration and re-deploy.",
        "This Hermes installation is managed; plugin activation is read-only",
        "Installed, but it could not be enabled: %@",
        "There was no stored auth state for this provider.",
        "There were no memory files to reset.",
        "Optimize failed. %@",
        // P47b finding 1.
        "hermes sessions optimize printed no result. Check the host.",
    ])
    func theNewStringsAreInTheCatalogueInAllSixLocales(_ key: String) throws {
        let url = PluginsManagedLockP47Tests.repoRoot
            .appendingPathComponent("scarf/scarf/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any], "\(key) has no catalogue row")
        let locs = try #require(entry["localizations"] as? [String: Any])
        for locale in ["de", "es", "fr", "ja", "pt-BR", "zh-Hans"] {
            #expect(locs[locale] != nil, "\(key) is missing \(locale)")
        }
    }
}

// MARK: - P47b: the review of P47's two commits

/// Finding 1. `HermesSessionsOptimizeVerdict` has three states, and the strip
/// had two branches for them: a `.unconfirmed` run (exit 0, neither
/// `Optimized {n} FTS index(es).` at `hermes_cli/sessions_cmd.py:817` nor
/// `Error: optimization failed:` at `:815`) fell into the failure arm, which
/// rendered `"Optimize failed. "` with an empty tail when the run printed
/// nothing at all. The memory-reset sites already say Hermes printed no
/// result; this one does now too.
@Suite("P47b · the sessions optimize strip")
struct SessionsOptimizeStripP47bTests {

    @MainActor @Test func aSilentExitZeroRunSaysHermesPrintedNoResult() {
        let outcome = HermesSessionsOptimizeVerdict.judge(output: "", exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        let message = HealthViewModel.sessionsOptimizeSummary(
            outcome: outcome, exitCode: 0, trimmed: ""
        )
        #expect(message == "hermes sessions optimize printed no result. Check the host.")
        #expect(message.contains("Optimize failed") == false)
    }

    /// The unrecognised-output shape: exit 0 with a line the verdict does not
    /// know. Still `.unconfirmed`, so still not a failure.
    @MainActor @Test func anUnrecognisedExitZeroRunIsNotCalledAFailure() {
        let output = "Nothing to do.\n"
        let outcome = HermesSessionsOptimizeVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        let message = HealthViewModel.sessionsOptimizeSummary(
            outcome: outcome, exitCode: 0,
            trimmed: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(message.contains("Optimize failed") == false)
    }

    /// The real exit-0 failure — `Error: optimization failed: {e}` (`:815`) —
    /// still quotes Hermes's own reason line. That is the P47 fix and it
    /// stays.
    @MainActor @Test func theExitZeroRefusalStillQuotesItsReasonLine() {
        let output = """
        Optimizing session store (FTS merge + VACUUM)…
        Error: optimization failed: database is locked
        """
        let outcome = HermesSessionsOptimizeVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.confidence == .failed)
        let message = HealthViewModel.sessionsOptimizeSummary(
            outcome: outcome, exitCode: 0,
            trimmed: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(message.contains("Optimize failed."))
        #expect(message.contains("database is locked"))
    }

    /// C1: the success and non-zero-exit arms are untouched.
    @MainActor @Test func theSuccessAndNonZeroArmsAreUnchanged() {
        let ok = "Optimized 3 FTS index(es)."
        let okOutcome = HermesSessionsOptimizeVerdict.judge(output: ok, exitCode: 0)
        #expect(HealthViewModel.sessionsOptimizeSummary(
            outcome: okOutcome, exitCode: 0, trimmed: ok
        ) == ok)
        let bad = "Traceback…"
        let badOutcome = HermesSessionsOptimizeVerdict.judge(output: bad, exitCode: 2)
        #expect(HealthViewModel.sessionsOptimizeSummary(
            outcome: badOutcome, exitCode: 2, trimmed: bad
        ).contains("exit 2"))
    }
}

/// Finding 5. Two sibling `.alert`s on one view is a SwiftUI coin-toss when
/// both fire; the reset's failure and its decision-3 neutral note are
/// mutually exclusive, so they are one enum-driven alert.
@Suite("P47b · the memory reset alert")
struct MemoryResetAlertP47bTests {

    @Test func theMemoryPaneRaisesExactlyOneResetAlert() throws {
        let source = try PluginsManagedLockP47Tests
            .source("scarf/Features/Memory/Views/MemoryView.swift")
        #expect(source.components(separatedBy: ".alert(").count - 1 == 1)
        #expect(source.contains("resetAlert: ResetAlert?"))
        // The two @State strings the stacked alerts were driven by are gone.
        #expect(source.contains("resetError") == false)
        #expect(source.contains("resetNote") == false)
    }
}

/// Findings 2, 3 and 4 — the citations P47 wrote that the tagged source does
/// not support. Each was re-opened at `v2026.9.7`.
@Suite("P47b · the corrected citations")
struct CorrectedCitationsP47bTests {

    /// Finding 2: `cmd_enable` (`plugins_cmd.py:987`) and `cmd_disable`
    /// (`:1182`) call `_save_plugin_sets` directly (`:1022`, `:1196`);
    /// `_set_plugin_enabled` (`:944`) is a sibling caller, not a link.
    @Test(arguments: [
        "scarf/Features/Plugins/ViewModels/PluginsViewModel.swift",
    ])
    func theActivationChainNamesSavePluginSets(_ relative: String) throws {
        let source = try PluginsManagedLockP47Tests.source(relative)
        #expect(source.contains("_save_plugin_sets"))
        #expect(source.contains("`cmd_enable` / `cmd_disable` reach\n    /// `_set_plugin_enabled`") == false)
    }

    /// Finding 3: `cmd_update` DOES reach `save_config`, through
    /// `_rescan_after_update` (`:810`) → `_set_plugin_enabled(name,
    /// enable=False)` (`:847`) on a dangerous verdict — the rationale that
    /// only `_set_plugin_enabled` reaches it (and by implication that Update
    /// is config-write-free) was false. The verdict, not the lock, catches it.
    @Test func theUpdateRationaleNoLongerClaimsNoConfigWrite() throws {
        let source = try PluginsManagedLockP47Tests
            .source("scarf/Features/Plugins/ViewModels/PluginsViewModel.swift")
        #expect(source.contains("only\n    /// `_set_plugin_enabled` reaches `save_config`") == false)
        #expect(source.contains("_rescan_after_update"))
        #expect(source.contains("HermesPluginsUpdateVerdict/judge"))
    }
}
