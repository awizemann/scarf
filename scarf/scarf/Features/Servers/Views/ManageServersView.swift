import SwiftUI
import ScarfCore

/// List of registered remote servers with add/remove actions. Rendered as a
/// popover from the toolbar switcher.
struct ManageServersView: View {
    @Environment(ServerRegistry.self) private var registry
    @State private var showAddSheet = false
    @State private var pendingRemoveID: ServerID?
    @State private var diagnosticsContext: ServerContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if registry.entries.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: 440, height: 380)
        .sheet(isPresented: $showAddSheet) {
            AddServerSheet { name, config in
                _ = registry.addServer(displayName: name, config: config)
            }
        }
        .sheet(item: Binding(
            get: { diagnosticsContext.map { IdentifiableContext(context: $0) } },
            set: { diagnosticsContext = $0?.context }
        )) { wrapper in
            RemoteDiagnosticsView(context: wrapper.context)
        }
        .confirmationDialog(
            "Remove this server?",
            isPresented: Binding(
                get: { pendingRemoveID != nil },
                set: { if !$0 { pendingRemoveID = nil } }
            ),
            actions: {
                Button("Remove", role: .destructive) {
                    if let id = pendingRemoveID { registry.removeServer(id) }
                    pendingRemoveID = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoveID = nil }
            },
            message: {
                Text("The server's SSH configuration is removed from Scarf. Your remote files are untouched.")
            }
        )
    }

    /// Wrapper because `ServerContext` isn't `Identifiable` against the sheet
    /// item API in a way that preserves display-ordering stability.
    private struct IdentifiableContext: Identifiable {
        var id: ServerID { context.id }
        let context: ServerContext
    }

    private var header: some View {
        HStack {
            Text("Servers").font(.headline)
            Spacer()
            Button {
                showAddSheet = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No remote servers").font(.headline)
            Text("Click Add to connect to a remote Hermes installation over SSH.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        let defaultID = registry.defaultServerID
        return List {
            // Local sits at the top so users can mark it as the open-on-launch
            // default alongside remote servers. It's synthesized (not in
            // `registry.entries`), so render it explicitly.
            HStack(spacing: 10) {
                defaultStar(for: ServerContext.local.id, currentDefault: defaultID)
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local").font(.body)
                    Text("This Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            ForEach(registry.entries) { entry in
                HStack(spacing: 10) {
                    defaultStar(for: entry.id, currentDefault: defaultID)
                    Image(systemName: "server.rack")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: entry.displayName).font(.body)
                        if case .ssh(let config) = entry.kind {
                            Text(summary(for: config))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        diagnosticsContext = entry.context
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                    .buttonStyle(.borderless)
                    .help("Run remote diagnostics — check exactly which files are readable on this server.")
                    Button {
                        pendingRemoveID = entry.id
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Remove this server from Scarf.")
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
    }

    /// A star button that marks the open-on-launch default. Filled + yellow
    /// on the current default row (disabled, since clicking would be a
    /// no-op); outline + secondary elsewhere, clicking promotes that row
    /// to default.
    @ViewBuilder
    private func defaultStar(for id: ServerID, currentDefault: ServerID) -> some View {
        let isDefault = id == currentDefault
        Button {
            registry.setDefaultServer(id)
        } label: {
            Image(systemName: isDefault ? "star.fill" : "star")
                .foregroundStyle(isDefault ? .yellow : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(isDefault)
        .help(isDefault ? "Opens on launch" : "Set as default — open this server when Scarf launches.")
    }

    private func summary(for config: SSHConfig) -> String {
        var s = ""
        if let user = config.user, !user.isEmpty { s += "\(user)@" }
        s += config.host
        if let port = config.port { s += ":\(port)" }
        if let home = config.remoteHome, !home.isEmpty { s += " (\(home))" }
        return s
    }
}
