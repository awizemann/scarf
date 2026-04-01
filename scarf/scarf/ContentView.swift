import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch coordinator.selectedSection {
        case .dashboard:
            DashboardView()
        case .insights:
            InsightsView()
        case .sessions:
            SessionsView()
        case .activity:
            ActivityView()
        case .projects:
            ProjectsView()
        case .chat:
            ChatView()
        case .memory:
            MemoryView()
        case .skills:
            SkillsView()
        case .tools:
            ToolsView()
        case .gateway:
            GatewayView()
        case .cron:
            CronView()
        case .health:
            HealthView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }
}
