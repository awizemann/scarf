import Testing
@testable import ScarfCore

/// Drift alarm for the Web Tools pickers (v0.21.1 audit finding D).
///
/// Nothing pinned Scarf's backend lists to Hermes's actual `plugins/web/`
/// roster, which is exactly how two bugs shipped: `tavily` stayed filtered
/// after v0.21.1 restored it, and `keenable` (v0.20.5) and `perplexity`
/// (v0.21.1) were never added at all.
///
/// The rosters below are transcribed from `git ls-tree <tag> plugins/web/`
/// at each tag, with the search/extract split read off each provider class
/// (`plugins/web/<name>/provider.py` — a provider is in the extract picker
/// iff it defines `extract`). Update this file and the picker together, or
/// not at all.
@Suite struct WebToolsBackendRosterTests {

    private func caps(_ line: String) -> HermesCapabilities { HermesHost.caps(line) }

    /// `git ls-tree v2026.8.31 plugins/web/` → brave_free, ddgs, exa,
    /// firecrawl, keenable, parallel, searxng, xai. No tavily (deleted at
    /// this tag), no perplexity (not yet).
    @Test func searchRosterAtV0210() {
        #expect(WebToolsBackendRoster.search(caps("Hermes Agent v0.21.0 (2026.8.31)")) == [
            "", "exa", "parallel", "firecrawl", "searxng",
            "brave-free", "ddgs", "xai", "keenable",
        ])
    }

    @Test func extractRosterAtV0210() {
        #expect(WebToolsBackendRoster.extract(caps("Hermes Agent v0.21.0 (2026.8.31)")) == [
            "", "exa", "parallel", "firecrawl", "keenable",
        ])
    }

    /// `git ls-tree v2026.9.7 plugins/web/` → brave_free, ddgs, exa,
    /// firecrawl, keenable, parallel, perplexity, searxng, tavily, xai.
    @Test func searchRosterAtV0211() {
        #expect(WebToolsBackendRoster.search(caps("Hermes Agent v0.21.1 (2026.9.7)")) == [
            "", "exa", "parallel", "firecrawl", "tavily", "searxng",
            "brave-free", "ddgs", "xai", "keenable", "perplexity",
        ])
    }

    /// Perplexity's provider implements BOTH `search` and `extract`
    /// (`plugins/web/perplexity/provider.py:168,197`), as does Keenable
    /// (`plugins/web/keenable/provider.py:39,60`), so both belong here.
    @Test func extractRosterAtV0211() {
        #expect(WebToolsBackendRoster.extract(caps("Hermes Agent v0.21.1 (2026.9.7)")) == [
            "", "exa", "parallel", "firecrawl", "tavily", "keenable", "perplexity",
        ])
    }

    /// v0.20.6 is the last tag before the tavily hole; keenable is already
    /// there (since v0.20.5), perplexity is not.
    @Test func rosterAtV0206() {
        #expect(WebToolsBackendRoster.search(caps("Hermes Agent v0.20.6 (2026.8.27)")) == [
            "", "exa", "parallel", "firecrawl", "tavily", "searxng",
            "brave-free", "ddgs", "xai", "keenable",
        ])
        #expect(WebToolsBackendRoster.extract(caps("Hermes Agent v0.20.6 (2026.8.27)")) == [
            "", "exa", "parallel", "firecrawl", "tavily", "keenable",
        ])
    }

    /// Pre-target hosts must render exactly as they did before this change:
    /// v0.20.4 has no keenable and no perplexity.
    @Test func rosterAtV0204IsUnchanged() {
        #expect(WebToolsBackendRoster.search(caps("Hermes Agent v0.20.4 (2026.8.18)")) == [
            "", "exa", "parallel", "firecrawl", "tavily", "searxng",
            "brave-free", "ddgs", "xai",
        ])
        #expect(WebToolsBackendRoster.extract(caps("Hermes Agent v0.20.4 (2026.8.18)")) == [
            "", "exa", "parallel", "firecrawl", "tavily",
        ])
    }

    /// v0.13 (the tag that split the two keys) — no v0.14/v0.15 additions.
    @Test func rosterAtV013() {
        #expect(WebToolsBackendRoster.search(caps("Hermes Agent v0.13.0 (2026.5.7)")) == [
            "", "exa", "parallel", "firecrawl", "tavily", "searxng",
        ])
    }

    /// An undetected host keeps every removable entry and offers no gated
    /// addition — the conservative direction on both counts.
    @Test func rosterForUnknownVersion() {
        #expect(WebToolsBackendRoster.search(.empty) == [
            "", "exa", "parallel", "firecrawl", "tavily", "searxng",
        ])
        #expect(WebToolsBackendRoster.extract(.empty) == [
            "", "exa", "parallel", "firecrawl", "tavily",
        ])
        #expect(WebToolsBackendRoster.combined(.empty) == [
            "", "exa", "parallel", "firecrawl", "tavily", "searxng",
        ])
    }

    /// The one UI rule the roster carries: a v0.21.0 host that has `tavily`
    /// in its config still sees it — in its ORIGINAL position, so the picker
    /// doesn't reshuffle — while every other v0.21.0 host does not.
    @Test func tavilySurvivesInV0210WhenSelected() {
        let v0210 = caps("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(WebToolsBackendRoster.search(v0210, selected: "tavily") == [
            "", "exa", "parallel", "firecrawl", "tavily", "searxng",
            "brave-free", "ddgs", "xai", "keenable",
        ])
        #expect(!WebToolsBackendRoster.search(v0210, selected: "exa").contains("tavily"))
        #expect(WebToolsBackendRoster.extract(v0210, selected: "tavily").contains("tavily"))
        #expect(WebToolsBackendRoster.combined(v0210, selected: "tavily").contains("tavily"))
    }

    /// Widening is for EVERY backend, not just `tavily`. Previously only
    /// tavily survived, so an unknown-version host (or any host below the
    /// backend's floor) whose config named `perplexity` bound the picker to
    /// a value it did not offer — SwiftUI renders that as a blank row with
    /// no way back. Regression guard for that bug.
    @Test func unknownVersionHostWithPerplexitySelectedIsNotBlank() {
        for selected in ["perplexity", "keenable", "brave-free", "some-future-backend"] {
            let list = WebToolsBackendRoster.search(.empty, selected: selected)
            #expect(list.contains(selected), "search roster dropped \(selected)")
            #expect(list.first == "", "inherit row missing for \(selected)")
        }
        // Appended at the end so the known roster's order never reshuffles.
        #expect(WebToolsBackendRoster.search(.empty, selected: "perplexity") == [
            "", "exa", "parallel", "firecrawl", "tavily", "searxng", "perplexity",
        ])
        #expect(WebToolsBackendRoster.extract(.empty, selected: "perplexity") == [
            "", "exa", "parallel", "firecrawl", "tavily", "perplexity",
        ])
        #expect(WebToolsBackendRoster.combined(.empty, selected: "perplexity") == [
            "", "exa", "parallel", "firecrawl", "tavily", "searxng", "perplexity",
        ])
        // A v0.21.0 host with a stale `perplexity` config sees it too.
        let v0210 = caps("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(WebToolsBackendRoster.search(v0210, selected: "perplexity").last == "perplexity")
    }

    /// A stock Hermes config leaves all three keys at `""`
    /// (`config_defaults.py:350-352`). The picker must offer that value on
    /// every host and every capability, or the row renders blank out of the
    /// box and there is no way back to "inherit" after picking once.
    @Test func inheritRowIsAlwaysOffered() {
        let hosts: [HermesCapabilities] = [
            .empty,
            caps("Hermes Agent v0.13.0 (2026.5.7)"),
            caps("Hermes Agent v0.20.6 (2026.8.27)"),
            caps("Hermes Agent v0.21.0 (2026.8.31)"),
            caps("Hermes Agent v0.21.1 (2026.9.7)"),
        ]
        for host in hosts {
            #expect(WebToolsBackendRoster.search(host).first == "")
            #expect(WebToolsBackendRoster.extract(host).first == "")
            #expect(WebToolsBackendRoster.combined(host).first == "")
            // Exactly one, and never a duplicate when "" is also selected.
            #expect(WebToolsBackendRoster.search(host, selected: "").filter { $0.isEmpty }.count == 1)
            #expect(WebToolsBackendRoster.extract(host, selected: "").filter { $0.isEmpty }.count == 1)
            #expect(WebToolsBackendRoster.combined(host, selected: "").filter { $0.isEmpty }.count == 1)
        }
    }
}
