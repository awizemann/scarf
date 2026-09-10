import SwiftUI
import ScarfCore
import ScarfDesign

/// Web Tools tab — search + extract backend pickers. Pre-v0.13 hosts
/// (and only those: an UNDETECTED host whose config already sets either
/// override key gets the split editor, per
/// `WebToolsBackendRoster.editorStyle`) see a single "Backend" row writing
/// the shared `web.backend` key.
/// v0.13+ hosts see two rows writing the per-capability override keys
/// (`web.search_backend` + `web.extract_backend`; "" = inherit
/// `web.backend`); SearXNG appears in the search picker only because
/// Hermes registers it as a search-only backend.
struct WebToolsTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    /// Not a bare `hasWebToolsBackendSplit` read — see
    /// `WebToolsBackendRoster.editorStyle` for why an undetected host whose
    /// config already names a per-capability override gets the split editor
    /// anyway.
    private var split: Bool {
        WebToolsBackendRoster.editorStyle(
            caps,
            searchBackend: viewModel.config.webToolsSearchBackend,
            extractBackend: viewModel.config.webToolsExtractBackend
        ) == .split
    }

    // The roster lives in `WebToolsBackendRoster` (ScarfCore) so the pickers
    // and the drift-alarm tests read one source of truth; see its per-backend
    // table for the tag each one first ships at, and its `selected:` note for
    // why a dropped backend stays visible while the config still names it.
    private var caps: HermesCapabilities {
        capabilitiesStore?.capabilities ?? .empty
    }

    private var searchBackends: [String] {
        WebToolsBackendRoster.search(caps, selected: viewModel.config.webToolsSearchBackend)
    }

    private var extractBackends: [String] {
        WebToolsBackendRoster.extract(caps, selected: viewModel.config.webToolsExtractBackend)
    }

    /// The pre-v0.13 combined picker writes the shared `web.backend` key, so
    /// it prunes against that value instead. In practice a v0.21 host is
    /// never on this branch (the split landed in v0.13), but routing it
    /// through the same helper keeps the two paths from drifting.
    private var combinedBackends: [String] {
        WebToolsBackendRoster.combined(caps, selected: viewModel.config.webToolsBackend)
    }

    /// `""` is Hermes's default for both override keys and means "fall back
    /// to `web.backend`" — name it so, rather than PickerRow's generic
    /// "(none)", which reads like "no backend at all".
    private static func overrideOptionLabel(_ option: String) -> String {
        option.isEmpty ? String(localized: "Inherit (web.backend)") : option
    }

    /// The shared `web.backend` key has nothing above it to inherit from —
    /// empty there means Hermes picks, via the keyless free-tier ring.
    private static func sharedOptionLabel(_ option: String) -> String {
        option.isEmpty ? String(localized: "Automatic") : option
    }

    var body: some View {
        if split {
            SettingsSection(title: "Web Tools", icon: "globe.americas") {
                PickerRow(
                    label: "Search backend",
                    selection: viewModel.config.webToolsSearchBackend,
                    options: searchBackends,
                    optionLabel: Self.overrideOptionLabel
                ) { viewModel.setWebToolsSearchBackend($0) }
                PickerRow(
                    label: "Extract backend",
                    selection: viewModel.config.webToolsExtractBackend,
                    options: extractBackends,
                    optionLabel: Self.overrideOptionLabel
                ) { viewModel.setWebToolsExtractBackend($0) }
            }
            // Footer copy adapts to the connected host — v0.14 adds the
            // two new free-tier search backends; older hosts see the
            // SearXNG-joined-search-only line.
            let footerCopy: String = {
                if !caps.hasTavilyWebBackend {
                    return "v0.21.0 removed the Tavily backend; the keyless free-tier ring is Exa, Parallel, Firecrawl and Keenable. (v0.21.1 brings Tavily back — update to get it.) xAI Web Search, Brave Search and DuckDuckGo (DDGS) are search-only. Backend-specific tuning lives in the raw YAML editor for now."
                }
                if caps.hasPerplexityWebBackend {
                    return "v0.21.1 added Perplexity (search + extract; needs PERPLEXITY_API_KEY) and restored Tavily. Keenable joins Exa, Parallel and Firecrawl in the keyless free-tier ring. xAI Web Search, Brave Search and DuckDuckGo (DDGS) are search-only. Backend-specific tuning lives in the raw YAML editor for now."
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
                    options: combinedBackends,
                    optionLabel: Self.sharedOptionLabel
                ) { viewModel.setWebToolsBackend($0) }
            }
            Text("Hermes v0.13 splits search and extract into separate backends. Update Hermes to access the per-capability picker.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .padding(.horizontal, ScarfSpace.s4)
        }
    }
}
