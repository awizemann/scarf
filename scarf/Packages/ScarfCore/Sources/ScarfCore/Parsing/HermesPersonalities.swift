import Foundation

/// A personality available to the agent: either one of Hermes' built-ins or a
/// user-defined entry under `agent.personalities` in config.yaml.
public struct HermesPersonalityEntry: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    /// Prompt text as Hermes would render it, composed by the same rules as
    /// `render_personality_prompt` in `hermes_cli/personality.py`: the
    /// entry's `system_prompt` body, then a `Tone: …` line, then a
    /// `Style: …` line, each included only when non-empty and joined with
    /// newlines. A tone/style-only entry therefore has a non-empty prompt.
    ///
    /// Empty for built-ins, whose prompt text lives in Hermes' own source
    /// and is never surfaced here.
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
            let body = subs["system_prompt"]
                ?? subs["prompt"]
                ?? bareStrings[name]
                ?? ""
            return HermesPersonalityEntry(
                name: name,
                prompt: renderPrompt(systemPrompt: body, tone: subs["tone"], style: subs["style"]),
                isBuiltin: false
            )
        }
    }

    /// Port of `render_personality_prompt` (`hermes_cli/personality.py`) for
    /// the dict entry shape:
    ///
    ///     parts = [system_prompt]
    ///     if tone:  parts.append(f"Tone: {tone}")
    ///     if style: parts.append(f"Style: {style}")
    ///     "\n".join(stripped parts that are non-empty)
    ///
    /// Hermes builds the `Tone:`/`Style:` lines from truthiness of the raw
    /// value and only drops parts that are empty *after* stripping, which is
    /// what the two-stage check below reproduces.
    static func renderPrompt(systemPrompt: String, tone: String?, style: String?) -> String {
        var parts: [String] = [systemPrompt]
        if let tone, !tone.isEmpty { parts.append("Tone: \(tone)") }
        if let style, !style.isEmpty { parts.append("Style: \(style)") }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The full picker list for a host.
    ///
    /// `hasBuiltinPersonalitiesInCode` is the host capability, and it decides
    /// where the built-ins come from — the union is NOT unconditional:
    ///
    /// * `true` (v0.20.4+): the 14 built-ins live only in
    ///   `hermes_cli/personality.py` and the shipped config carries
    ///   `agent.personalities: {}`. The static list is the only source, so
    ///   it is unioned in and a user entry overlays the built-in it names.
    /// * `false` (pre-v0.20.4): the built-ins are ordinary, editable YAML in
    ///   the shipped config.yaml. A user who deleted one genuinely removed
    ///   it from that host, so the config parse is authoritative and the
    ///   static list must NOT resurrect the deleted entry.
    ///
    /// Overlay rule for a user entry that reuses a built-in name: the user
    /// entry wins (Hermes' own resolution order), but only when it actually
    /// carries prompt text. An entry that renders to nothing — a bare
    /// `pirate:` section header, or one holding only keys Hermes doesn't
    /// render — would otherwise blank a built-in's identity in the picker,
    /// so on a `hasBuiltinPersonalitiesInCode` host it degrades back to the
    /// built-in row (`isBuiltin: true`, empty prompt = "text lives in
    /// Hermes' source"). The name never silently loses its identity, and no
    /// prompt text is invented. On a pre-v0.20.4 host there is no in-code
    /// built-in to fall back to, so the parsed entry stands as written.
    public static func resolve(yaml: String, hasBuiltinPersonalitiesInCode: Bool) -> [HermesPersonalityEntry] {
        let parsed = parseUserDefined(yaml: yaml)
        guard hasBuiltinPersonalitiesInCode else {
            return parsed.sorted { $0.name < $1.name }
        }
        let builtinSet = Set(builtinNames)
        let userDefined = parsed.map { entry -> HermesPersonalityEntry in
            guard entry.prompt.isEmpty, builtinSet.contains(entry.name) else { return entry }
            return HermesPersonalityEntry(name: entry.name, prompt: "", isBuiltin: true)
        }
        let userNames = Set(userDefined.map(\.name))
        let builtins = builtinNames
            .filter { !userNames.contains($0) }
            .map { HermesPersonalityEntry(name: $0, prompt: "", isBuiltin: true) }
        return (builtins + userDefined).sorted { $0.name < $1.name }
    }

    /// Name-only convenience.
    public static func resolvedNames(yaml: String, hasBuiltinPersonalitiesInCode: Bool) -> [String] {
        resolve(yaml: yaml, hasBuiltinPersonalitiesInCode: hasBuiltinPersonalitiesInCode).map(\.name)
    }

    /// Options for a personality picker: the neutral `default` row (no
    /// overlay — `HermesConfig` seeds `display.personality` with it, and it is
    /// not one of the 14 built-ins), then the resolved names.
    ///
    /// `current` is appended when the config holds a name no source knows —
    /// a hand-written or since-deleted selection stays visible and selectable
    /// instead of the picker silently showing some other row as active.
    public static func pickerOptions(
        yaml: String,
        current: String = "",
        hasBuiltinPersonalitiesInCode: Bool
    ) -> [String] {
        var options = ["default"] + resolvedNames(
            yaml: yaml,
            hasBuiltinPersonalitiesInCode: hasBuiltinPersonalitiesInCode
        )
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !options.contains(trimmed) {
            options.insert(trimmed, at: 1)
        }
        return options
    }
}
