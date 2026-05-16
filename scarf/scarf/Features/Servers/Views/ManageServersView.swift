import SwiftUI
import ScarfCore
import ScarfDesign
import UniformTypeIdentifiers
import AppKit

/// List of registered remote servers with add/remove actions. Rendered as a
/// popover from the toolbar switcher.
struct ManageServersView: View {
    @Environment(ServerRegistry.self) private var registry
    @State private var showAddSheet = false
    @State private var showGatewaySettings = false
    @State private var gatewayConfig: GatewayScarfConnectionConfig?
    @State private var pendingRemoveID: ServerID?
    @State private var diagnosticsContext: ServerContext?
    @State private var importAlert: ImportAlertState?
    @State private var backupContext: ServerContext?
    @State private var restoreContext: ServerContext?

    /// Lightweight wrapper around the after-import message so we can
    /// present a single SwiftUI `.alert` for both success summaries
    /// ("Imported 3 servers") and refusals ("Schema v2 not recognized").
    private struct ImportAlertState: Identifiable {
        var id = UUID()
        var title: String
        var message: String
    }

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
        .onAppear { reloadGatewayConfig() }
        .sheet(isPresented: $showGatewaySettings, onDismiss: reloadGatewayConfig) {
            GatewayScarfSettingsSheet { config in
                _ = registry.ensureGatewayScarfServer(config: config, setAsDefault: true)
            }
        }
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
        .sheet(item: Binding(
            get: { backupContext.map { IdentifiableContext(context: $0) } },
            set: { backupContext = $0?.context }
        )) { wrapper in
            BackupServerSheet(context: wrapper.context)
        }
        .sheet(item: Binding(
            get: { restoreContext.map { IdentifiableContext(context: $0) } },
            set: { restoreContext = $0?.context }
        )) { wrapper in
            RestoreServerSheet(context: wrapper.context)
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
        .alert(item: $importAlert) { state in
            Alert(title: Text(state.title), message: Text(state.message), dismissButton: .default(Text("OK")))
        }
    }

    /// Wrapper because `ServerContext` isn't `Identifiable` against the sheet
    /// item API in a way that preserves display-ordering stability.
    private struct IdentifiableContext: Identifiable {
        var id: ServerID { context.id }
        let context: ServerContext
    }

    private var header: some View {
        HStack {
            Text("Servers").scarfStyle(.headline)
            Spacer()
            Menu {
                Button("Export Servers…") { exportServers() }
                    .disabled(registry.entries.isEmpty)
                Button("Import Servers…") { importServers() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Export or import the list of remote servers. SSH keys aren't included — you copy those separately.")
            Button {
                showGatewaySettings = true
            } label: {
                Label("Gateway", systemImage: "network")
            }
            .buttonStyle(.borderless)
            Button {
                showAddSheet = true
            } label: {
                Label("SSH", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    /// `.scarfservers` is a plain JSON file (`ServerRegistry.exportFile()`).
    /// Declared inline so callers don't need a shared UTType module just to
    /// open one save panel. The conformance is dual: also `.json` so users
    /// renaming the file don't break the import handler.
    private static let scarfServersType: UTType = {
        if let t = UTType("com.scarf.servers") { return t }
        return UTType.json
    }()

    private func exportServers() {
        let panel = NSSavePanel()
        panel.title = "Export Servers"
        panel.prompt = "Export"
        panel.allowedContentTypes = [Self.scarfServersType, .json]
        panel.nameFieldStringValue = "scarf-servers-\(Self.todayStamp()).scarfservers"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try registry.exportFile()
            try data.write(to: url, options: .atomic)
        } catch {
            importAlert = ImportAlertState(
                title: "Couldn't export servers",
                message: error.localizedDescription
            )
        }
    }

    private func importServers() {
        let panel = NSOpenPanel()
        panel.title = "Import Servers"
        panel.prompt = "Import"
        panel.allowedContentTypes = [Self.scarfServersType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let summary = try registry.importEntries(from: data)
            let count = summary.imported
            let skipped = summary.skippedDuplicates
            let title = count == 0 && skipped > 0
                ? "Nothing to import"
                : (count == 1 ? "Imported 1 server" : "Imported \(count) servers")
            var lines: [String] = []
            if count == 0 && skipped > 0 {
                lines.append("Every entry was already in your registry. Nothing changed.")
            } else if skipped > 0 {
                lines.append("\(skipped) duplicate \(skipped == 1 ? "entry was" : "entries were") skipped — your existing copy is preserved.")
            }
            lines.append("SSH keys aren't included in the export — make sure your `~/.ssh/` keys are in place on this Mac, or edit each server to point at the right identity file.")
            importAlert = ImportAlertState(title: title, message: lines.joined(separator: "\n\n"))
        } catch let err as ServerRegistry.ImportError {
            importAlert = ImportAlertState(
                title: "Couldn't import servers",
                message: err.localizedDescription
            )
        } catch {
            importAlert = ImportAlertState(
                title: "Couldn't import servers",
                message: error.localizedDescription
            )
        }
    }

    /// `yyyy-MM-dd` so the exported filename sorts naturally in Finder
    /// when a user accumulates rotating exports.
    private static func todayStamp() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(gatewayConfig == nil ? "No Gateway configured" : "Gateway configured")
                .scarfStyle(.headline)
            Text(gatewayConfig == nil ? "Configure Gateway Scarf to connect by URL. Add SSH only if you still need direct shell access." : "Gateway Scarf is configured. Add SSH only if you still need direct shell access.")
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
            if let gatewayConfig {
                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gateway Scarf").font(.body)
                        Text(gatewayConfig.baseURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { showGatewaySettings = true }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }

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
                    actionsMenu(for: entry.context, removable: true)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
    }

    /// Per-row actions menu. Consolidates Backup / Restore /
    /// Diagnostics / Remove behind a single ellipsis so the row stays
    /// readable as the count of available actions grows. Local
    /// servers can be backed up + restored just like remotes
    /// (running `tar` against `~/.hermes`) but can't be removed —
    /// the local entry is synthesized, not registry-backed.
    @ViewBuilder
    private func actionsMenu(for context: ServerContext, removable: Bool) -> some View {
        Menu {
            Button {
                backupContext = context
            } label: {
                Label("Back Up…", systemImage: "arrow.down.doc")
            }
            Button {
                restoreContext = context
            } label: {
                Label("Restore from Backup…", systemImage: "arrow.up.doc")
            }
            if context.isRemote {
                Divider()
                Button {
                    diagnosticsContext = context
                } label: {
                    Label("Diagnostics…", systemImage: "stethoscope")
                }
            }
            if removable {
                Divider()
                Button(role: .destructive) {
                    pendingRemoveID = context.id
                } label: {
                    Label("Remove Server…", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Backup, restore, or remove this server.")
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

    private func reloadGatewayConfig() {
        gatewayConfig = try? GatewayScarfConnectionConfig.load(environment: [:])
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
