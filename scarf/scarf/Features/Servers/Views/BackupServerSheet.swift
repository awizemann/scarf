import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScarfCore
import ScarfDesign

/// Sheet for running a full backup of a remote (or local) server. Walks
/// the user through preflight → confirm scope → run → done.
struct BackupServerSheet: View {
    let context: ServerContext
    @State private var viewModel: BackupServerViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: BackupServerViewModel(context: context))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 540)
        .task {
            if case .loading = viewModel.phase {
                await viewModel.start()
            }
        }
        // Cancel the in-flight remote backup if the sheet is dismissed
        // mid-run so the remote `tar`/SSH work doesn't keep going. (t-aud17)
        .onDisappear { viewModel.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Back up server").scarfStyle(.headline)
                Text(verbatim: context.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Probing the server…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)

        case .ready(let summary):
            readyView(summary: summary)

        case .running(let step):
            runningView(step: step)

        case .done(let result):
            doneView(result: result)

        case .failed(let message):
            failedView(message: message)
        }
    }

    private func readyView(summary: RemoteBackupService.PreflightSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scope").font(.subheadline).bold().foregroundStyle(.secondary)
                Text("Backs up the Hermes home (`~/.hermes/`) and every registered project so this server can be reconstructed from scratch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                row(label: "Hermes version", value: summary.hermesVersion ?? "(unknown)")
                row(label: "Hermes home", value: summary.hermesHomePath, mono: true)
                row(label: "Hermes home size", value: Self.formatBytes(summary.hermesHomeBytes))
                row(label: "Projects", value: "\(summary.projects.count) registered")
                if !summary.projects.isEmpty {
                    let total: Int64 = summary.projects.compactMap { $0.sizeBytes }.reduce(0, +)
                    row(label: "Projects size", value: Self.formatBytes(total))
                }
                if !summary.sqliteAvailable {
                    row(label: "WAL checkpoint", value: "skipped (sqlite3 not on remote PATH)")
                }
            }

            if !summary.projects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Projects to include").font(.subheadline).bold().foregroundStyle(.secondary)
                    ForEach(summary.projects, id: \.path) { p in
                        HStack(spacing: 6) {
                            Image(systemName: p.reachable ? "folder.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(p.reachable ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                                .font(.caption)
                            Text(verbatim: p.name).font(.callout)
                            Spacer()
                            Text(Self.formatBytes(p.sizeBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Optional inclusions").font(.subheadline).bold().foregroundStyle(.secondary)
                Toggle(isOn: $viewModel.includeAuth) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include `auth.json`").font(.callout)
                        Text("Provider credentials (Anthropic/OpenAI/Nous keys). **Off by default** — they're sensitive and you'll likely re-auth on the new droplet anyway.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $viewModel.includeLogs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include logs").font(.callout)
                        Text("`agent.log`, `errors.log`, `gateway.log`. Useful for forensics; usually skipped to keep archive size down.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func runningView(step: RemoteBackupService.Progress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                Text(stepLabel(step)).font(.subheadline)
            }
            switch step {
            case .archivingHermes(let n):
                Text("Hermes home: \(Self.formatBytes(n)) so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .archivingProject(let name, let n):
                Text("\(name): \(Self.formatBytes(n)) so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 30)
    }

    private func doneView(result: RemoteBackupService.BackupResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Backup complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            row(label: "Archive", value: result.archiveURL.lastPathComponent, mono: true)
            row(label: "Size", value: Self.formatBytes(result.archiveSize))
            row(label: "Hermes version", value: result.manifest.source.hermesVersion ?? "(unknown)")
            row(label: "Projects", value: "\(result.manifest.projects.count)")
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.archiveURL])
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Backup failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.headline)
            ScrollView {
                Text(verbatim: message)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }

    private var footer: some View {
        HStack {
            switch viewModel.phase {
            case .running:
                Button("Cancel", role: .destructive) {
                    viewModel.cancel()
                }
            default:
                Button("Close") { dismiss() }
            }
            Spacer()
            switch viewModel.phase {
            case .ready(let summary):
                Button("Back up…") { presentSavePanel(summary: summary) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .failed:
                Button("Try again") { Task { await viewModel.start() } }
                    .keyboardShortcut(.defaultAction)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func presentSavePanel(summary: RemoteBackupService.PreflightSummary) {
        let panel = NSSavePanel()
        panel.title = "Save Backup"
        panel.prompt = "Back Up"
        panel.nameFieldStringValue = viewModel.defaultArchiveName
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let backupDir = documentsURL.appendingPathComponent("Scarf Backups", isDirectory: true)
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            panel.directoryURL = backupDir
        }
        panel.allowedContentTypes = [Self.scarfBackupType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.runBackup(to: url, summary: summary)
    }

    /// `.scarfbackup` declared inline (project doesn't have a shared
    /// UTType bundle yet). `archive` parent type so Finder treats it
    /// like any other archive bundle.
    private static let scarfBackupType: UTType = {
        if let t = UTType(filenameExtension: BackupArchiveLayout.archiveExtension) { return t }
        return UTType.archive
    }()

    private static func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func stepLabel(_ step: RemoteBackupService.Progress) -> String {
        switch step {
        case .preflight: return "Preparing…"
        case .checkpointingDB: return "Checkpointing state.db…"
        case .archivingHermes: return "Archiving Hermes home…"
        case .archivingProject(let name, _): return "Archiving project: \(name)…"
        case .bundling: return "Bundling archive…"
        case .finalizing: return "Finalizing…"
        }
    }

    @ViewBuilder
    private func row(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(verbatim: value)
                .font(mono ? .system(.caption, design: .monospaced) : .callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
