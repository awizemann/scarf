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
    @State private var viewModel: SettingsViewModel
    @State private var selectedTab: SettingsTab = .general

    init(context: ServerContext) {
        _viewModel = State(initialValue: SettingsViewModel(context: context))
    }


    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case display = "Display"
        case agent = "Agent"
        case terminal = "Terminal"
        case browser = "Browser"
        case voice = "Voice"
        case memory = "Memory"
        case auxiliary = "Aux Models"
        case security = "Security"
        case advanced = "Advanced"

        var id: String { rawValue }

        var displayName: LocalizedStringResource {
            switch self {
            case .general: return "General"
            case .display: return "Display"
            case .agent: return "Agent"
            case .terminal: return "Terminal"
            case .browser: return "Browser"
            case .voice: return "Voice"
            case .memory: return "Memory"
            case .auxiliary: return "Aux Models"
            case .security: return "Security"
            case .advanced: return "Advanced"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .display: return "paintbrush"
            case .agent: return "brain.head.profile"
            case .terminal: return "terminal"
            case .browser: return "globe"
            case .voice: return "mic"
            case .memory: return "memorychip"
            case .auxiliary: return "sparkles.rectangle.stack"
            case .security: return "lock.shield"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            tabStrip
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s5) {
                    tabContent(selectedTab)
                }
                .frame(maxWidth: 880, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, ScarfSpace.s6)
                .padding(.vertical, ScarfSpace.s6)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Settings")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading settings…",
            isEmpty: viewModel.rawConfigYAML.isEmpty
        )
        .onAppear { viewModel.load() }
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
            if let msg = viewModel.saveMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.success)
            }
            HStack(spacing: ScarfSpace.s2) {
                Button("Open in Editor") { viewModel.openConfigInEditor() }
                    .buttonStyle(ScarfGhostButton())
                Button("Reload") { viewModel.load() }
                    .buttonStyle(ScarfSecondaryButton())
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s3)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ScarfSpace.s1) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, ScarfSpace.s6)
        }
        .background(
            ScarfColor.backgroundSecondary
                .overlay(
                    Rectangle()
                        .fill(ScarfColor.border)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isActive = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12))
                Text(tab.displayName)
                    .scarfStyle(isActive ? .bodyEmph : .body)
            }
            .foregroundStyle(isActive ? ScarfColor.accent : ScarfColor.foregroundMuted)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, 10)
            .overlay(
                Rectangle()
                    .fill(isActive ? ScarfColor.accent : Color.clear)
                    .frame(height: 2),
                alignment: .bottom
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tabContent(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:   GeneralTab(viewModel: viewModel)
        case .display:   DisplayTab(viewModel: viewModel)
        case .agent:     AgentTab(viewModel: viewModel)
        case .terminal:  TerminalTab(viewModel: viewModel)
        case .browser:   BrowserTab(viewModel: viewModel)
        case .voice:     VoiceTab(viewModel: viewModel)
        case .memory:    MemoryTab(viewModel: viewModel)
        case .auxiliary: AuxiliaryTab(viewModel: viewModel)
        case .security:  SecurityTab(viewModel: viewModel)
        case .advanced:  AdvancedTab(viewModel: viewModel)
        }
    }
}
