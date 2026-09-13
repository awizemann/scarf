import SwiftUI
import ScarfCore
import ScarfDesign

/// Settings is now organized into tabs because the full Hermes config surface is far
/// too large for a single scrolling form (~70 config fields). Each tab has its own
/// extracted view file under `Tabs/`.
///
/// Visual layer follows `design/static-site/ui-kit/Settings.jsx`:
/// page header on top, custom horizontal tab strip below, scrollable
/// content per tab. The 10 functional tabs differ from the mockup's 6 — we
/// keep our tabs (General/Display/Agent/Terminal/Browser/Voice/Memory/Aux
/// Models/Security/Advanced) and only adopt the visual chrome.
struct SettingsView: View {
    // Coordinator-cached (t-aud24) so it survives section switches.
    let viewModel: SettingsViewModel
    @State private var selectedTab: SettingsTab = .general
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    /// Tabs visible for the connected host. The Secrets (Bitwarden) tab is
    /// release-gated — pre-v0.15 hosts don't see it at all.
    private var visibleTabs: [SettingsTab] {
        let hasBitwarden = capabilitiesStore?.capabilities.hasBitwarden ?? false
        return SettingsTab.allCases.filter { tab in
            switch tab {
            case .secrets: return hasBitwarden
            default: return true
            }
        }
    }


    enum SettingsTab: String, CaseIterable, Identifiable, ScarfTabStripTab {
        case general = "General"
        case display = "Display"
        case agent = "Agent"
        case terminal = "Terminal"
        case browser = "Browser"
        case webTools = "Web Tools"
        case voice = "Voice"
        case memory = "Memory"
        case auxiliary = "Aux Models"
        case security = "Security"
        case secrets = "Secrets"
        case advanced = "Advanced"

        var id: String { rawValue }

        var displayName: LocalizedStringResource {
            switch self {
            case .general: return "General"
            case .display: return "Display"
            case .agent: return "Agent"
            case .terminal: return "Terminal"
            case .browser: return "Browser"
            case .webTools: return "Web Tools"
            case .voice: return "Voice"
            case .memory: return "Memory"
            case .auxiliary: return "Aux Models"
            case .security: return "Security"
            case .secrets: return "Secrets"
            case .advanced: return "Advanced"
            }
        }

        /// Whether a managed host may black out this whole tab.
        ///
        /// True for the nine tabs that are write controls end to end. False
        /// for the three that carry a READ the user still needs on a managed
        /// host — `.disabled` reaches every descendant, so a wholesale lock
        /// takes the reads with the writes. Each of the three locks its own
        /// write controls instead:
        ///
        /// - `.advanced` — Config Diagnostics' "Check" (`_cmd_config_check`
        ///   mutates nothing, `hermes_cli/config.py:3693-3720` @ v2026.9.7),
        ///   "Backup Now", the Raw Config disclosure, ScarfMon's "Copy as
        ///   JSON" and the text selection in every output panel.
        /// - `.secrets` — "Check Status" (`bitwardenStatus()` shells
        ///   `hermes secrets status`, a read) and its selectable output panel.
        /// - `.security` — the selectable proposal patterns in Allowlist
        ///   Suggestions, plus the two `ReadOnlyRow`s that are the only way to
        ///   see the pinned blocklist and command allowlist.
        ///
        /// Walked all eleven non-Advanced tabs for the same shape (P39c): no
        /// other tab has a copy / export / check / open-in-Finder / text
        /// selection affordance inside the lock.
        var locksWholeTabWhenManaged: Bool {
            switch self {
            case .advanced, .secrets, .security: return false
            default: return true
            }
        }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .display: return "paintbrush"
            case .agent: return "brain.head.profile"
            case .terminal: return "terminal"
            case .browser: return "globe"
            case .webTools: return "globe.americas"
            case .voice: return "mic"
            case .memory: return "memorychip"
            case .auxiliary: return "sparkles.rectangle.stack"
            case .security: return "lock.shield"
            case .secrets: return "key.horizontal"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            tabStrip
            managedBanner
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s5) {
                    tabContent(selectedTab)
                }
                .frame(maxWidth: 880, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, ScarfSpace.s6)
                .padding(.vertical, ScarfSpace.s6)
                // P39 (round-4 decision 1): a package-manager-managed Hermes
                // refuses every config write — at exit 0, with a stderr line
                // the user never sees. One banner above, and the write
                // controls are read-only, instead of thirteen tabs of
                // controls that each snap back. Untouched on a host with no
                // `.managed` marker.
                //
                // The lock covers the DIRECT writers too (the Secrets tab's
                // `.env` rows), which do not go through the CLI and would
                // therefore "succeed". That is deliberate, and it is Hermes's
                // own posture: `_env_write_blocked` refuses every `.env`
                // write on a managed install (`hermes_cli/config.py:2556-2558`)
                // and `save_config` every config.yaml write (`:2316-2318`).
                //
                // It does NOT cover Advanced, Secrets or Security, the three
                // tabs that carry reads a managed host still needs — see
                // `locksWholeTabWhenManaged`. On Advanced those are Config
                // Diagnostics'
                // "Check" (`_cmd_config_check` is read-only,
                // `hermes_cli/config.py:3693-3720`), "Backup Now", the Raw
                // Config show/hide disclosure, ScarfMon's "Copy as JSON",
                // and the text selection in all of their output panels.
                // `.disabled` reaches every descendant and kills all of them,
                // so a managed host could not even read its own config to
                // find out what its package manager had pinned (round-4
                // review). `AdvancedTab`, `SecretsTab` and `SecurityTab` each
                // apply the same lock to their write controls alone.
                .disabled(viewModel.isManagedHost && selectedTab.locksWholeTabWhenManaged)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Settings")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading settings…",
            isEmpty: viewModel.rawConfigYAML.isEmpty
        )
        .onAppear {
            // Decides whether Hermes' in-code built-in personalities are
            // unioned into the personality picker — must be set before load.
            viewModel.hasBuiltinPersonalitiesInCode =
                capabilitiesStore?.capabilities.hasBuiltinPersonalitiesInCode ?? false
            viewModel.load()
        }
    }

    /// The ONE managed-install banner. Nothing else in Settings repeats it:
    /// the pane below is simply disabled. See
    /// ``SettingsViewModel/managedInstall``.
    @ViewBuilder
    private var managedBanner: some View {
        if let text = viewModel.managedBannerText {
            HStack(alignment: .top, spacing: ScarfSpace.s2) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Text(text)
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ScarfSpace.s6)
            .padding(.vertical, ScarfSpace.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ScarfColor.backgroundSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("This Hermes installation is managed; settings are read-only")
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("Global preferences for Scarf. Per-project overrides live in each project.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            OutcomeMessageBar(
                text: viewModel.saveMessage,
                kind: viewModel.messageKind,
                onDismiss: { viewModel.dismissMessage() }
            )
            HStack(spacing: ScarfSpace.s2) {
                Button("Open in Editor") { viewModel.openConfigInEditor() }
                    .buttonStyle(ScarfGhostButton())
                Button("Reload") { viewModel.load(force: true) }
                    .buttonStyle(ScarfSecondaryButton())
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s3)
    }

    private var tabStrip: some View {
        ScarfTabStrip(
            tabs: visibleTabs,
            selection: $selectedTab,
            identifierPrefix: "settings.tab",
            icon: { $0.icon }
        )
    }

    @ViewBuilder
    private func tabContent(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:   GeneralTab(viewModel: viewModel)
        case .display:   DisplayTab(viewModel: viewModel)
        case .agent:     AgentTab(viewModel: viewModel)
        case .terminal:  TerminalTab(viewModel: viewModel)
        case .browser:   BrowserTab(viewModel: viewModel)
        case .webTools:  WebToolsTab(viewModel: viewModel)
        case .voice:     VoiceTab(viewModel: viewModel)
        case .memory:    MemoryTab(viewModel: viewModel)
        case .auxiliary: AuxiliaryTab(viewModel: viewModel)
        case .security:  SecurityTab(viewModel: viewModel)
        case .secrets:   SecretsTab(viewModel: viewModel)
        case .advanced:  AdvancedTab(viewModel: viewModel)
        }
    }
}
