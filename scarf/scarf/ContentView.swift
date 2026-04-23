import SwiftUI

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
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
        } detail: {
            detailView
                // The detail column's size is what NavigationSplitView
                // reports up to the window. Without a bound here, the
                // reported ideal is derived from the currently-rendered
                // section's natural intrinsic size — and some sections
                // (Chat with a fully-materialized message list, the
                // v2.3 per-project Sessions tab) have intrinsic heights
                // that exceed the screen. With `.windowResizability
                // (.contentMinSize)` in scarfApp, the window is forced
                // at least that tall, pushing its bottom edge past the
                // visible desktop and hiding the input bar.
                //
                // This frame pins the detail's reported ideal at a
                // modest 900×600 — small enough to fit any reasonable
                // screen — while allowing it to expand freely to
                // whatever the user drags the window to. `minHeight: 0`
                // is load-bearing: it overrides the "my child's min is
                // huge" chain so NavigationSplitView doesn't carry a
                // massive min up to the window.
                .frame(
                    minWidth: 500,
                    idealWidth: 900,
                    maxWidth: .infinity,
                    minHeight: 300,
                    idealHeight: 600,
                    maxHeight: .infinity
                )
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
