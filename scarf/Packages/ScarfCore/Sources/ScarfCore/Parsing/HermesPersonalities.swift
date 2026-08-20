import Foundation

/// A personality available to the agent: either one of Hermes' built-ins or a
/// user-defined entry under `agent.personalities` in config.yaml.
public struct HermesPersonalityEntry: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    /// Prompt text as written in config.yaml. Empty for built-ins, whose
    /// prompt text lives in Hermes' own source and is never surfaced here.
    public let prompt: String
    public let isBuiltin: Bool

    public init(name: String, prompt: String, isBuiltin: Bool) {
        self.name = name
        self.prompt = prompt
        self.isBuiltin = isBuiltin
    }
}

/// Single owner of the personality name list Scarf's pickers render.
///
/// Ground truth is Hermes' `hermes_cli/personality.py`:
/// `BUILTIN_PERSONALITIES` (the 14 names below) and
/// `NEUTRAL_PERSONALITY_NAMES`. As of Hermes v0.20.4 (tag v2026.8.18) the
/// built-ins were removed from the shipped `config.yaml` — it now carries
/// `agent.personalities: {}` for user-defined entries only — so a pure YAML
/// scrape returns nothing and the pickers go empty.
public enum HermesPersonalities {
    /// Verbatim key order of `BUILTIN_PERSONALITIES` in
    /// `hermes_cli/personality.py` at v2026.8.18.
    public static let builtinNames: [String] = [
        "helpful",
        "concise",
        "technical",
        "creative",
        "teacher",
        "kawaii",
        "catgirl",
        "pirate",
        "shakespeare",
        "surfer",
        "noir",
        "uwu",
        "philosopher",
        "hype",
    ]

    /// `NEUTRAL_PERSONALITY_NAMES` — selections that mean "no overlay".
    public static let neutralNames: Set<String> = ["", "none", "default", "neutral"]

    public static func isNeutral(_ name: String) -> Bool {
        neutralNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Parse user-defined personalities out of a config.yaml body.
    ///
    /// Keys are matched under `agent.personalities.<name>` — the fully
    /// qualified path `parseNestedYAML` emits. The bare `personalities.<name>`
    /// form is also accepted for hand-written/top-level configs.
    ///
    /// Two entry shapes are legal:
    /// * dict — `<name>:` with a `system_prompt:` child (legacy `prompt:` is
    ///   still honored as a fallback), plus optional `tone`/`style`;
    /// * bare string — `<name>: "You are …"`.
    public static func parseUserDefined(yaml: String) -> [HermesPersonalityEntry] {
        guard !yaml.isEmpty else { return [] }
        let parsed = HermesYAML.parseNestedYAML(yaml)

        /// Returns the remainder after the `agent.personalities.` /
        /// `personalities.` prefix, or nil when the key is unrelated.
        func suffix(of key: String) -> String? {
            for prefix in ["agent.personalities.", "personalities."] where key.hasPrefix(prefix) {
                return String(key.dropFirst(prefix.count))
            }
            return nil
        }

        var names: Set<String> = []
        var bareStrings: [String: String] = [:]
        var subValues: [String: [String: String]] = [:]

        for (key, value) in parsed.values {
            guard let rest = suffix(of: key), !rest.isEmpty else { continue }
            let parts = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            guard !name.isEmpty else { continue }
            names.insert(name)
            if parts.count == 1 {
                // Bare-string entry form: `pirate: "Arrr!"`. An empty value is
                // the dict/section header, which carries no prompt itself.
                bareStrings[name] = HermesYAML.stripYAMLQuotes(value)
            } else {
                subValues[name, default: [:]][String(parts[1])] = HermesYAML.stripYAMLQuotes(value)
            }
        }
        for key in parsed.lists.keys {
            guard let rest = suffix(of: key), !rest.isEmpty else { continue }
            let name = String(rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0])
            if !name.isEmpty { names.insert(name) }
        }
        for (key, map) in parsed.maps {
            guard let rest = suffix(of: key), !rest.isEmpty else { continue }
            let parts = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            guard !name.isEmpty else { continue }
            names.insert(name)
            // Inline flow dict: `pirate: {system_prompt: "Arrr!"}`.
            if parts.count == 1 {
                for (subKey, subValue) in map {
                    subValues[name, default: [:]][subKey] = HermesYAML.stripYAMLQuotes(subValue)
                }
            }
        }

        return names.sorted().map { name in
            let subs = subValues[name] ?? [:]
            let prompt = subs["system_prompt"]
                ?? subs["prompt"]
                ?? bareStrings[name]
                ?? ""
            return HermesPersonalityEntry(name: name, prompt: prompt, isBuiltin: false)
        }
    }

    /// The full picker list: built-ins unioned with the user-defined entries
    /// parsed from `yaml`, deduped by name (a user entry overlays the built-in
    /// of the same name, matching Hermes' own resolution order).
    ///
    /// The union is applied on every host, not just `hasBuiltinPersonalitiesInCode`
    /// ones. On v0.20.4+ the built-ins exist only in code, so the static list is
    /// the only source. On older hosts the shipped config.yaml still carries the
    /// same 14 inline, so parsing finds them and the dedupe collapses the two
    /// sources back to one list — the rendered names are unchanged for those
    /// hosts, and any user entry keeps its config-defined prompt either way.
    public static func resolve(yaml: String) -> [HermesPersonalityEntry] {
        let userDefined = parseUserDefined(yaml: yaml)
        let userNames = Set(userDefined.map(\.name))
        let builtins = builtinNames
            .filter { !userNames.contains($0) }
            .map { HermesPersonalityEntry(name: $0, prompt: "", isBuiltin: true) }
        return (builtins + userDefined).sorted { $0.name < $1.name }
    }

    /// Name-only convenience.
    public static func resolvedNames(yaml: String) -> [String] {
        resolve(yaml: yaml).map(\.name)
    }

    /// Options for a personality picker: the neutral `default` row (no
    /// overlay — `HermesConfig` seeds `display.personality` with it, and it is
    /// not one of the 14 built-ins), then the resolved names.
    ///
    /// `current` is appended when the config holds a name no source knows —
    /// a hand-written or since-deleted selection stays visible and selectable
    /// instead of the picker silently showing some other row as active.
    public static func pickerOptions(yaml: String, current: String = "") -> [String] {
        var options = ["default"] + resolvedNames(yaml: yaml)
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !options.contains(trimmed) {
            options.insert(trimmed, at: 1)
        }
        return options
    }
}
