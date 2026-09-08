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
    @State private var pendingRemoveID: ServerID?
    @State private var diagnosticsContext: ServerContext?
    @State private var importAlert: ImportAlertState?
    @State private var backupContext: ServerContext?
    @State private var restoreContext: ServerContext?
    /// Last damage sentence announced to VoiceOver, so a republished but
    /// unchanged `storeDamage` doesn't repeat itself (AX H1).
    @State private var lastAnnouncedDamagePath: String?

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
            if let damage = registry.storeDamage {
                damageBanner(damage)
                Divider()
            } else if let failure = registry.saveFailure {
                saveFailureBanner(failure)
                Divider()
            }
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

    /// `servers.json` is damaged, so the list below is whatever Scarf holds
    /// in memory and every add/remove/rename is being REFUSED rather than
    /// published over a file nobody could read (GW-E2b). Without this the
    /// refusal would be silent and the user would think their edit stuck.
    @ViewBuilder
    private func damageBanner(_ damage: ServerRegistry.StoreDamage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The PROSE is one combined VoiceOver element (AX H1's house
            // pattern); the retry button below has to stay its own
            // focusable control, so the grouping moved in here rather than
            // sitting on the whole banner and swallowing it.
            VStack(alignment: .leading, spacing: 4) {
                Label("Your server list couldn't be read", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .scarfStyle(.headline)
                // GW-F6 / audit DI M6: "until it can read it again" promised
                // a retry that did not exist — nothing re-read the file for
                // the life of the window. The sentence is now true because
                // the button below it is what makes it true.
                Text(damage.refusedSave
                     ? "Changes you make here are kept in this session only — Scarf won't overwrite \(damage.path) until it can read it again."
                     : "Scarf won't overwrite \(damage.path) until it can read it again, so changes you make here stay in this session only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let quarantine = damage.quarantinePath {
                    // AX M2: the path is the actionable half of this
                    // sentence — the user has to go find that file.
                    // Monospaced so a path reads as a path, and selectable
                    // so it can be copied (there is no "Show in Finder"
                    // here: the file may live on a remote host). Split from
                    // the prose for the same reason `RegistryDamageBanner`
                    // splits it.
                    //
                    // Absent for a file refused on SIZE: that one is never
                    // read, so there are no bytes to copy aside (GW-F5) and
                    // promising a copy would send the user hunting for a
                    // file that does not exist.
                    Text("A copy of the unreadable file is at:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(quarantine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Button("Try Reading It Again") { registry.retryLoad() }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityHint(damage.refusedSave
                    ? "Re-reads the server list file. If it can be read now, the changes you made in this session are saved to it."
                    : "Re-reads the server list file.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // AX H1: the banner has no chrome of its own to draw a VoiceOver
        // user's attention, so its appearance was exactly as silent as the
        // refusal it exists to announce. Guarded on the last announced
        // value: `storeDamage` republishes on every registry read, and a
        // stable warning re-announcing on each one is worse than silence
        // (`RegistryDamageBanner` is the house pattern).
        .onAppear { announceDamage(damage) }
        .onChange(of: damage.path) { _, _ in announceDamage(damage) }
    }

    /// A save that was ALLOWED and failed anyway (GW-F6 / audit DI M5) — a
    /// full disk, a read-only volume, permissions. Nothing is damaged, so
    /// this is not the refusal banner: there is no quarantine copy to point
    /// at and no read to retry, only a write to try again once the user has
    /// fixed the cause.
    @ViewBuilder
    private func saveFailureBanner(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Your server list couldn't be saved", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .scarfStyle(.headline)
                Text("Changes you make here are kept in this session only: \(failure)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Button("Try Saving Again") { registry.retrySave() }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityHint("Writes the server list to disk again.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .onAppear { announce(failure: failure) }
        .onChange(of: failure) { _, new in announce(failure: new) }
    }

    private func announce(failure: String) {
        let spoken = String(
            localized: "Your server list couldn’t be saved. Changes you make here are kept in this session only. \(failure)"
        )
        guard lastAnnouncedDamagePath != spoken else { return }
        lastAnnouncedDamagePath = spoken
        AccessibilityNotification.Announcement(AttributedString(spoken)).post()
    }

    private func announceDamage(_ damage: ServerRegistry.StoreDamage) {
        let spoken = String(
            localized: "Your server list couldn’t be read. Scarf won’t overwrite \(damage.path) until it can read it again, so changes you make here stay in this session only."
        )
        guard lastAnnouncedDamagePath != spoken else { return }
        lastAnnouncedDamagePath = spoken
        AccessibilityNotification.Announcement(AttributedString(spoken)).post()
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
                showAddSheet = true
            } label: {
                Label("Add", systemImage: "plus")
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
        panel.title = String(localized: "Export Servers")
        panel.prompt = String(localized: "Export")
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
        panel.title = String(localized: "Import Servers")
        panel.prompt = String(localized: "Import")
        panel.allowedContentTypes = [Self.scarfServersType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let summary = try registry.importEntries(from: data)
            let count = summary.imported
            let skipped = summary.skippedDuplicates
            // GW-F6 / audit DI M7: the title used to claim the import
            // regardless of whether it reached `servers.json`. A refused or
            // failed save means the entries are in this session only, and
            // that is what the alert now says.
            let title: String
            if count > 0 && !summary.persisted {
                title = "Imported into this session only"
            } else {
                title = count == 0 && skipped > 0
                    ? "Nothing to import"
                    : (count == 1 ? "Imported 1 server" : "Imported \(count) servers")
            }
            var lines: [String] = []
            if count > 0, !summary.persisted {
                lines.append("Scarf couldn't write \(count == 1 ? "it" : "them") to your server list: \(summary.persistFailure ?? "the save didn't complete"). The imported \(count == 1 ? "server is" : "servers are") usable now but won't survive a restart.")
            }
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
            Text("No remote servers").scarfStyle(.headline)
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Local, this Mac")
                Spacer()
                actionsMenu(for: ServerContext.local, removable: false)
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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(rowLabel(for: entry))
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
        .accessibilityLabel("Server actions")
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
        .accessibilityLabel(isDefault ? "Default server" : "Set as default server")
        .help(isDefault ? "Opens on launch" : "Set as default — open this server when Scarf launches.")
    }

    /// Spoken row label: server name first, then its connection
    /// summary. The default-server state is carried by the star
    /// button's own label, so it isn't repeated here.
    private func rowLabel(for entry: ServerEntry) -> String {
        guard case .ssh(let config) = entry.kind else { return entry.displayName }
        return "\(entry.displayName), \(summary(for: config))"
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
