import SwiftUI

/// Settings is now organized into tabs because the full Hermes config surface is far
/// too large for a single scrolling form (~70 config fields). Each tab has its own
/// extracted view file under `Tabs/` — per CLAUDE.md guidance, splitting avoids
/// SwiftUI type-checker timeouts and keeps each section testable in isolation.
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
            headerBar
            Divider()
            TabView(selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            tabContent(tab)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.icon)
                    }
                    .tag(tab)
                }
            }
        }
        .navigationTitle("Settings")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading settings…",
            isEmpty: viewModel.rawConfigYAML.isEmpty
        )
        .onAppear { viewModel.load() }
    }

    private var headerBar: some View {
        HStack {
            if let msg = viewModel.saveMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("Open in Editor") { viewModel.openConfigInEditor() }
                .controlSize(.small)
            Button("Reload") { viewModel.load() }
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
