import SwiftUI

struct PlatformsView: View {
    @State private var viewModel: PlatformsViewModel
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: PlatformsViewModel(context: context))
    }


    // HSplitView (not nested NavigationSplitView) because ContentView already
    // hosts the outer NavigationSplitView — nesting them breaks layout on macOS.
    var body: some View {
        HSplitView {
            platformList
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
            detail
                .frame(minWidth: 480)
        }
        .navigationTitle("Platforms")
        .onAppear { viewModel.load() }
        // Re-read config.yaml / .env / gateway_state.json when any of them
        // changes on disk. This is how the left-side connectivity dots refresh
        // after the user saves in a per-platform setup form.
        .onChange(of: fileWatcher.lastChangeDate) { viewModel.load() }
    }

    private var platformList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { viewModel.selected.name },
                set: { name in
                    if let p = viewModel.platforms.first(where: { $0.name == name }) {
                        viewModel.selected = p
                    }
                }
            )) {
                ForEach(viewModel.platforms) { platform in
                    HStack(spacing: 8) {
                        Image(systemName: KnownPlatforms.icon(for: platform.name))
                            .frame(width: 20)
                        Text(verbatim: platform.displayName)
                        Spacer()
                        Circle()
                            .fill(statusColor(viewModel.connectivity(for: platform)))
                            .frame(width: 8, height: 8)
                    }
                    .tag(platform.name)
                }
            }
            .listStyle(.inset)

            Divider()

            VStack(spacing: 4) {
                Button {
                    viewModel.restartGateway()
                } label: {
                    Label("Restart Gateway", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.restartInProgress)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                connectivitySection
                platformForm
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(viewModel.selected.name) // Force view rebuild when platform changes so per-platform state resets.
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: KnownPlatforms.icon(for: viewModel.selected.name))
                .font(.title)
            VStack(alignment: .leading) {
                Text(verbatim: viewModel.selected.displayName)
                    .font(.title2.bold())
                Text(statusDescription(viewModel.connectivity(for: viewModel.selected)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let msg = viewModel.message {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if viewModel.restartInProgress {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var connectivitySection: some View {
        SettingsSection(title: "Connection", icon: "dot.radiowaves.left.and.right") {
            let status = viewModel.connectivity(for: viewModel.selected)
            ReadOnlyRow(label: "Status", value: statusDescription(status))
            if case .error(let msg) = status {
                ReadOnlyRow(label: "Error", value: msg)
            }
            ReadOnlyRow(label: "Configured", value: viewModel.hasConfigBlock(for: viewModel.selected) ? "Yes" : "No")
        }
    }

    /// Dispatch to the right per-platform setup view based on the selection.
    /// Each setup view owns its own `@State` view model and handles load/save
    /// independently; the parent's `context` is forwarded so writes go to the
    /// right server.
    @ViewBuilder
    private var platformForm: some View {
        let ctx = viewModel.context
        switch viewModel.selected.name {
        case "cli":            cliPanel
        case "telegram":       TelegramSetupView(context: ctx)
        case "discord":        DiscordSetupView(context: ctx)
        case "slack":          SlackSetupView(context: ctx)
        case "whatsapp":       WhatsAppSetupView(context: ctx)
        case "signal":         SignalSetupView(context: ctx)
        case "email":          EmailSetupView(context: ctx)
        case "matrix":         MatrixSetupView(context: ctx)
        case "mattermost":     MattermostSetupView(context: ctx)
        case "feishu":         FeishuSetupView(context: ctx)
        case "imessage":       IMessageSetupView(context: ctx)
        case "homeassistant":  HomeAssistantSetupView(context: ctx)
        case "webhook":        WebhookSetupView(context: ctx)
        default:
            SettingsSection(title: LocalizedStringKey(viewModel.selected.displayName), icon: KnownPlatforms.icon(for: viewModel.selected.name)) {
                ReadOnlyRow(label: "Setup", value: "No setup form for this platform yet.")
            }
        }
    }

    private var cliPanel: some View {
        SettingsSection(title: "CLI", icon: "terminal") {
            ReadOnlyRow(label: "Scope", value: "Local terminal sessions")
            ReadOnlyRow(label: "Note", value: "CLI uses the main app — no platform-specific config.")
        }
    }

    private func statusColor(_ status: PlatformConnectivity) -> Color {
        switch status {
        case .connected: return .green
        case .configured: return .orange
        case .notConfigured: return .secondary.opacity(0.4)
        case .error: return .red
        }
    }

    private func statusDescription(_ status: PlatformConnectivity) -> String {
        switch status {
        case .connected: return "Connected"
        case .configured: return "Configured · not running"
        case .notConfigured: return "Not configured"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
