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
final class PluginsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "PluginsViewModel")
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }

    var plugins: [HermesPlugin] = []
    var isLoading = false
    var message: String?

    private var pluginsDir: String { context.paths.pluginsDir }

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
            await MainActor.run { [weak self] in
                self?.plugins = result
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
            let toolOverrideRaw = HermesFileService.stripYAMLQuotes(parsed.values["tool_override"] ?? "").lowercased()
            return (name, source, version, toolOverrideRaw == "true", true)
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
        message = "Installing \(identifier)…"
        Task.detached { [weak self, fileService] in
            let result = fileService.runHermesCLI(
                args: ["plugins", "install", enable ? "--enable" : "--no-enable", "--", identifier],
                timeout: 180
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
                self.message = failed ? "Install failed" : (outcome.enabled ? "Installed and enabled" : "Installed (not enabled)")
                self.installReport = InstallReport(identifier: identifier, outcome: outcome, failed: failed)
                self.load(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    func update(_ plugin: HermesPlugin) {
        runAndReload(["plugins", "update", plugin.name], success: "Updated")
    }

    func remove(_ plugin: HermesPlugin) {
        runAndReload(["plugins", "remove", plugin.name], success: "Removed")
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
        var args = ["plugins", "enable", plugin.name]
        if let allowToolOverride, supportsToolOverrideFlags {
            args.append(allowToolOverride ? "--allow-tool-override" : "--no-allow-tool-override")
        }
        runAndReload(args, success: "Enabled")
    }

    /// True when this host's `plugins enable` understands the
    /// tool-override consent flags (v0.18+). Drives whether the view
    /// offers the grant affordance at all.
    var supportsToolOverrideFlags: Bool {
        HermesVersionCache.shared.cached(for: context)?.hasPluginEnableToolOverrideFlag ?? false
    }

    func disable(_ plugin: HermesPlugin) {
        runAndReload(["plugins", "disable", plugin.name], success: "Disabled")
    }

    private func runAndReload(_ args: [String], success: String) {
        Task.detached { [weak self, fileService] in
            let result = fileService.runHermesCLI(args: args, timeout: 60)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.message = result.exitCode == 0 ? success : "Failed"
                self.load(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }
}
