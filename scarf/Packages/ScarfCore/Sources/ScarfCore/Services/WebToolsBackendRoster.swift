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
public enum WebToolsBackendRoster {
    /// Backends registered for the `search` capability, in picker order.
    ///
    /// `selected` is the value the picker is currently bound to. It only ever
    /// widens the roster: a host that dropped `tavily` still lists it while
    /// the config names it, so the user can see what they are on and pick a
    /// replacement instead of facing a picker whose current value is
    /// invisible. Position is preserved either way.
    public static func search(_ caps: HermesCapabilities, selected: String = "") -> [String] {
        var list = ["exa", "parallel", "firecrawl", "tavily", "searxng"]
        if caps.hasBraveFreeSearchBackend { list.append("brave-free") }
        if caps.hasDDGSearchBackend { list.append("ddgs") }
        if caps.hasXAIWebSearchBackend { list.append("xai") }
        if caps.hasKeenableWebBackend { list.append("keenable") }
        if caps.hasPerplexityWebBackend { list.append("perplexity") }
        return pruningTavily(list, caps: caps, selected: selected)
    }

    /// Backends registered for the `extract` capability, in picker order.
    /// Search-only providers (searxng / brave-free / ddgs / xai) are absent
    /// because their provider classes implement no `extract`.
    public static func extract(_ caps: HermesCapabilities, selected: String = "") -> [String] {
        var list = ["exa", "parallel", "firecrawl", "tavily"]
        if caps.hasKeenableWebBackend { list.append("keenable") }
        if caps.hasPerplexityWebBackend { list.append("perplexity") }
        return pruningTavily(list, caps: caps, selected: selected)
    }

    /// The pre-v0.13 combined `web.backend` roster — a conservative superset
    /// of both capabilities, for hosts that hadn't split the two keys yet.
    /// Every post-v0.13 addition is irrelevant here by construction.
    public static func combined(_ caps: HermesCapabilities, selected: String = "") -> [String] {
        pruningTavily(["exa", "parallel", "firecrawl", "tavily", "searxng"],
                      caps: caps, selected: selected)
    }

    private static func pruningTavily(
        _ list: [String], caps: HermesCapabilities, selected: String
    ) -> [String] {
        guard !caps.hasTavilyWebBackend, selected != "tavily" else { return list }
        return list.filter { $0 != "tavily" }
    }
}
