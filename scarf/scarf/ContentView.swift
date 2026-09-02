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
        // Mini-apps present in a trailing OVERLAY, not SwiftUI `.inspector`:
        // an inspector is a layout column that grows the window under
        // `.windowResizability(.contentMinSize)` (it "slid wider"). The
        // overlay keeps the window's size and covers the right ~74% of the
        // chrome; the left stays interactive. See MiniAppInspectorSurface.
        .overlay {
            if let presented = coordinator.presentedMiniApp {
                MiniAppInspectorSurface {
                    MiniAppLaunchHost(
                        project: presented.project,
                        manifest: presented.manifest,
                        serverContext: serverContext,
                        onClose: { coordinator.presentedMiniApp = nil }
                    )
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: coordinator.presentedMiniApp?.id)
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
        // Cached like Cron/Peers: the roster is a per-profile file scan
        // plus avatar reads, all over the transport — rebuilding it on
        // every section switch would re-read every profile over SSH.
        // Peers is passed in from the coordinator's own cache — same
        // instance as the standalone Peers section below — so an async-run
        // handle started in one pane stays visible/stoppable in the other
        // (queued audit-board item A2-F5).
        case .bots:             BotsView(viewModel: cachedVM(.bots) {
                                     BotsViewModel(
                                         context: serverContext,
                                         peers: cachedVM(.peers) { PeersViewModel(context: serverContext) }
                                     )
                                 })
        case .chat:             ChatView()
        case .memory:           MemoryView(context: serverContext)
        case .curator:          CuratorView(context: serverContext)
        case .skills:           SkillsView(context: serverContext)
        case .platforms:        PlatformsView(viewModel: cachedVM(.platforms) { PlatformsViewModel(context: serverContext) })
        case .personalities:    PersonalitiesView(context: serverContext)
        case .quickCommands:    QuickCommandsView(viewModel: cachedVM(.quickCommands) { QuickCommandsViewModel(context: serverContext) })
        case .credentialPools:  CredentialPoolsView(context: serverContext)
        case .plugins:          PluginsView(viewModel: cachedVM(.plugins) { PluginsViewModel(context: serverContext) })
        case .webhooks:         WebhooksView(viewModel: cachedVM(.webhooks) { WebhooksViewModel(context: serverContext) })
        case .profiles:         ProfilesView(context: serverContext)
        case .models:           ModelPresetsView(viewModel: cachedVM(.models) { ModelPresetsViewModel(context: serverContext) })
        case .proxy:            HermesProxyView(context: serverContext)
        case .tools:            ToolsView(context: serverContext)
        case .mcpServers:       MCPServersView(viewModel: cachedVM(.mcpServers) { MCPServersViewModel(context: serverContext) })
        case .gateway:          GatewayView(context: serverContext)
        case .cron:             CronView(viewModel: cachedVM(.cron) { CronViewModel(context: serverContext) })
        // Cached like Cron: the VM holds peer run handles, and `hermes
        // peer` has no verb to re-enumerate them after a rebuild.
        case .peers:            PeersView(viewModel: cachedVM(.peers) { PeersViewModel(context: serverContext) })
        case .kanban:           KanbanView(context: serverContext)
        case .health:           HealthView(context: serverContext)
        case .logs:             LogsView(context: serverContext)
        case .settings:         SettingsView(viewModel: cachedVM(.settings) { SettingsViewModel(context: serverContext) })
        }
    }

    /// Resolve a feature view model from the per-window/-server cache in
    /// `AppCoordinator` so switching sidebar sections reuses the existing
    /// instance (and its loaded data) instead of rebuilding it and re-running
    /// `load()` over SSH on every re-entry (t-aud24). `make` runs only on a
    /// cache miss.
    private func cachedVM<VM: AnyObject>(_ section: SidebarSection, _ make: () -> VM) -> VM {
        coordinator.featureViewModel(for: section, make: make)
    }
}
