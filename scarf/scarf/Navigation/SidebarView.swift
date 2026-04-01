import SwiftUI

struct SidebarView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        List(selection: $coordinator.selectedSection) {
            Section("Monitor") {
                ForEach([SidebarSection.dashboard, .insights, .sessions, .activity]) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            Section("Projects") {
                ForEach([SidebarSection.projects]) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            Section("Interact") {
                ForEach([SidebarSection.chat, .memory, .skills]) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            Section("Manage") {
                ForEach([SidebarSection.tools, .gateway, .cron, .health, .logs, .settings]) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Scarf")
    }
}
