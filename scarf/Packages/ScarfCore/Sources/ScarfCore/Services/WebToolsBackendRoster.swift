import Foundation

/// Which web search / extract backends a given Hermes host actually ships.
///
/// Hermes registers each backend from a bundled plugin directory
/// (`plugins/web/<name>/__init__.py` calling
/// `ctx.register_web_search_provider(...)`), so the roster moves with the
/// release and Scarf's pickers have to move with it. This is the single
/// source of truth both the Settings pickers and the drift-alarm tests read,
/// so a picker can't quietly disagree with what a host has.
///
/// Roster verified directly against `git ls-tree <tag> plugins/web/`:
///
/// | backend      | first tag        | search | extract |
/// |--------------|------------------|--------|---------|
/// | exa          | ≤ v0.12          | ✓      | ✓       |
/// | parallel     | ≤ v0.12          | ✓      | ✓       |
/// | firecrawl    | ≤ v0.12          | ✓      | ✓       |
/// | tavily       | ≤ v0.12          | ✓      | ✓       |
/// | searxng      | ≤ v0.12          | ✓      | —       |
/// | brave-free   | v0.14            | ✓      | —       |
/// | ddgs         | v0.14            | ✓      | —       |
/// | xai          | v0.15            | ✓      | —       |
/// | keenable     | v0.20.5          | ✓      | ✓       |
/// | perplexity   | v0.21.1          | ✓      | ✓       |
///
/// `tavily` is the one gap rather than a floor: absent at v0.21.0 only
/// (deleted at v2026.8.31, restored at v2026.9.7, commit 428e084dcd).
///
/// Every roster starts with `""` — the value Hermes itself defaults these
/// keys to (`hermes_cli/config_defaults.py:350` `"backend": ""`, `:351`
/// `"search_backend": ""`, `:352` `"extract_backend": ""` at v2026.9.7).
/// Without it a stock config selects a value the picker does not offer, so
/// the row renders blank AND there is no way to get back to "unset" after
/// picking a backend once.
public enum WebToolsBackendRoster {
    /// Backends registered for the `search` capability, in picker order.
    ///
    /// `selected` is the value the picker is currently bound to. It only ever
    /// widens the roster: whatever the config names stays listed even when
    /// this host's roster does not contain it, so the user can see what they
    /// are on and pick a replacement instead of facing a picker whose current
    /// value is invisible. Position is preserved for a backend the roster
    /// knows (`tavily` on a v0.21.0 host); anything else — a backend above
    /// this host's floor, a hand-edited name, or any backend at all when the
    /// version could not be parsed — is appended at the end.
    public static func search(_ caps: HermesCapabilities, selected: String = "") -> [String] {
        var list = ["exa", "parallel", "firecrawl", "tavily", "searxng"]
        if caps.hasBraveFreeSearchBackend { list.append("brave-free") }
        if caps.hasDDGSearchBackend { list.append("ddgs") }
        if caps.hasXAIWebSearchBackend { list.append("xai") }
        if caps.hasKeenableWebBackend { list.append("keenable") }
        if caps.hasPerplexityWebBackend { list.append("perplexity") }
        return finalize(list, caps: caps, selected: selected)
    }

    /// Backends registered for the `extract` capability, in picker order.
    /// Search-only providers (searxng / brave-free / ddgs / xai) are absent
    /// because their provider classes implement no `extract`.
    public static func extract(_ caps: HermesCapabilities, selected: String = "") -> [String] {
        var list = ["exa", "parallel", "firecrawl", "tavily"]
        if caps.hasKeenableWebBackend { list.append("keenable") }
        if caps.hasPerplexityWebBackend { list.append("perplexity") }
        return finalize(list, caps: caps, selected: selected)
    }

    /// The pre-v0.13 combined `web.backend` roster — a conservative superset
    /// of both capabilities, for hosts that hadn't split the two keys yet.
    /// Every post-v0.13 addition is irrelevant here by construction.
    public static func combined(_ caps: HermesCapabilities, selected: String = "") -> [String] {
        finalize(["exa", "parallel", "firecrawl", "tavily", "searxng"],
                 caps: caps, selected: selected)
    }

    /// Which of the two Web Tools editors to render.
    ///
    /// Mirrors `HermesServiceTier.editorStyle`: an `.empty` capabilities
    /// value means the PROBE FAILED, not "old host", so a gate whose false
    /// branch renders the LOSSY editor must also consider the stored value.
    /// The combined `web.backend` row is that lossy editor — it neither shows
    /// nor writes `web.search_backend` / `web.extract_backend`, so on an
    /// undetected host with either override set the user saw "Automatic"
    /// (those keys' own default is `""`, which the shared row spells that
    /// way) and any pick wrote `web.backend`, which the overrides shadow —
    /// a control that silently does nothing.
    ///
    /// The widening branch is only reachable for a config Scarf could not
    /// have written on a pre-v0.13 host, because the combined row never
    /// writes the override keys. So C1 holds: every host that rendered the
    /// single row before still renders it.
    public static func editorStyle(
        _ caps: HermesCapabilities,
        searchBackend: String = "",
        extractBackend: String = ""
    ) -> EditorStyle {
        if caps.hasWebToolsBackendSplit { return .split }
        return (searchBackend.isEmpty && extractBackend.isEmpty) ? .combined : .split
    }

    public enum EditorStyle: Sendable, Equatable {
        /// The pre-v0.13 single shared `web.backend` row.
        case combined
        /// The v0.13+ `web.search_backend` + `web.extract_backend` pair.
        case split
    }

    /// Prune the one removal window, widen with whatever the config actually
    /// names, then prepend the inherit/unset row.
    private static func finalize(
        _ list: [String], caps: HermesCapabilities, selected: String
    ) -> [String] {
        var out = list
        // The tavily window (v0.21.0 only) is a removal, not a floor — drop
        // it in place unless this config is the thing keeping it visible.
        if !caps.hasTavilyWebBackend, selected != "tavily" {
            out.removeAll { $0 == "tavily" }
        }
        // Widen for EVERY backend, not just tavily: an unknown-version host
        // (`.empty` capabilities — all floors read false) with `perplexity`
        // or `keenable` in its config must still show that value rather than
        // a blank row.
        if !selected.isEmpty, !out.contains(selected) {
            out.append(selected)
        }
        // "" is Hermes's own default for all three keys and the only way back
        // to "inherit / unset" after a backend has been picked once.
        return [""] + out
    }
}
