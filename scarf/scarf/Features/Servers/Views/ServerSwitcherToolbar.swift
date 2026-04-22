import SwiftUI
import ScarfCore

/// Toolbar control that shows the current window's server and exposes a
/// menu for opening *other* servers in additional windows. Multi-window is
/// the primary interaction model — each window is bound to one server for
/// its whole lifetime — so the dropdown action is "Open in new window",
/// not "switch in place".
struct ServerSwitcherToolbar: View {
    @Environment(\.serverContext) private var current
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow
    @State private var showManage = false

    var body: some View {
        Menu {
            Text("Current: \(current.displayName)")
                .font(.caption)
            Divider()
            Section("Open in new window") {
                if current.id != ServerContext.local.id {
                    openRow(.local)
                }
                ForEach(registry.entries) { entry in
                    if entry.id != current.id {
                        openRow(entry.context)
                    }
                }
            }
            Divider()
            Button {
                showManage = true
            } label: {
                Label("Manage Servers…", systemImage: "server.rack")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(current.isRemote ? Color.blue : Color.green)
                    .frame(width: 8, height: 8)
                Text(verbatim: current.displayName)
                    .font(.callout)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .menuIndicator(.hidden)
        .popover(isPresented: $showManage, arrowEdge: .bottom) {
            ManageServersView()
        }
    }

    @ViewBuilder
    private func openRow(_ context: ServerContext) -> some View {
        Button {
            openWindow(value: context.id)
        } label: {
            Label(context.displayName, systemImage: context.isRemote ? "server.rack" : "laptopcomputer")
        }
    }
}
