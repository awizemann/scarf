import Foundation

/// A plugin's activation state as Hermes itself reports it.
///
/// Verified against `hermes_cli/plugins_cmd.py::_plugin_status` at
/// v2026.8.31 (v0.21.0) — the CLI reports exactly three states, derived
/// from the `plugins.enabled` / `plugins.disabled` **lists in
/// config.yaml**. There is no `.disabled` marker file anywhere in the
/// Hermes tree; Scarf used to invent one.
///
/// ```python
/// def _plugin_status(name, enabled, disabled, key=""):
///     if name in disabled or key in disabled: return "disabled"
///     if name in enabled or key in enabled:   return "enabled"
///     return "not enabled"
/// ```
///
/// `notEnabled` is a real, distinct state: the plugin is installed on
/// disk but absent from both lists, so the runtime never loads it.
/// Collapsing it into "enabled" (which the directory walk did) told the
/// user a plugin was live when it was inert.
public enum HermesPluginActivation: String, Sendable, Equatable, CaseIterable {
    case enabled
    case disabled
    /// Installed but in neither list — Hermes prints `not enabled`.
    case notEnabled

    /// Maps the CLI's exact status strings. Unknown values fall back to
    /// `notEnabled` (fail closed: never claim a plugin is live).
    public static func from(cliStatus: String) -> HermesPluginActivation {
        switch cliStatus.trimmingCharacters(in: .whitespaces).lowercased() {
        case "enabled": return .enabled
        case "disabled": return .disabled
        default: return .notEnabled
        }
    }

    /// True only for the state where the plugin actually loads.
    public var isActive: Bool { self == .enabled }
}

/// One row of `hermes plugins list --json`.
///
/// Schema verified against `plugins_cmd.py::cmd_list` at v2026.8.31 —
/// the payload is a top-level JSON **array** of objects with exactly
/// these five string keys:
///
/// ```python
/// payload = [{"name": name, "status": _plugin_status(...),
///             "version": str(version), "description": description,
///             "source": source} for ... in entries]
/// print(json.dumps(payload, indent=2))
/// ```
///
/// `version` is `str(version)` CLI-side, so it is always a JSON string
/// even when the manifest carried a number.
public struct HermesPluginListEntry: Sendable, Equatable, Identifiable, Decodable {
    public var id: String { name }
    public let name: String
    public let status: HermesPluginActivation
    public let version: String
    public let description: String
    public let source: String

    public init(name: String, status: HermesPluginActivation, version: String, description: String, source: String) {
        self.name = name
        self.status = status
        self.version = version
        self.description = description
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case name, status, version, description, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        status = HermesPluginActivation.from(cliStatus: try c.decodeIfPresent(String.self, forKey: .status) ?? "")
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) .flatMap { $0 } ?? ""
        description = (try? c.decodeIfPresent(String.self, forKey: .description)).flatMap { $0 } ?? ""
        source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap { $0 } ?? ""
    }
}

/// Readers for plugin activation state.
///
/// Two paths, because `--json` has a version floor:
///
/// * **v0.16.0+** — `hermes plugins list --json`. Verified: the flag is
///   absent from the `plugins list` parser at v2026.5.29.2 (v0.15.2) and
///   present at v2026.6.5 (v0.16.0), so pre-v0.16 hosts fail the whole
///   command at argparse time. Gate on
///   `HermesCapabilities.hasPluginsListJSON`.
/// * **below that** — read the same two lists straight out of
///   config.yaml. That is byte-identical to what `_plugin_status` does,
///   so both paths agree; only the transport differs.
public enum HermesPluginList {

    /// Decodes `hermes plugins list --json` stdout.
    ///
    /// Returns `nil` (not `[]`) when the payload is unparseable, so the
    /// caller can distinguish "host really has no plugins" from "we did
    /// not understand the output" and fall back instead of rendering an
    /// empty list as fact.
    public static func parseJSON(_ output: String) -> [HermesPluginListEntry]? {
        // Rich/`hermes` can print banners before the payload on some
        // hosts; scan for the first `[` that begins a decodable array.
        guard let start = output.firstIndex(of: "[") else { return nil }
        let candidate = String(output[start...])
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([HermesPluginListEntry].self, from: data)
    }

    /// Extracts `plugins.enabled` / `plugins.disabled` from config.yaml.
    ///
    /// Hermes writes both as block sequences under a `plugins:` mapping
    /// (`_save_enabled_set` / `_save_disabled_set` assign a sorted list
    /// and round-trip through the YAML dumper), e.g.
    ///
    /// ```yaml
    /// plugins:
    ///   enabled:
    ///   - chrome-profiles
    ///   disabled:
    ///     - noisy-plugin
    /// ```
    ///
    /// Flow sequences (`enabled: [a, b]`) are accepted too, because a
    /// hand-edited config.yaml may use them.
    public static func parseConfigActivationLists(_ yaml: String) -> (enabled: Set<String>, disabled: Set<String>) {
        var enabled: Set<String> = []
        var disabled: Set<String> = []

        var inPlugins = false
        /// Which list we are currently collecting items into.
        var currentKey: String?
        /// Indentation of the `enabled:` / `disabled:` key, so a deeper
        /// unrelated mapping cannot silently continue the sequence.
        var keyIndent = 0

        func indent(of line: Substring) -> Int {
            line.prefix(while: { $0 == " " }).count
        }

        for rawLine in yaml.components(separatedBy: "\n") {
            let line = Substring(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let col = indent(of: line)

            if col == 0 {
                inPlugins = (trimmed == "plugins:")
                currentKey = nil
                continue
            }
            guard inPlugins else { continue }

            // A sequence item belonging to the list we are collecting.
            if trimmed.hasPrefix("-"), let key = currentKey, col > keyIndent - 1 {
                let item = scalar(String(trimmed.dropFirst()))
                guard !item.isEmpty else { continue }
                if key == "enabled" { enabled.insert(item) } else { disabled.insert(item) }
                continue
            }

            // A new key inside `plugins:`.
            currentKey = nil
            for key in ["enabled", "disabled"] where trimmed.hasPrefix(key + ":") {
                let rest = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                keyIndent = col
                if rest.isEmpty {
                    currentKey = key            // block sequence follows
                } else if rest.hasPrefix("[") {
                    let inner = rest.dropFirst().prefix(while: { $0 != "]" })
                    let items = inner.split(separator: ",").map { scalar(String($0)) }.filter { !$0.isEmpty }
                    if key == "enabled" { enabled.formUnion(items) } else { disabled.formUnion(items) }
                }
                break
            }
        }
        return (enabled, disabled)
    }

    /// Resolves one plugin's state exactly as `_plugin_status` does,
    /// including the registry `key` alias (`observability/langfuse`)
    /// that `_discover_all_plugins` emits alongside the bare name.
    public static func status(
        name: String,
        key: String = "",
        enabled: Set<String>,
        disabled: Set<String>
    ) -> HermesPluginActivation {
        if disabled.contains(name) || (!key.isEmpty && disabled.contains(key)) { return .disabled }
        if enabled.contains(name) || (!key.isEmpty && enabled.contains(key)) { return .enabled }
        return .notEnabled
    }

    private static func scalar(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let hash = value.firstIndex(of: "#"), value.first != "#" {
            // Trailing comment — only when preceded by whitespace, so a
            // plugin name containing '#' is not truncated.
            let before = value.index(before: hash)
            if value[before] == " " { value = String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
        }
        if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// Outcome of `hermes plugins install`.
///
/// The CLI `sys.exit(1)`s on a blocked scan or a resolve failure, so a
/// nonzero exit is trustworthy — but a **zero** exit says nothing about
/// whether the plugin ended up enabled. `cmd_install` prints one of two
/// mutually exclusive lines, and Scarf reported "Installed" for both.
public struct HermesPluginInstallOutcome: Sendable, Equatable {
    /// True when the CLI confirmed `Plugin <name> enabled.`
    public let enabled: Bool
    /// True when it printed `Plugin installed but not enabled.`
    public let installedDisabled: Bool
    /// `requires_env` names the plugin declared but that are unset in
    /// `~/.hermes/.env` — the CLI prints these and Scarf swallowed them.
    public let missingEnvVars: [String]
    /// True when the CLI emitted its `hermes gateway restart` reminder.
    public let needsGatewayRestart: Bool
    /// The plugin's `after-install.md` (or default confirmation) and any
    /// dependency notes, verbatim, for display.
    public let notes: String

    public init(enabled: Bool, installedDisabled: Bool, missingEnvVars: [String], needsGatewayRestart: Bool, notes: String) {
        self.enabled = enabled
        self.installedDisabled = installedDisabled
        self.missingEnvVars = missingEnvVars
        self.needsGatewayRestart = needsGatewayRestart
        self.notes = notes
    }

    /// Parses `hermes plugins install` stdout.
    ///
    /// Sentinels verified in `plugins_cmd.py::cmd_install` at v2026.8.31:
    /// `✓ Plugin <name> enabled.` / `Plugin installed but not enabled.` /
    /// `Restart the gateway for the plugin to take effect:`. Rich strips
    /// its own markup before printing, so the tags never reach stdout,
    /// but the ✓/glyph prefix and indentation both vary — match on the
    /// stable substrings only.
    public static func parse(_ output: String) -> HermesPluginInstallOutcome {
        let lower = output.lowercased()
        let enabled = lower.contains("] enabled.")
            || lower.range(of: "plugin .* enabled\\.", options: .regularExpression) != nil
        let disabled = lower.contains("installed but not enabled")
        var missing: [String] = []
        for raw in output.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // `_prompt_plugin_env_vars` lists each unset var on its own
            // line; the names are shell-style uppercase identifiers.
            guard trimmed.range(of: "^[•\\-*]?\\s*[A-Z][A-Z0-9_]{2,}\\s*$", options: .regularExpression) != nil else { continue }
            let name = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "•-* "))
            if !name.isEmpty { missing.append(name) }
        }
        return HermesPluginInstallOutcome(
            enabled: enabled && !disabled,
            installedDisabled: disabled,
            missingEnvVars: missing,
            needsGatewayRestart: lower.contains("restart the gateway"),
            notes: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
