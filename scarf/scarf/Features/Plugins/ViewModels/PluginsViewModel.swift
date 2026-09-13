import Foundation
import ScarfCore
import os

struct HermesPlugin: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let source: String      // Git URL / `owner/repo`, or the CLI's source column
    /// Activation state as Hermes reports it — three states, not two.
    ///
    /// This used to be `enabled: Bool`, computed from a `.disabled`
    /// marker file inside the plugin directory. **Hermes never writes
    /// such a file.** Activation lives in `plugins.enabled` /
    /// `plugins.disabled` in config.yaml (`plugins_cmd.py::_plugin_status`,
    /// `_save_disabled_set`), so the marker was always absent and every
    /// plugin rendered as enabled — including plugins in neither list,
    /// which the runtime does not load at all.
    let activation: HermesPluginActivation
    let description: String
    let version: String     // From `plugins list --json`, or the manifest
    let path: String        // Absolute directory path (empty on the JSON path)
    /// Hermes v0.14 — plugin advertises `tool_override = true` in its
    /// manifest, meaning it replaces a built-in tool. Rendered as a
    /// "tool-override" badge in PluginsView so the user notices when
    /// installed plugins are intercepting built-in behavior.
    let toolOverride: Bool
}

@Observable
final class PluginsViewModel: OutcomeMessageHosting {
    private let logger = Logger(subsystem: "com.scarf", category: "PluginsViewModel")
    let context: ServerContext
    private let fileService: HermesFileService
    /// Injectable CLI seam so `enable` / `disable` can be exercised through
    /// their real production entry points in tests (the verdict rules —
    /// markers and `failureWins` — live at those call sites, so a test that
    /// re-states them itself proves nothing about the shipped behaviour).
    private let cliRunner: HermesCLIRunner

    init(context: ServerContext = .local, cliRunner: HermesCLIRunner? = nil) {
        self.context = context
        self.fileService = HermesFileService(context: context)
        self.cliRunner = cliRunner ?? context.cliRunner
    }

    var plugins: [HermesPlugin] = []
    /// `hermes plugins compat --json` (v0.21.1+). Nil means "no answer" —
    /// an older host, or a command that didn't run — which is deliberately
    /// distinct from a report with no affected plugins. The banner only
    /// renders for the latter's opposite; nothing is claimed on nil.
    var compatReport: HermesPluginCompatReport?
    /// Whether this host is a package-manager-managed Hermes, from the one
    /// `.managed` probe P39 added (``HermesManagedInstall``).
    ///
    /// P47 / round-5 decision 1 — the Plugins pane is the second surface
    /// under the read-only lock (`t-8f55df7d`, this pane's half). Activation
    /// is a config write: `cmd_enable` (`hermes_cli/plugins_cmd.py:987`) and
    /// `cmd_disable` (`:1182`) call `_save_plugin_sets` directly (`:1022`,
    /// `:1196`) → `_save_enabled_set` / `_save_disabled_set` (`:910`, `:906`)
    /// → `_write_config_value` (`:115-120`) → `save_config`, whose managed
    /// arm refuses at exit 0 and lets the caller print its success line
    /// anyway (`hermes_cli/config.py:2315-2318` @ `v2026.9.7`).
    /// `_set_plugin_enabled` (`:944`) is a SIBLING caller of the same door,
    /// reached from `cmd_install` (`:754`), `_rescan_after_update` (`:847`)
    /// and the dashboard APIs (`:1711`, `:1786`) — the door is
    /// `_save_plugin_sets` (`:914-916`), not any one of its callers
    /// (P47b review, finding 2).
    ///
    /// `.notManaged` until the probe lands, so the pane renders writable and
    /// then locks — never the reverse flash. A host WITHOUT the marker file
    /// is byte-identical to before (charter C1), and an env-var-only
    /// (`HERMES_MANAGED`) managed host — which Scarf's transport cannot see —
    /// also renders unchanged and falls through to the verdicts
    /// (``HermesPluginInstallOutcome/configWriteRefusal`` and the anchored
    /// markers on enable/disable/update).
    /// Written in exactly ONE production place — `load()`'s detached hop,
    /// from ``HermesManagedInstallCache/shared``. The setter is internal
    /// rather than private only so a test can exercise the lock's real
    /// consumers (`enable` / `disable` / `install`) without a `.managed` file
    /// on disk; `HermesP47Tests.theProbeIsReadInLoadAndNowhereElse` fails if
    /// a second production writer appears.
    var managedInstall: HermesManagedInstall = .notManaged
    var isLoading = false
    var message: String?
    /// Outcome of `message` (GW-F4). This channel carried "Install failed"
    /// and "Installed and enabled" alike, and the header painted both green.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

    private var pluginsDir: String { context.paths.pluginsDir }

    var isManagedHost: Bool { managedInstall.isManaged }

    /// The ONE managed-install banner this pane shows. Names the package
    /// manager `get_managed_system` resolved, because "use your package
    /// manager" is useless without it — the same rule as
    /// `SettingsViewModel.managedBannerText`, with this pane's own scope in
    /// the sentence.
    ///
    /// The scope is deliberately ACTIVATION, not the whole pane. Install,
    /// Update and Remove write the plugin DIRECTORY
    /// (`_install_plugin_core`, `_remove_plugin_core`, the `git pull` in
    /// `cmd_update` — `hermes_cli/plugins_cmd.py:740`, `:893`, `:794-830` @
    /// `v2026.9.7`), which `is_managed()` never guards, and those directory
    /// writes are the whole of what the three verbs do on their own account.
    /// They are not `save_config`-free: `cmd_update` (`:794`) →
    /// `_rescan_after_update` (`:810`) → `_set_plugin_enabled(name,
    /// enable=False)` (`:847`) on a `dangerous` scan verdict, and it prints
    /// `Plugin '<name>' has been disabled.` (`:848-851`) whether or not the
    /// write landed. That refusal is caught by the VERDICT
    /// (``HermesPluginsUpdateVerdict/judge``, whose `managedRefusalAnchored`
    /// match wins over the success line), not by the lock — P47's rationale
    /// that "only `_set_plugin_enabled` reaches `save_config`" was false
    /// (P47b review, finding 3). Locking a control Hermes
    /// would honour is the round-4-review mistake in reverse, and a managed
    /// host has more reason to manage its plugin directory, not less. What
    /// the lock covers: the Enable/Disable buttons and the install sheet's
    /// "Enable after installing" toggle, whose write is the refused one.
    var managedBannerText: String? {
        guard let system = managedInstall.system else { return nil }
        return String(localized: "This Hermes is managed by \(system). Enabling and disabling plugins is read-only here — change it in your package manager's configuration and re-deploy.")
    }

    /// Activation state comes from Hermes, never from the filesystem.
    ///
    /// Two paths, because `plugins list --json` has a version floor of
    /// v0.16.0 (verified: the flag is absent from the `plugins list`
    /// subparser at v2026.5.29.2 / v0.15.2 and present at v2026.6.5 /
    /// v0.16.0, and a pre-v0.16 host fails the whole command at argparse
    /// time). Below that floor we walk `~/.hermes/plugins/` for the
    /// roster — but read the state out of config.yaml's
    /// `plugins.enabled` / `plugins.disabled`, which is exactly what
    /// `_plugin_status` reads. Both paths therefore agree; only the
    /// transport differs.
    ///
    /// `hasLoaded` lets a plain section re-entry skip the work (the VM
    /// instance is cached in `AppCoordinator`, so it persists across
    /// switches); Reload and post-mutation reloads pass `force: true`.
    @ObservationIgnored private var hasLoaded = false

    func load(force: Bool = false) {
        if !force, hasLoaded || isLoading { return }
        hasLoaded = true
        isLoading = true
        let dir = pluginsDir
        let ctx = context
        let svc = fileService
        // The JSON path is one CLI call; the fallback is listDirectory +
        // (stat × N) + (readManifest × N) — a lot of sync transport ops on
        // remote, and definitively a beach ball if run on main. Detach.
        Task.detached { [weak self] in
            let caps = HermesVersionCache.shared.capabilitiesSync(for: ctx)
            let result: [HermesPlugin] = {
                if caps.hasPluginsListJSON {
                    let cli = svc.runHermesCLI(args: ["plugins", "list", "--json"], timeout: 45)
                    // `parseJSON` returns nil (not []) when it cannot read
                    // the payload, so a broken host falls through to the
                    // directory walk instead of rendering "no plugins".
                    if let entries = HermesPluginList.parseJSON(cli.output) {
                        return entries.map { entry in
                            HermesPlugin(
                                name: entry.name,
                                source: entry.source,
                                activation: entry.status,
                                description: entry.description,
                                version: entry.version,
                                path: "",
                                // `--json` carries no manifest fields, so the
                                // tool-override badge still needs the manifest.
                                // Only user-installed plugins live under
                                // `~/.hermes/plugins/`; probing that path for
                                // bundled entries would be one wasted SSH
                                // round-trip each on a remote host.
                                toolOverride: entry.source == "bundled"
                                    ? false
                                    : Self.readManifestStatic(path: dir + "/" + entry.name, context: ctx).toolOverride
                            )
                        }
                    }
                }
                return Self.walkPluginsDirectory(dir: dir, context: ctx)
            }()
            // `plugins compat` is v0.21.1+ and EXITS 1 when it finds
            // something — that is the finding path, not a failure, so the
            // stdout is parsed regardless of exit code (`cmd_compat`'s
            // `sys.exit(1 if report else 0)`). It runs on the same detached
            // hop as the roster so the pane paints once.
            let compat: HermesPluginCompatReport? = caps.hasPluginsCompat
                ? HermesPluginCompatReport.parse(
                    svc.runHermesCLISplit(args: ["plugins", "compat", "--json"], timeout: 45).stdout)
                : nil
            // P47: one `.managed` stat+read per home, memoized process-wide,
            // on the same detached hop as the roster (charter C10). The
            // capabilities decide how the marker is READ — below v0.20.5
            // `get_managed_system` never opens the file and ANY marker means
            // managed (`hermes_cli/config.py:327-330` @ `v2026.6.19`).
            let managed = HermesManagedInstallCache.shared.managedInstall(for: ctx, capabilities: caps)
            await MainActor.run { [weak self] in
                self?.plugins = result
                self?.compatReport = compat
                self?.managedInstall = managed
                self?.isLoading = false
            }
        }
    }

    /// Pre-v0.16 fallback: roster from disk, activation from config.yaml.
    ///
    /// **What this can and cannot see.** It walks `~/.hermes/plugins/` — the
    /// USER plugin directory — and nothing else. `_discover_all_plugins`
    /// additionally enumerates bundled plugins (from the Hermes package's own
    /// `plugins/` dir, whose location Scarf cannot resolve without the CLI)
    /// and **entry-point** plugins, which are installed as Python packages
    /// and have no directory at all, so no filesystem walk of any kind can
    /// find them. On a pre-v0.16 host this list is therefore a subset, not a
    /// reproduction: it is user-directory plugins only. An earlier note here
    /// implied parity with the CLI; it never had it, and no directory walk
    /// can. The `--json` path (v0.16+) is the complete one. (F9)
    ///
    /// **Activation keys.** `_scan_level` recurses one level, so a plugin at
    /// `plugins/<category>/<name>/` is keyed `<category>/<name>` while a
    /// top-level one is keyed by its manifest `name`. `plugins.enabled` in
    /// config.yaml may list EITHER form, which is why `status` takes both.
    /// Scarf used to walk only depth 0 and pass no key, so a plugin enabled
    /// as `observability/langfuse` was invisible *and* anything enabled by
    /// key rendered `notEnabled` — the fallback quietly disagreed with the
    /// host about what was switched on.
    nonisolated fileprivate static func walkPluginsDirectory(dir: String, context ctx: ServerContext) -> [HermesPlugin] {
        let transport = ctx.makeTransport()
        let lists = HermesPluginList.parseConfigActivationLists(
            ctx.readText(ctx.paths.configYAML) ?? ""
        )
        var out: [HermesPlugin] = []

        /// One directory level. `prefix` is the category segment for depth 1
        /// (empty at depth 0), mirroring `_scan_level`'s recursion.
        func scan(_ base: String, prefix: String, depth: Int) {
            guard let entries = try? transport.listDirectory(base) else { return }
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let path = base + "/" + entry
                guard transport.stat(path)?.isDirectory == true else { continue }
                let manifest = Self.readManifestStatic(path: path, context: ctx)
                guard manifest.hasManifest else {
                    // No manifest here — at depth 0 this is a category
                    // directory holding nested plugins. `_scan_level` stops
                    // recursing at depth >= 1, so we do too.
                    if depth == 0 { scan(path, prefix: entry, depth: 1) }
                    continue
                }
                // `_read_manifest_info`: name defaults to the directory name
                // and is overridden by the manifest's own `name`.
                let name = manifest.name.isEmpty ? entry : manifest.name
                // `key = f"{prefix}/{d.name}" if prefix else name` — note it
                // is the DIRECTORY name after a prefix, not the manifest name.
                let key = prefix.isEmpty ? name : "\(prefix)/\(entry)"
                out.append(HermesPlugin(
                    name: name,
                    source: manifest.source,
                    activation: HermesPluginList.status(
                        name: name,
                        key: key,
                        enabled: lists.enabled,
                        disabled: lists.disabled
                    ),
                    description: "",
                    version: manifest.version,
                    path: path,
                    toolOverride: manifest.toolOverride
                ))
            }
        }

        scan(dir, prefix: "", depth: 0)
        return out
    }

    /// Static form of readManifest used by the detached load task. The
    /// instance form delegates to this so both call paths share logic.
    /// `hasManifest` distinguishes "a plugin directory whose manifest says
    /// nothing" from "not a plugin directory at all" — the walk needs the
    /// latter to know when to recurse into a category folder, and a
    /// three-empty-strings return could not express it.
    ///
    /// `plugin.yaml`/`.yml` takes precedence over `plugin.json`, matching
    /// `_read_manifest_info` and `_is_portable_plugin_dir`.
    nonisolated fileprivate static func readManifestStatic(
        path: String,
        context: ServerContext
    ) -> (name: String, source: String, version: String, toolOverride: Bool, hasManifest: Bool) {
        for yamlPath in [path + "/plugin.yaml", path + "/plugin.yml"] {
            guard let yaml = context.readText(yamlPath) else { continue }
            let parsed = HermesFileService.parseNestedYAML(yaml)
            let name = HermesFileService.stripYAMLQuotes(parsed.values["name"] ?? "")
            let source = HermesFileService.stripYAMLQuotes(parsed.values["source"] ?? parsed.values["repository"] ?? parsed.values["url"] ?? "")
            let version = HermesFileService.stripYAMLQuotes(parsed.values["version"] ?? "")
            // Same boolish helper as every other YAML flag read (P18): a
            // manifest author writing `tool_override: yes` meant the same
            // thing as `true`, and the literal comparison read it as false.
            // (Scarf's own display read — Hermes gates an override on
            // `plugins.entries.<id>.allow_tool_override` in config.yaml,
            // `hermes_cli/plugins.py:568-578` @ v2026.9.7 — so this decides a
            // badge, not behaviour. It should still agree with the `plugin.json`
            // arm below, which uses a real `Bool`.)
            let toolOverride = HermesYAML.boolishValue(parsed.values["tool_override"]) ?? false
            return (name, source, version, toolOverride, true)
        }
        let jsonPath = path + "/plugin.json"
        if let data = context.readData(jsonPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let name = (obj["name"] as? String) ?? ""
            let source = (obj["source"] as? String) ?? (obj["repository"] as? String) ?? (obj["url"] as? String) ?? ""
            let version = (obj["version"] as? String) ?? ""
            // v0.14 — `tool_override: true` opt-in. Accept both spellings
            // because plugin authors might use camelCase.
            let toolOverride = (obj["tool_override"] as? Bool) ?? (obj["toolOverride"] as? Bool) ?? false
            return (name, source, version, toolOverride, true)
        }
        return ("", "", "", false, false)
    }

    // (readManifestStatic above is the new implementation; the instance
    // version was removed because the only caller was the load() walk,
    // which now runs detached and uses the static form.)

    /// What `plugins install` reported, for the post-install sheet.
    ///
    /// The CLI prints things Scarf used to discard entirely: the plugin's
    /// `after-install.md`, the `requires_env` names it still needs in
    /// `~/.hermes/.env`, and the "restart the gateway" instruction
    /// without which the plugin does not load in the running gateway.
    struct InstallReport: Identifiable, Sendable, Equatable {
        var id: String { identifier }
        let identifier: String
        let outcome: HermesPluginInstallOutcome
        let failed: Bool
    }

    var installReport: InstallReport?

    /// Installs a plugin, telling the CLI **explicitly** whether to enable
    /// it, per the user's choice in the install sheet.
    ///
    /// `--enable` / `--no-enable` are a mutually exclusive argparse group
    /// on `plugins install`, present since at least v0.12.0 (verified at
    /// v2026.4.30), so no capability gate is needed. Passing neither makes
    /// `cmd_install` prompt "Enable '<name>' now? [y/N]" on stdin — and on
    /// a non-tty it silently answers **no**, which is why Scarf's installs
    /// reported "Installed" while leaving the plugin inert.
    func install(_ identifier: String, enable: Bool) {
        isLoading = true
        // In-progress, not an outcome — nothing has failed yet.
        message = String(localized: "Installing \(identifier)…")
        messageIsFailure = false
        // And the unconfirmed flag (P55b): it never auto-clears, so a prior
        // neutral verdict would otherwise seal this in-progress line amber.
        messageIsUnconfirmed = false
        // P47: through `cliRunner`, the same injectable seam `enable` /
        // `disable` / `update` use. The verdict rule that matters here — a
        // refusal outranks the `✓ Plugin <name> enabled.` line printed on top
        // of it — lives on this path, so a test that cannot reach the real
        // path proves nothing about the shipped behaviour.
        let run = cliRunner
        Task.detached { [weak self] in
            let result = run(
                ["plugins", "install", enable ? "--enable" : "--no-enable", "--", identifier],
                180
            )
            let outcome = HermesPluginInstallOutcome.parse(result.output)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoading = false
                // `cmd_install` does `sys.exit(1)` on a blocked scan or an
                // unresolvable identifier, so a nonzero exit is real — but
                // exit 0 only means "the process finished", and the enable
                // outcome has to come out of stdout.
                let failed = result.exitCode != 0
                // `cmd_install` (plugins_cmd.py:764) discards
                // `_run_capability_consent`'s bool the same way `enable` and
                // `update` do, so a capability-declaring plugin installs
                // "successfully" with nothing granted (:1092-1098). That is
                // the install's real outcome, not a footnote in the report.
                if !failed, outcome.capabilitiesNotGranted {
                    self.applySaveOutcome(.failure(
                        Self.friendlyPluginFailure(HermesCLIMarkers.pluginsConsentRefusal)
                            ?? String(localized: "Installed, but its capabilities were not granted")
                    ))
                } else if !failed, enable, let refusal = outcome.configWriteRefusal {
                    // P47 / decision 1, the FALLTHROUGH half: an env-var-only
                    // managed host is invisible to the `.managed` probe, so
                    // the lock above never armed and `--enable` really did
                    // reach `save_config`'s refusal — which printed
                    // `✓ Plugin <name> enabled.` on top of it at exit 0
                    // (`plugins_cmd.py:754-755`). The clone DID happen, so
                    // this is a partial write, not a failed install; it is
                    // never "Installed and enabled".
                    self.applySaveOutcome(.failure(
                        String(localized: "Installed, but it could not be enabled: \(refusal)")
                    ))
                } else {
                    self.applySaveOutcome(
                        failed
                            ? .failure(String(localized: "Install failed"))
                            : .success(outcome.enabled
                                       ? String(localized: "Installed and enabled")
                                       : String(localized: "Installed (not enabled)"))
                    )
                }
                self.installReport = InstallReport(identifier: identifier, outcome: outcome, failed: failed)
                self.load(force: true)
            }
        }
    }

    /// `cmd_update` (plugins_cmd.py:822 at v2026.9.7) calls
    /// `_run_capability_consent(...)` and DISCARDS its `bool` exactly as
    /// `cmd_enable` does — round 1 only caught `enable`. Its non-TTY arm
    /// (:1092-1098) is the one Scarf always takes, so a capability-declaring
    /// plugin updated from Scarf reported a plain "Updated" while its
    /// capabilities were left ungranted (fail closed).
    ///
    /// Both success lines are printed AFTER the consent screen (:826, :828),
    /// so both markers are present by design and the refusal has to win —
    /// same shape as `enable`. The consent call arrives at v2026.8.13 and the
    /// two success lines go back to v2026.6.19, so an older host prints a
    /// success line and no refusal and is judged exactly as before (C1).
    /// P40 / round-4 decision 3: `update` has THREE outcomes. When the
    /// post-pull security scan returns `dangerous`, `_rescan_after_update`
    /// DISABLES the plugin (`hermes_cli/plugins_cmd.py:845-851` @ v2026.9.7)
    /// and `cmd_update` prints `✓ Plugin <name> updated.` (`:828`) anyway —
    /// both at exit 0. That is neither a failure (the tree really was pulled)
    /// nor the plain "Updated" Scarf used to claim (the plugin is off now),
    /// so the banner says so and quotes Hermes's own reason line (`:843`).
    /// See ``HermesPluginsUpdateVerdict``, which also anchors the success side
    /// against the raw `git pull` body and the scan report.
    func update(_ plugin: HermesPlugin) {
        let run = cliRunner
        let name = plugin.name
        Task.detached { [weak self] in
            let result = run(HermesPluginsUpdateVerdict.argv(name: name), 60)
            let outcome = HermesPluginsUpdateVerdict.judge(
                output: result.output, exitCode: result.exitCode
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applySaveOutcome(
                    outcome.succeeded
                        ? .success(outcome.warning ?? String(localized: "Updated"))
                        : .failure(Self.friendlyPluginFailure(outcome.detail)
                            ?? String(localized: "Failed"))
                )
                self.load(force: true)
            }
        }
    }

    func remove(_ plugin: HermesPlugin) {
        runAndReload(["plugins", "remove", "--", plugin.name], success: "Removed")
    }

    /// Enables a plugin, answering the built-in-tool-override consent
    /// question non-interactively.
    ///
    /// `plugins enable` prompts before granting a plugin permission to
    /// replace built-ins like `shell_exec` / `write_file`. Scarf has no
    /// tty, so the prompt would hang or fail closed — the consent was
    /// simply unreachable from the app. `--allow-tool-override` /
    /// `--no-allow-tool-override` (a mutually exclusive group) skip it.
    ///
    /// **Version floor: v0.18.0.** The flags first appear in the
    /// `plugins enable` parser at v2026.7.1; they are absent at
    /// v2026.6.19 (v0.17.0). Older hosts get the bare command, exactly as
    /// before — passing an unknown flag would fail the whole enable.
    ///
    /// `allowToolOverride` must come from an explicit in-app confirmation
    /// (`PluginsView`'s tool-override dialog). It is never inferred.
    func enable(_ plugin: HermesPlugin, allowToolOverride: Bool? = nil) {
        // Flags first, then `--`, then the positional: argparse reads
        // everything after the first `--` as a positional, so a flag appended
        // afterwards would exit 2.
        // P47: the lock disables the control, so reaching here means a
        // programmatic or keyboard path around it. Refuse locally rather than
        // shelling a command whose only outcome is Hermes's exit-0 refusal.
        if let refusal = managedBannerText {
            applySaveOutcome(.failure(refusal))
            return
        }
        var args = ["plugins", "enable"]
        if let allowToolOverride, supportsToolOverrideFlags {
            args.append(allowToolOverride ? "--allow-tool-override" : "--no-allow-tool-override")
        }
        args += ["--", plugin.name]
        runAndReload(
            args,
            success: "Enabled",
            successMarkers: HermesCLIMarkers.pluginsEnableSuccess,
            failureMarkers: HermesCLIMarkers.pluginsEnableFailure,
            // P39 (round-4 review): the managed refusal is matched ANCHORED.
            // `plugins update` prints the raw `git pull` output and the
            // post-update scan report (`hermes_cli/plugins_cmd.py:829`, `:844`)
            // — text Hermes does not control — and these verdicts run
            // `failureWins`, so a bare `is managed by` substring in a commit
            // message or a scan finding turned a completed run into a reported
            // failure. `save_config`'s refusal is at column 0.
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            // `cmd_enable` prints the green "enabled." line (:1023) BEFORE it
            // runs the consent screen (:1033), so both markers are present by
            // design and the refusal has to win.
            failureWins: true
        )
    }

    /// True when this host's `plugins enable` understands the
    /// tool-override consent flags (v0.18+). Drives whether the view
    /// offers the grant affordance at all.
    var supportsToolOverrideFlags: Bool {
        HermesVersionCache.shared.cached(for: context)?.hasPluginEnableToolOverrideFlag ?? false
    }

    func disable(_ plugin: HermesPlugin) {
        // P47: same local refusal as `enable` — one door, both directions.
        if let refusal = managedBannerText {
            applySaveOutcome(.failure(refusal))
            return
        }
        runAndReload(
            ["plugins", "disable", "--", plugin.name],
            success: "Disabled",
            successMarkers: HermesCLIMarkers.pluginsDisableSuccess,
            failureMarkers: HermesCLIMarkers.pluginsDisableFailure,
            // P39 (round-4 review): the managed refusal is matched ANCHORED.
            // `plugins update` prints the raw `git pull` output and the
            // post-update scan report (`hermes_cli/plugins_cmd.py:829`, `:844`)
            // — text Hermes does not control — and these verdicts run
            // `failureWins`, so a bare `is managed by` substring in a commit
            // message or a scan finding turned a completed run into a reported
            // failure. `save_config`'s refusal is at column 0.
            anchoredFailureMarkers: HermesCLIMarkers.managedRefusalAnchored,
            // P39: `cmd_disable` writes config.yaml through `save_config`
            // (`hermes_cli/plugins_cmd.py:115-120`), whose managed-install arm
            // prints to stderr and RETURNS (`hermes_cli/config.py:2316-2318`,
            // exit 0) — and `:1196-1198` then prints `⊘ Plugin … disabled.`
            // anyway. Both markers in one run, so the refusal has to win, the
            // same shape `enable` already had for the consent screen.
            failureWins: true
        )
    }

    /// Runs a `plugins` verb and judges it by what the CLI printed.
    ///
    /// `hermes plugins enable` exits 0 even when the enable did not fully
    /// happen: `cmd_enable` (hermes_cli/plugins_cmd.py:1033 at v2026.9.7)
    /// calls `_run_capability_consent(...)` and discards its `bool`, and that
    /// function's non-TTY arm (:1092-1098) prints
    /// `Non-interactive session: capabilities NOT granted (fail closed).` and
    /// returns False. Scarf has NO tty, so for any plugin whose manifest
    /// declares `capabilities:` that is the arm it always takes — the plugin
    /// is on the allow-list but runs without the host surfaces it asked for,
    /// which is not what a plain "Enabled" toast says (charter C5).
    ///
    /// The success markers are the CLI's own confirmations —
    /// `Plugin <key> enabled. Takes effect on next session.` (:1023) /
    /// `disabled.` (:1198), and the `is already enabled/disabled.` idempotent
    /// lines (:1012, :1191). Both `Takes effect on next session.` spellings go
    /// back to v2026.6.19:801,833 (charter C1).
    /// One plain sentence for the refusal Scarf hits most, and a bounded quote
    /// of the CLI's own line otherwise.
    ///
    /// The consent refusal (plugins_cmd.py:1092-1098) is ~230 characters whose
    /// ACTIONABLE half is its last clause, so a leading truncation would cut
    /// off exactly the part the user needs — the same trap the v0.21.1 cron
    /// lifecycle-guard message set. It gets its own sentence instead.
    nonisolated static func friendlyPluginFailure(_ detail: String?) -> String? {
        guard let detail, !detail.isEmpty else { return nil }
        if detail.contains(HermesCLIMarkers.pluginsConsentRefusal) {
            // Deliberately verb-neutral: the same consent screen runs from
            // `enable` (:1033), `install` (:764) and `update` (:822), so a
            // sentence that opened with "Enabled," would be wrong on two of
            // the three.
            return String(localized: "The plugin's requested capabilities were NOT granted — Hermes fails closed without a terminal. Grant them with `hermes plugins enable` in a terminal; the plugin should otherwise degrade gracefully.")
        }
        return String(detail.prefix(200))
    }

    /// `successMarkers: nil` keeps the exit code as the verdict, which is
    /// sound for `remove` alone: every refusal `cmd_remove` can reach goes
    /// through `_fail` (:895, :412, :415 → :80-83), which `sys.exit(1)`s. Even
    /// there the exit code is not the MESSAGE — the `_fail` line is the only
    /// thing that says what went wrong — so the detail is carried across.
    /// The `_fail` line out of a nonzero `plugins` run. `detail: nil` used to
    /// throw it away and leave the user a bare "Failed", yet it is the only
    /// text that says what happened (`Error: Could not remove plugin 'x': …`,
    /// plugins_cmd.py:895). Prefer the line carrying `Error:` over the last
    /// line: `_require_installed_plugin` (:415) puts a second line —
    /// `Installed plugins: …` — after the reason.
    nonisolated static func failLine(_ output: String) -> String? {
        let lines = HermesCLIVerdict.significantLines(output)
        return lines.first { $0.contains("Error:") } ?? lines.last
    }

    private func runAndReload(
        _ args: [String],
        success: String,
        successMarkers: [String]? = nil,
        failureMarkers: [String] = [],
        anchoredFailureMarkers: [String] = [],
        failureWins: Bool = false
    ) {
        let run = cliRunner
        Task.detached { [weak self] in
            let result = run(args, 60)
            let outcome: HermesCLIOutcome = successMarkers.map { markers in
                HermesCLIVerdict.judge(
                    output: result.output,
                    exitCode: result.exitCode,
                    successMarkers: markers,
                    failureMarkers: failureMarkers,
                    anchoredFailureMarkers: anchoredFailureMarkers,
                    failureWins: failureWins
                )
            } ?? HermesCLIOutcome(
                succeeded: result.exitCode == 0,
                detail: result.exitCode == 0 ? nil : Self.failLine(result.output)
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applySaveOutcome(
                    outcome.succeeded
                        ? .success(success)
                        : .failure(Self.friendlyPluginFailure(outcome.detail)
                            ?? String(localized: "Failed"))
                )
                self.load(force: true)
            }
        }
    }
}
