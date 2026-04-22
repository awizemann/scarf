import SwiftUI

struct SidebarView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        List(selection: $coordinator.selectedSection) {
            Section("Monitor") {
                ForEach([SidebarSection.dashboard, .insights, .sessions, .activity]) { section in
                    Label {
                        Text(section.displayName)
                    } icon: {
                        Image(systemName: section.icon)
                    }
                    .tag(section)
                }
            }
            Section("Projects") {
                ForEach([SidebarSection.projects]) { section in
                    Label {
                        Text(section.displayName)
                    } icon: {
                        Image(systemName: section.icon)
                    }
                    .tag(section)
                }
            }
            Section("Interact") {
                ForEach([SidebarSection.chat, .memory, .skills]) { section in
                    Label {
                        Text(section.displayName)
                    } icon: {
                        Image(systemName: section.icon)
                    }
                    .tag(section)
                }
            }
            Section("Configure") {
                ForEach([SidebarSection.platforms, .personalities, .quickCommands, .credentialPools, .plugins, .webhooks, .profiles]) { section in
                    Label {
                        Text(section.displayName)
                    } icon: {
                        Image(systemName: section.icon)
                    }
                    .tag(section)
                }
            }
            Section("Manage") {
                ForEach([SidebarSection.tools, .mcpServers, .gateway, .cron, .health, .logs, .settings]) { section in
                    Label {
                        Text(section.displayName)
                    } icon: {
                        Image(systemName: section.icon)
                    }
                    .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Scarf")
        .splitViewAutosaveName("ScarfMainSidebar")
    }
}
