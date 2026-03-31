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
        case .sessions:
            SessionsView()
        case .activity:
            ActivityView()
        case .chat:
            ChatView()
        case .memory:
            MemoryView()
        case .skills:
            SkillsView()
        case .cron:
            CronView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }
}
