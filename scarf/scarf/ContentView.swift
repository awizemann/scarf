import SwiftUI
import ScarfCore

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.serverContext) private var serverContext
    /// Per-window connection status. Constructed from the window's
    /// `serverContext` once; lifetime matches the window.
    @State private var connectionStatus: ConnectionStatusViewModel

    init() {
        _connectionStatus = State(initialValue: ConnectionStatusViewModel(context: .local))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 224, max: 360)
        } detail: {
            detailView
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ServerSwitcherToolbar()
                    }
                    if serverContext.isRemote {
                        // `.principal` centers the pill in the toolbar —
                        // the native emphasis bezel is the intended frame;
                        // the pill's own visual content (icon + label, no
                        // background) sits inside it in balance.
                        ToolbarItem(placement: .principal) {
                            ConnectionStatusPill(status: connectionStatus)
                        }
                    }
                }
                .onAppear {
                    // The actual context is injected via @Environment, which
                    // isn't available in `init`. Rebuild the monitor here
                    // the first time we know the real context. Safe to call
                    // repeatedly; `startMonitoring()` cancels + restarts.
                    if connectionStatus.context.id != serverContext.id {
                        connectionStatus = ConnectionStatusViewModel(context: serverContext)
                    }
                    connectionStatus.startMonitoring()
                }
                .onDisappear { connectionStatus.stopMonitoring() }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        // Each routed view receives the window's `serverContext` in its
        // init so its `@State` ViewModel is constructed bound to the right
        // server. This is what makes multi-window work — without it,
        // every window's VMs default-construct with `.local` even though
        // the surrounding env has the right context.
        switch coordinator.selectedSection {
        case .dashboard:        DashboardView(context: serverContext)
        case .insights:         InsightsView(context: serverContext)
        case .sessions:         SessionsView(context: serverContext)
        case .activity:         ActivityView(context: serverContext)
        case .projects:         ProjectsView(context: serverContext)
        case .chat:             ChatView()
        case .memory:           MemoryView(context: serverContext)
        case .skills:           SkillsView(context: serverContext)
        case .platforms:        PlatformsView(context: serverContext)
        case .personalities:    PersonalitiesView(context: serverContext)
        case .quickCommands:    QuickCommandsView(context: serverContext)
        case .credentialPools:  CredentialPoolsView(context: serverContext)
        case .plugins:          PluginsView(context: serverContext)
        case .webhooks:         WebhooksView(context: serverContext)
        case .profiles:         ProfilesView(context: serverContext)
        case .tools:            ToolsView(context: serverContext)
        case .mcpServers:       MCPServersView(context: serverContext)
        case .gateway:          GatewayView(context: serverContext)
        case .cron:             CronView(context: serverContext)
        case .health:           HealthView(context: serverContext)
        case .logs:             LogsView(context: serverContext)
        case .settings:         SettingsView(context: serverContext)
        }
    }
}
