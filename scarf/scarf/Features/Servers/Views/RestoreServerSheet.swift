import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScarfCore
import ScarfDesign

/// Sheet for restoring a `.scarfbackup` onto a server. Walks the user
/// through file pick → inspect (manifest preview + hash verify) →
/// confirm scope → run → done.
struct RestoreServerSheet: View {
    let context: ServerContext
    @State private var viewModel: RestoreServerViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: RestoreServerViewModel(context: context))
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
        .frame(width: 580, height: 560)
        .task {
            if case .awaitingFile = viewModel.phase {
                presentOpenPanel()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.doc")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore from backup").scarfStyle(.headline)
                Text("Target: \(context.displayName)")
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
        case .awaitingFile:
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.up")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Pick a `.scarfbackup` file to inspect.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)

        case .inspecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Validating archive + verifying hashes…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)

        case .ready(let inspection):
            readyView(inspection: inspection)

        case .running(let step):
            runningView(step: step)

        case .done(let result):
            doneView(result: result)

        case .failed(let message):
            failedView(message: message)
        }
    }

    private func readyView(inspection: RemoteRestoreService.InspectionResult) -> some View {
        let m = inspection.manifest
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Source").font(.subheadline).bold().foregroundStyle(.secondary)
                row(label: "Server", value: m.source.displayName)
                row(label: "Host", value: m.source.host, mono: true)
                row(label: "Hermes version", value: m.source.hermesVersion ?? "(unknown)")
                row(label: "Backup time", value: m.createdAt)
                row(label: "Hermes size", value: ByteCountFormatter.string(fromByteCount: m.hermes.tarballSize, countStyle: .file))
                row(label: "Projects", value: "\(m.projects.count)")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Target").font(.subheadline).bold().foregroundStyle(.secondary)
                row(label: "Server", value: context.displayName)
                if let v = inspection.targetHermesVersion {
                    row(label: "Hermes version", value: v)
                }
                if let h = inspection.targetHomeResolved {
                    row(label: "Home", value: h, mono: true)
                }
            }

            if !m.projects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Projects landing path").font(.subheadline).bold().foregroundStyle(.secondary)
                    HStack {
                        TextField("e.g. /home/ubuntu/projects", text: $viewModel.targetProjectsRoot)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .accessibilityLabel("Projects landing path")
                    }
                    Text("Each project lands at `<this path>/<project name>`. Existing files at the same path will be overwritten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $viewModel.pauseCronJobs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause cron jobs after restore").font(.callout)
                        Text("Restored cron jobs may carry stale credentials or schedules you no longer want. Pausing them lets you re-enable intentionally from the Cron view.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Warning panel for sensitive contents.
            VStack(alignment: .leading, spacing: 6) {
                if !m.options.includeAuth {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("`auth.json` was excluded — re-authenticate AI providers after restore.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !m.options.includeMcpTokens {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("MCP tokens were excluded — re-authenticate any MCP servers (Spotify, Google Workspace, etc.) after restore.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func runningView(step: RemoteRestoreService.Progress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                Text(stepLabel(step)).font(.subheadline)
            }
            switch step {
            case .restoringHermes(let n):
                Text("Hermes home: \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) pushed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .restoringProject(let name, let n):
                Text("\(name): \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) pushed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 30)
    }

    private func doneView(result: RemoteRestoreService.RestoreResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Restore complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            row(label: "Hermes home", value: result.hermesHome, mono: true)
            row(label: "Projects", value: "\(result.projectsRestored.count) restored")
            if result.cronJobsPaused > 0 {
                row(label: "Cron jobs paused", value: "\(result.cronJobsPaused)")
            }
            if !result.projectsRestored.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restored to").font(.caption).foregroundStyle(.secondary)
                    ForEach(result.projectsRestored, id: \.targetPath) { p in
                        Text(verbatim: "\(p.name) → \(p.targetPath)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Re-authenticate AI providers and any MCP servers from Settings if those weren't included in the backup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Restore failed", systemImage: "xmark.octagon.fill")
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
            case .ready(let inspection):
                Button("Restore") { viewModel.runRestore(inspection: inspection) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.targetProjectsRoot.isEmpty)
            case .failed:
                Button("Pick another file") { presentOpenPanel() }
                    .keyboardShortcut(.defaultAction)
            case .awaitingFile:
                Button("Pick a backup…") { presentOpenPanel() }
                    .keyboardShortcut(.defaultAction)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Backup")
        panel.prompt = String(localized: "Inspect")
        panel.allowedContentTypes = [Self.scarfBackupType, .zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            // User cancelled — keep the awaitingFile phase so the
            // sheet's "Pick a backup…" button stays available.
            return
        }
        Task { await viewModel.inspect(archiveURL: url) }
    }

    private static let scarfBackupType: UTType = {
        if let t = UTType(filenameExtension: BackupArchiveLayout.archiveExtension) { return t }
        return UTType.archive
    }()

    private func stepLabel(_ step: RemoteRestoreService.Progress) -> String {
        switch step {
        case .validating: return "Validating archive…"
        case .verifyingHashes: return "Verifying hashes…"
        case .planning: return "Planning…"
        case .restoringHermes: return "Restoring Hermes home…"
        case .restoringProject(let name, _): return "Restoring project: \(name)…"
        case .reanchoringPaths: return "Re-anchoring project paths…"
        case .pausingCron: return "Pausing cron jobs…"
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
