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
    /// the per-server `ContextBoundRoot`.
    private var capabilities: HermesCapabilities {
        capabilitiesStore?.capabilities ?? .empty
    }

    /// Capability-filtered platform list. Every gated row carries its floor
    /// as DATA (`HermesToolPlatform.minimumVersion`, walked across every
    /// tag), so there is one uniform rule here — the `google_chat` special
    /// case this filter used to carry read the same floor by a different
    /// route, and Yuanbao / Teams / ntfy / WhatsApp Cloud / Buzz joined the
    /// gated set in P23 (Alan's round-2 decision 6).
    ///
    /// `isVisible` rather than `isAvailable`: a platform the user has
    /// already CONFIGURED stays listed even below the floor, so a failed
    /// version probe never hides their own setup from them.
    private var visiblePlatforms: [HermesToolPlatform] {
        KnownPlatforms.visible(on: capabilities) {
            // Before the detached load lands, `configuredPlatforms` is empty
            // because nothing has been READ — not because nothing is
            // configured. Answering `false` there hides a configured
            // sub-floor row for the first paint and pops it in a moment
            // later; answering `true` renders what Scarf rendered before the
            // gate existed and then settles down to the gated list.
            !viewModel.hasLoadedConfiguredPlatforms
                || viewModel.configuredPlatforms.contains($0)
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
        .onAppear {
            viewModel.load(changeToken: fileWatcher.lastChangeDate)
            // `onChange` fires on a CHANGE, so it covers the narrowing that
            // happens while this view is on screen. This covers re-entry: the
            // VM is cached in `AppCoordinator`, so a selection made in an
            // earlier visit arrives already stale against a roster that is
            // narrow from the first paint.
            viewModel.reconcileSelection(visible: visiblePlatforms)
        }
        // Re-read config.yaml / .env / gateway_state.json when any of them
        // changes on disk. This is how the left-side connectivity dots refresh
        // after the user saves in a per-platform setup form. The token guard in
        // `load()` skips the re-read on a plain section re-entry but always
        // honors a real on-disk change (the token advances).
        .onChange(of: fileWatcher.lastChangeDate) { _, newValue in
            viewModel.load(changeToken: newValue)
        }
        // The roster NARROWS after the fact — every row renders until the
        // detached read lands, so a sub-floor row can be selected in that
        // window and the selection binding above can only ever SET from the
        // visible list. Snap it back when it leaves (round-3 decision 8).
        .onChange(of: visiblePlatforms.map(\.name)) { _, _ in
            viewModel.reconcileSelection(visible: visiblePlatforms)
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
            OutcomeMessageBar(
                text: viewModel.message,
                kind: viewModel.messageKind,
                onDismiss: { viewModel.dismissMessage() }
            )
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
        // `bluebubbles` is the real Hermes platform id. Scarf's own
        // `imessage` spelling was renamed away in this cycle and is no longer
        // a `KnownPlatforms` row, so `viewModel.selected.name` can never be
        // it — the extra arm was unreachable.
        case "bluebubbles":    IMessageSetupView(context: ctx)
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
