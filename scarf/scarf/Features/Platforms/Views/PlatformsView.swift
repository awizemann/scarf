import SwiftUI
import ScarfCore
import ScarfDesign

struct PlatformsView: View {
    // Owned by `AppCoordinator`'s feature-VM cache (t-aud24), not `@State`,
    // so the instance + its loaded data survive sidebar section switches.
    // Still observed: SwiftUI's Observation tracks property reads in `body`
    // regardless of how the `@Observable` reference is held.
    let viewModel: PlatformsViewModel
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    /// Capabilities resolved at view-eval time. Defaults to `.empty` outside
    /// the per-server `ContextBoundRoot`. Used to filter `KnownPlatforms.all`
    /// for v0.13-only entries (Google Chat) — see `visiblePlatforms` for
    /// the deliberate asymmetry: pre-v0.12 hosts still see Yuanbao + Teams
    /// unfiltered, by design.
    private var capabilities: HermesCapabilities {
        capabilitiesStore?.capabilities ?? .empty
    }

    /// Capability-filtered platform list. Today only **Google Chat** is
    /// gated — Yuanbao and Microsoft Teams stay unfiltered to avoid
    /// changing v0.12 host UX in a v0.13 work-stream (WS-5 plan §Q4).
    /// If we later decide to gate the v0.12 platforms too, add their
    /// flags here; the `default: true` arm keeps every other platform
    /// visible.
    private var visiblePlatforms: [HermesToolPlatform] {
        KnownPlatforms.all.filter { p in
            switch p.name {
            case "google_chat":
                return capabilities.hasGoogleChatPlatform
            default:
                return true
            }
        }
    }

    init(viewModel: PlatformsViewModel) {
        self.viewModel = viewModel
    }


    // HSplitView (not nested NavigationSplitView) because ContentView already
    // hosts the outer NavigationSplitView — nesting them breaks layout on macOS.
    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Platforms",
                subtitle: "Inbound channels the agent listens on. Set up tokens per platform."
            )
            HSplitView {
                platformList
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
                detail
                    .frame(minWidth: 480)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Platforms")
        .onAppear { viewModel.load(changeToken: fileWatcher.lastChangeDate) }
        // Re-read config.yaml / .env / gateway_state.json when any of them
        // changes on disk. This is how the left-side connectivity dots refresh
        // after the user saves in a per-platform setup form. The token guard in
        // `load()` skips the re-read on a plain section re-entry but always
        // honors a real on-disk change (the token advances).
        .onChange(of: fileWatcher.lastChangeDate) { _, newValue in
            viewModel.load(changeToken: newValue)
        }
    }

    private var platformList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { viewModel.selected.name },
                set: { name in
                    if let p = visiblePlatforms.first(where: { $0.name == name }) {
                        viewModel.selected = p
                    }
                }
            )) {
                ForEach(visiblePlatforms) { platform in
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
        case "ntfy":           NtfySetupView(context: ctx)
        case "whatsapp_cloud": WhatsAppCloudSetupView(context: ctx)
        case "simplex":        SimpleXSetupView(context: ctx)
        case "imessage":       IMessageSetupView(context: ctx)
        case "homeassistant":  HomeAssistantSetupView(context: ctx)
        case "webhook":        WebhookSetupView(context: ctx)
        case "yuanbao":        yuanbaoPanel
        case "teams":          microsoftTeamsPanel
        case "google_chat":    googleChatPanel
        default:
            SettingsSection(title: LocalizedStringKey(viewModel.selected.displayName), icon: KnownPlatforms.icon(for: viewModel.selected.name)) {
                ReadOnlyRow(label: "Setup", value: "No setup form for this platform yet.")
            }
        }
    }

    /// Hermes v0.12 — Yuanbao 元宝 ships as a native gateway adapter
    /// (the 18th platform). Setup is YAML-driven; we surface the
    /// shell command and a docs link rather than a per-field form
    /// because the auth dance is OAuth-style and lives outside Scarf.
    private var yuanbaoPanel: some View {
        SettingsSection(title: "Yuanbao 元宝", icon: KnownPlatforms.icon(for: "yuanbao")) {
            ReadOnlyRow(label: "Type", value: "Native gateway adapter (v0.12+)")
            ReadOnlyRow(label: "Setup", value: "Run `hermes setup` and select Yuanbao to walk the OAuth flow.")
            ReadOnlyRow(label: "Multi-image", value: "Supported via the gateway's centralized media routing.")
            ReadOnlyRow(label: "Configured", value: viewModel.hasConfigBlock(for: viewModel.selected) ? "Yes" : "No")
        }
    }

    /// Hermes v0.12 — Microsoft Teams ships as a plugin (the 19th
    /// platform). Surface that explicitly so users know the setup
    /// path differs from the native adapters.
    private var microsoftTeamsPanel: some View {
        SettingsSection(title: "Microsoft Teams", icon: KnownPlatforms.icon(for: "teams")) {
            ReadOnlyRow(label: "Type", value: "Plugin-shipped gateway platform (v0.12+)")
            ReadOnlyRow(label: "Setup", value: "Install the plugin from the Plugins tab, then run `hermes setup` to register the bot.")
            ReadOnlyRow(label: "Configured", value: viewModel.hasConfigBlock(for: viewModel.selected) ? "Yes" : "No")
        }
    }

    /// Hermes v0.13 — Google Chat is the 20th gateway platform. Like
    /// Yuanbao + Microsoft Teams, the auth dance is OAuth-style and
    /// lives outside Scarf, so the panel surfaces the setup verb rather
    /// than a per-field form. The `GatewayBehaviorSection` below it picks
    /// up the v0.13 allowlist + behavior toggles, capability-gated.
    @ViewBuilder
    private var googleChatPanel: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            SettingsSection(title: "Google Chat", icon: KnownPlatforms.icon(for: "google_chat")) {
                ReadOnlyRow(label: "Type", value: "Generic env-driven gateway adapter (v0.13+)")
                ReadOnlyRow(label: "Setup", value: "Run `hermes setup` and select Google Chat to walk the OAuth flow.")
                ReadOnlyRow(label: "Configured", value: viewModel.hasConfigBlock(for: viewModel.selected) ? "Yes" : "No")
            }
            GatewayBehaviorSection(
                platform: "google_chat",
                capabilities: capabilities,
                context: viewModel.context
            )
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
