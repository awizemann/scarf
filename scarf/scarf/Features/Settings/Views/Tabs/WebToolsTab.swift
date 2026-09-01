import SwiftUI
import ScarfCore
import ScarfDesign

/// Web Tools tab — search + extract backend pickers. Pre-v0.13 hosts
/// see a single "Backend" row writing the shared `web.backend` key.
/// v0.13+ hosts see two rows writing the per-capability override keys
/// (`web.search_backend` + `web.extract_backend`; "" = inherit
/// `web.backend`); SearXNG appears in the search picker only because
/// Hermes registers it as a search-only backend.
struct WebToolsTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    private var split: Bool {
        capabilitiesStore?.capabilities.hasWebToolsBackendSplit ?? false
    }

    // Wire-accurate against `tools/web_tools.py`. Through v0.20.6 the
    // canonical set is exa, parallel, firecrawl, tavily, searxng,
    // brave-free, ddgs. `brave-free` and `ddgs` are v0.14 additions and
    // `xai` a v0.15 one — gated below so older hosts only see what they
    // have. Search-only entries (searxng / brave-free / ddgs / xai) don't
    // appear in the extract picker.
    //
    // `tavily` is the one REMOVAL: the whole `plugins/web/tavily/` provider
    // was deleted at v2026.8.31 (0.21.0), and the keyless free-tier ring
    // comment in `config_defaults.py` narrows from five vendors to four
    // (exa, parallel, firecrawl, keenable) at the same tag. It is filtered
    // out on v0.21+ hosts by `hasTavilyWebBackend` — except when the config
    // still names it, so a user landing on a fresh host can see what they
    // are on and pick a replacement rather than face a picker whose current
    // value is invisible.
    private static let v013SearchBackends: [String] = [
        "exa", "parallel", "firecrawl", "tavily", "searxng"
    ]
    private static let v014SearchAdditions: [String] = [
        "brave-free", "ddgs"
    ]
    /// v0.15 search-only addition — xAI Web Search (`plugins/web/xai`),
    /// reuses Grok OAuth / `XAI_API_KEY`. Search-only, so it isn't in the
    /// extract picker.
    private static let v015SearchAdditions: [String] = [
        "xai"
    ]
    private static let extractBackends: [String] = [
        "exa", "parallel", "firecrawl", "tavily"
    ]
    /// v0.12 combined-backend list — pre-v0.13 hosts that haven't yet
    /// split search/extract into per-capability keys. Conservative
    /// superset: every backend that handles either capability.
    private static let combinedBackends: [String] = [
        "exa", "parallel", "firecrawl", "tavily", "searxng"
    ]

    /// Drop `tavily` on hosts that no longer ship the provider — unless the
    /// config currently selects it, in which case keeping the entry is what
    /// lets the user migrate off it. `current` is the value the picker is
    /// bound to.
    private func pruningTavily(_ list: [String], current: String) -> [String] {
        let caps = capabilitiesStore?.capabilities ?? .empty
        guard !caps.hasTavilyWebBackend, current != "tavily" else { return list }
        return list.filter { $0 != "tavily" }
    }

    private var searchBackends: [String] {
        let caps = capabilitiesStore?.capabilities ?? .empty
        var list = Self.v013SearchBackends
        if caps.hasBraveFreeSearchBackend { list.append("brave-free") }
        if caps.hasDDGSearchBackend { list.append("ddgs") }
        if caps.hasXAIWebSearchBackend { list.append("xai") }
        return pruningTavily(list, current: viewModel.config.webToolsSearchBackend)
    }

    private var extractBackends: [String] {
        pruningTavily(Self.extractBackends, current: viewModel.config.webToolsExtractBackend)
    }

    /// The pre-v0.13 combined picker writes the shared `web.backend` key, so
    /// it prunes against that value instead. In practice a v0.21 host is
    /// never on this branch (the split landed in v0.13), but routing it
    /// through the same helper keeps the two paths from drifting.
    private var combinedBackends: [String] {
        pruningTavily(Self.combinedBackends, current: viewModel.config.webToolsBackend)
    }

    var body: some View {
        if split {
            SettingsSection(title: "Web Tools", icon: "globe.americas") {
                PickerRow(
                    label: "Search backend",
                    selection: viewModel.config.webToolsSearchBackend,
                    options: searchBackends
                ) { viewModel.setWebToolsSearchBackend($0) }
                PickerRow(
                    label: "Extract backend",
                    selection: viewModel.config.webToolsExtractBackend,
                    options: extractBackends
                ) { viewModel.setWebToolsExtractBackend($0) }
            }
            // Footer copy adapts to the connected host — v0.14 adds the
            // two new free-tier search backends; older hosts see the
            // SearXNG-joined-search-only line.
            let caps = capabilitiesStore?.capabilities ?? .empty
            let footerCopy: String = {
                if !caps.hasTavilyWebBackend {
                    return "v0.21 removed the Tavily backend; the keyless free-tier ring is now Exa, Parallel, Firecrawl and Keenable. xAI Web Search, Brave Search and DuckDuckGo (DDGS) are search-only. Backend-specific tuning lives in the raw YAML editor for now."
                }
                if caps.hasXAIWebSearchBackend {
                    return "v0.15 added xAI Web Search (reuses your Grok OAuth / XAI_API_KEY). v0.14 added Brave Search (free tier; honors BRAVE_SEARCH_API_KEY) and DuckDuckGo (DDGS). All three are search-only. Backend-specific tuning lives in the raw YAML editor for now."
                }
                if caps.hasBraveFreeSearchBackend || caps.hasDDGSearchBackend {
                    return "v0.14 added Brave Search (free tier; honors BRAVE_SEARCH_API_KEY) and DuckDuckGo (DDGS) as search-only backends. Backend-specific tuning lives in the raw YAML editor for now."
                }
                return "SearXNG is search-only. Backend-specific tuning (host URLs, API keys) lives in the raw YAML editor for now."
            }()
            Text(footerCopy)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.horizontal, ScarfSpace.s4)
        } else {
            SettingsSection(title: "Web Tools", icon: "globe.americas") {
                PickerRow(
                    label: "Backend",
                    selection: viewModel.config.webToolsBackend,
                    options: combinedBackends
                ) { viewModel.setWebToolsBackend($0) }
            }
            Text("Hermes v0.13 splits search and extract into separate backends. Update Hermes to access the per-capability picker.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .padding(.horizontal, ScarfSpace.s4)
        }
    }
}
