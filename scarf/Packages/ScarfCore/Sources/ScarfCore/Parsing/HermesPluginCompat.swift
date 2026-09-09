import Foundation

/// One pre-decomposition import found in a plugin's source.
///
/// Mirrors `hermes_cli/plugin_compat.py`'s frozen `Hit` dataclass, which
/// `hermes plugins compat --json` serialises with `h.__dict__`:
///
/// ```python
/// @dataclass(frozen=True)
/// class Hit:
///     file: str   # path relative to the plugin dir
///     line: int
///     old: str    # "facade.name"
///     new: str    # "target_module.name" (or the target module)
/// ```
/// Not `Decodable`: the payload is read with `JSONSerialization` in
/// `HermesPluginCompatReport.parse`, which tolerates a `line` that arrives
/// as a JSON string. A hand-written `init(from:)` used to shadow that and
/// was never called by anything.
public struct HermesPluginCompatHit: Sendable, Equatable, Identifiable {
    public var id: String { "\(file):\(line):\(old)" }
    public let file: String
    public let line: Int
    /// The pre-decomposition dotted path the plugin still imports.
    public let old: String
    /// Where that name lives now — or, for a restored definition with no
    /// new home, Hermes's own `"… (removed; no replacement — vendor a
    /// copy)"` sentence. Rendered verbatim; Scarf does not interpret it.
    public let new: String

    public init(file: String, line: Int, old: String, new: String) {
        self.file = file
        self.line = line
        self.old = old
        self.new = new
    }
}

/// The `hermes plugins compat --json` payload: which installed plugins
/// import module paths the Sep 2026 decomposition removes, and when they
/// stop loading.
///
/// Emitted by `hermes_cli/plugins_cmd.py::cmd_compat`:
///
/// ```python
/// print(json.dumps({"removal_date": COMPAT_REMOVAL, "in_effect": removal_in_effect(),
///                   "plugins": {k: [h.__dict__ for h in v] for k, v in report.items()}}, indent=2))
/// sys.exit(1 if report else 0)
/// ```
///
/// **Exit 1 is the FINDING, not a failure** — same contract as `cron
/// doctor`. A caller that treats a non-zero exit as "command failed"
/// throws away the only warning a user gets before their plugins stop
/// loading, so `parse` reads stdout regardless of exit code.
public struct HermesPluginCompatReport: Sendable, Equatable {
    /// ISO date (`COMPAT_REMOVAL`, `2026-09-14` at v0.21.1) after which an
    /// affected plugin is not loaded. Kept as the string Hermes printed:
    /// it is display copy, and a future Hermes moving the date must not be
    /// silently re-interpreted by a Scarf date parse.
    public let removalDate: String
    /// True once that date has passed (or the compat layer is already
    /// gone) — i.e. affected plugins are ALREADY not loading.
    public let inEffect: Bool
    /// Plugin name → the imports that will break. Only affected plugins
    /// appear; a clean host reports `{}`.
    public let plugins: [String: [HermesPluginCompatHit]]

    public init(removalDate: String, inEffect: Bool, plugins: [String: [HermesPluginCompatHit]]) {
        self.removalDate = removalDate
        self.inEffect = inEffect
        self.plugins = plugins
    }

    /// Affected plugin names, sorted the way the CLI sorts its tables.
    public var affectedNames: [String] { plugins.keys.sorted() }

    /// Whether anything at all is affected. A report with no affected
    /// plugins renders nothing — no "all clear" banner competing for
    /// attention with the plugin list.
    public var isAffected: Bool { !plugins.isEmpty }

    /// Hits for one plugin, ordered by file then line so the banner and
    /// the row detail read in source order.
    public func hits(for plugin: String) -> [HermesPluginCompatHit] {
        (plugins[plugin] ?? []).sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    /// Decode `plugins compat --json` stdout. Returns `nil` when the
    /// payload isn't there (older host, argparse error, transport failure)
    /// so callers can tell "no answer" from "clean host" — rendering a
    /// green all-clear over a command that never ran would be the worst
    /// possible outcome for a surface whose entire job is a warning.
    public static func parse(_ output: String) -> HermesPluginCompatReport? {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // `plugins` is the one key that must be present and of the right
        // shape; the other two are display metadata that degrade.
        guard let raw = root["plugins"] as? [String: Any] else { return nil }
        var plugins: [String: [HermesPluginCompatHit]] = [:]
        for (name, value) in raw {
            guard let rows = value as? [Any] else { continue }
            let hits: [HermesPluginCompatHit] = rows.compactMap { row in
                guard let dict = row as? [String: Any] else { return nil }
                return HermesPluginCompatHit(
                    file: dict["file"] as? String ?? "",
                    // Hermes writes an int; a JSON string is tolerated so a
                    // shape change costs the line number, not the finding.
                    line: (dict["line"] as? Int) ?? Int(dict["line"] as? String ?? "") ?? 0,
                    old: dict["old"] as? String ?? "",
                    new: dict["new"] as? String ?? ""
                )
            }
            // A plugin key with no readable hits is still AFFECTED —
            // Hermes only lists plugins that hit. Keep the key.
            plugins[name] = hits
        }
        return HermesPluginCompatReport(
            removalDate: root["removal_date"] as? String ?? "",
            inEffect: root["in_effect"] as? Bool ?? false,
            plugins: plugins
        )
    }
}
