import Foundation

/// A plugin's manifest fields, as far as Scarf reads them.
///
/// `hasManifest` distinguishes "a plugin directory whose manifest says
/// nothing" from "not a plugin directory at all" — the walk needs the
/// latter to know when to recurse into a category folder, and three empty
/// strings could not express it.
public struct HermesPluginManifest: Sendable, Equatable {
    public let name: String
    public let source: String
    public let version: String
    public let toolOverride: Bool
    public let hasManifest: Bool

    public static let none = HermesPluginManifest(
        name: "", source: "", version: "", toolOverride: false, hasManifest: false
    )
}

/// One plugin found by walking `~/.hermes/plugins/`.
public struct HermesPluginDirectoryEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let name: String
    public let source: String
    public let version: String
    /// Absolute directory path.
    public let path: String
    public let activation: HermesPluginActivation
    public let toolOverride: Bool
}

/// The filesystem roster of user plugins, with activation read from
/// config.yaml — the fallback both the Mac Plugins pane and the iOS
/// Plugins view use below `hasPluginsListJSON` (v0.16.0), or when
/// `plugins list --json` can't be read.
///
/// Moved here from the Mac `PluginsViewModel` so iOS stops carrying its
/// own walk. The iOS copy read Enabled/Disabled from a `.disabled` marker
/// file Hermes never writes, so every plugin showed "Enabled", and it
/// walked only depth 0 (S10-F4).
///
/// **What this can and cannot see.** It walks `~/.hermes/plugins/` — the
/// USER plugin directory — and nothing else. `_discover_all_plugins`
/// additionally enumerates bundled plugins (from the Hermes package's own
/// `plugins/` dir, whose location Scarf cannot resolve without the CLI)
/// and **entry-point** plugins, which are installed as Python packages and
/// have no directory at all. On a pre-v0.16 host this list is therefore a
/// subset: user-directory plugins only. The `--json` path is the complete
/// one. (F9)
///
/// **Activation keys.** `_scan_level` recurses one level, so a plugin at
/// `plugins/<category>/<name>/` is keyed `<category>/<name>` while a
/// top-level one is keyed by its manifest `name`. `plugins.enabled` in
/// config.yaml may list EITHER form, which is why `status` takes both.
/// State itself comes only from `plugins.enabled` / `plugins.disabled`,
/// exactly as `_plugin_status` reads it (`hermes_cli/plugins_cmd.py:
/// 1638-1651` @ v2026.9.24).
public enum HermesPluginDirectoryScanner {

    /// Synchronous and transport-backed: run it off the main actor.
    public static func walk(dir: String, context ctx: ServerContext) -> [HermesPluginDirectoryEntry] {
        let transport = ctx.makeTransport()
        let lists = HermesPluginList.parseConfigActivationLists(
            ctx.readText(ctx.paths.configYAML) ?? ""
        )
        var out: [HermesPluginDirectoryEntry] = []

        /// One directory level. `prefix` is the category segment for depth 1
        /// (empty at depth 0), mirroring `_scan_level`'s recursion.
        func scan(_ base: String, prefix: String, depth: Int) {
            guard let entries = try? transport.listDirectory(base) else { return }
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let path = base + "/" + entry
                guard transport.stat(path)?.isDirectory == true else { continue }
                let manifest = readManifest(path: path, context: ctx)
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
                out.append(HermesPluginDirectoryEntry(
                    name: name,
                    source: manifest.source,
                    version: manifest.version,
                    path: path,
                    activation: HermesPluginList.status(
                        name: name,
                        key: key,
                        enabled: lists.enabled,
                        disabled: lists.disabled
                    ),
                    toolOverride: manifest.toolOverride
                ))
            }
        }

        scan(dir, prefix: "", depth: 0)
        return out
    }

    /// Reads `plugin.yaml` / `plugin.yml`, then `plugin.json`. YAML takes
    /// precedence, matching `_read_manifest_info` and
    /// `_is_portable_plugin_dir`.
    public static func readManifest(path: String, context: ServerContext) -> HermesPluginManifest {
        for yamlPath in [path + "/plugin.yaml", path + "/plugin.yml"] {
            guard let yaml = context.readText(yamlPath) else { continue }
            let parsed = HermesYAML.parseNestedYAML(yaml)
            let name = HermesYAML.stripYAMLQuotes(parsed.values["name"] ?? "")
            let source = HermesYAML.stripYAMLQuotes(parsed.values["source"] ?? parsed.values["repository"] ?? parsed.values["url"] ?? "")
            let version = HermesYAML.stripYAMLQuotes(parsed.values["version"] ?? "")
            // Same boolish helper as every other YAML flag read (P18): a
            // manifest author writing `tool_override: yes` meant the same
            // thing as `true`, and the literal comparison read it as false.
            // (Scarf's own display read — Hermes gates an override on
            // `plugins.entries.<id>.allow_tool_override` in config.yaml,
            // `hermes_cli/plugins.py:568-578` @ v2026.9.7 — so this decides a
            // badge, not behaviour. It should still agree with the `plugin.json`
            // arm below, which uses a real `Bool`.)
            let toolOverride = HermesYAML.boolishValue(parsed.values["tool_override"]) ?? false
            return HermesPluginManifest(
                name: name, source: source, version: version,
                toolOverride: toolOverride, hasManifest: true
            )
        }
        if let data = context.readData(path + "/plugin.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let name = (obj["name"] as? String) ?? ""
            let source = (obj["source"] as? String) ?? (obj["repository"] as? String) ?? (obj["url"] as? String) ?? ""
            let version = (obj["version"] as? String) ?? ""
            // v0.14 — `tool_override: true` opt-in. Accept both spellings
            // because plugin authors might use camelCase.
            let toolOverride = (obj["tool_override"] as? Bool) ?? (obj["toolOverride"] as? Bool) ?? false
            return HermesPluginManifest(
                name: name, source: source, version: version,
                toolOverride: toolOverride, hasManifest: true
            )
        }
        return .none
    }
}
