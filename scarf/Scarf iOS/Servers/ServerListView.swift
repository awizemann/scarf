import SwiftUI
import ScarfCore
import ScarfIOS
import ScarfDesign

/// ScarfGo's root surface when the user has at least one server
/// configured. Replaces the pre-M9 "boot straight into Dashboard"
/// flow — which worked while the app was single-server, but had
/// nowhere to put a second host once multi-server landed.
///
/// Each row shows nickname + host and navigates to ScarfGoTabRoot
/// on tap. The "+" toolbar button re-enters onboarding for a new
/// server. Swipe → Forget (destructive, with confirmation) so users
/// can prune without going into the More tab.
struct ServerListView: View {
    let model: RootModel

    @State private var serverPendingForget: ServerRow?

    var body: some View {
        NavigationStack {
            List {
                if let err = model.lastError {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.headline)
                            Text(err)
                                .font(.callout)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 12) {
                                Button("Dismiss") { model.clearLastError() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    ForEach(sortedServers, id: \.id) { row in
                        ServerListRow(row: row) {
                            Task { await model.connect(to: row.id) }
                        }
                        .scarfGoCompactListRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                serverPendingForget = row
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("Tap a server to connect. Swipe for more actions.")
                        .font(.caption)
                }
            }
            .scarfGoListDensity()
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.beginAddServer()
                    } label: {
                        Label("Add server", systemImage: "plus.circle.fill")
                    }
                }
            }
            .task { await model.refreshServers() }
            .confirmationDialog(
                "Forget this server?",
                isPresented: forgetBinding,
                titleVisibility: .visible,
                presenting: serverPendingForget
            ) { row in
                Button("Forget \(row.displayName)", role: .destructive) {
                    Task {
                        await model.forget(id: row.id)
                        serverPendingForget = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    serverPendingForget = nil
                }
            } message: { row in
                Text("Removes \(row.displayName)'s SSH key and host details from this device. Other servers stay configured.")
            }
        }
    }

    /// View-model carrier — Identifiable + stable sort key. Fileprivate
    /// so the ServerListRow subview in this same file can reference
    /// it; the rest of the module doesn't need it.
    fileprivate struct ServerRow: Identifiable, Hashable {
        let id: ServerID
        let displayName: String
        let host: String
        let port: Int?
        let user: String?
    }

    /// Project the model's `servers` dict into a sortable list.
    /// Alphabetical by display name so the ordering is deterministic
    /// and matches what users see in the picker.
    private var sortedServers: [ServerRow] {
        model.servers
            .map { id, config in
                ServerRow(
                    id: id,
                    displayName: config.displayName,
                    host: config.host,
                    port: config.port,
                    user: config.user
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// `.confirmationDialog(isPresented:)` wants a Bool binding; map
    /// `serverPendingForget` to one so the dialog dismisses when we
    /// clear the optional.
    private var forgetBinding: Binding<Bool> {
        Binding(
            get: { serverPendingForget != nil },
            set: { newValue in
                if !newValue { serverPendingForget = nil }
            }
        )
    }
}

private struct ServerListRow: View {
    let row: ServerListView.ServerRow
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(hostLine)
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Second-row subtitle: `user@host:port` when fully specified,
    /// else whichever pieces are known.
    private var hostLine: String {
        var parts: [String] = []
        if let user = row.user, !user.isEmpty {
            parts.append("\(user)@\(row.host)")
        } else {
            parts.append(row.host)
        }
        if let port = row.port, port != 22 {
            parts[parts.count - 1] += ":\(port)"
        }
        return parts.joined(separator: " ")
    }
}

// ServerRow needs to live outside the private struct for the
// confirmationDialog(presenting:) closure to reference it. Swift's
// type scoping won't let us put Identifiable conformance on a nested
// struct that's used from the view's top level; we accept a small
// scope leak.
extension ServerListView.ServerRow: @unchecked Sendable {}
