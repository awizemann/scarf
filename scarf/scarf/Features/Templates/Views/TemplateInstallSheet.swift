import SwiftUI
import AppKit

/// Preview-and-confirm sheet for installing a `.scarftemplate`. Honest
/// accounting: shows every file that will be written, every cron job that
/// will be registered, and the memory diff — nothing gets written until the
/// user clicks Install.
struct TemplateInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var viewModel: TemplateInstallerViewModel
    let onCompleted: (ProjectEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch viewModel.stage {
            case .idle:
                idleView
            case .fetching(let src):
                progress("Downloading from \(src)…")
            case .inspecting:
                progress("Inspecting template…")
            case .awaitingParentDirectory:
                pickParentView
            case .planned:
                if let plan = viewModel.plan {
                    plannedView(plan: plan)
                } else {
                    progress("Preparing…")
                }
            case .installing:
                progress("Installing…")
            case .succeeded(let entry):
                successView(entry: entry)
            case .failed(let message):
                failureView(message: message)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .padding()
    }

    // MARK: - Stages

    private var idleView: some View {
        VStack(spacing: 16) {
            Text("No template loaded.")
                .font(.headline)
            Button("Close") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progress(_ label: LocalizedStringKey) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pickParentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let manifest = viewModel.inspection?.manifest {
                manifestHeader(manifest)
                Divider()
            }
            Text("Where should this project live?")
                .font(.headline)
            Text("Scarf will create a new folder inside the directory you pick, named after the template id.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Cancel") {
                    viewModel.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Folder…") { chooseParentDirectory() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func plannedView(plan: TemplateInstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            manifestHeader(plan.manifest)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectFilesSection(plan: plan)
                    if plan.skillsNamespaceDir != nil {
                        skillsSection(plan: plan)
                    }
                    if !plan.cronJobs.isEmpty {
                        cronSection(plan: plan)
                    }
                    if plan.memoryAppendix != nil {
                        memorySection(plan: plan)
                    }
                    readmeSection
                }
                .padding(.vertical)
            }
            Divider()
            HStack {
                Button("Cancel") {
                    viewModel.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(plan.totalWriteCount) changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Install") { viewModel.confirmInstall() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
    }

    private func manifestHeader(_ manifest: ProjectTemplateManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(manifest.name).font(.title2.bold())
                Text("v\(manifest.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(manifest.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(manifest.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let author = manifest.author {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(author.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let url = author.url, let parsed = URL(string: url) {
                        Link(parsed.host ?? url, destination: parsed)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func projectFilesSection(plan: TemplateInstallPlan) -> some View {
        section(title: "New project directory", subtitle: plan.projectDir) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(plan.projectFiles, id: \.destinationPath) { copy in
                    fileRow(label: copy.destinationPath, systemImage: "doc.text")
                }
            }
        }
    }

    private func skillsSection(plan: TemplateInstallPlan) -> some View {
        section(
            title: "Skills (namespaced, safe to remove later)",
            subtitle: plan.skillsNamespaceDir
        ) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(plan.skillsFiles, id: \.destinationPath) { copy in
                    fileRow(label: copy.destinationPath, systemImage: "puzzlepiece")
                }
            }
        }
    }

    private func cronSection(plan: TemplateInstallPlan) -> some View {
        section(title: "Cron jobs (created disabled — you can enable each one manually)", subtitle: nil) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.cronJobs, id: \.name) { job in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.name).font(.callout.monospaced())
                            Text("schedule: \(job.schedule)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func memorySection(plan: TemplateInstallPlan) -> some View {
        section(title: "Memory appendix", subtitle: plan.memoryPath) {
            ScrollView {
                Text(plan.memoryAppendix ?? "")
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(maxHeight: 160)
        }
    }

    private var readmeSection: some View {
        Group {
            // The body is preloaded in the VM off MainActor when inspection
            // completes — no sync file I/O during View body evaluation.
            if let readme = viewModel.readmeBody {
                section(title: "README", subtitle: nil) {
                    ScrollView {
                        Text(readme)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, subtitle: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            content()
                .padding(.top, 2)
        }
    }

    private func fileRow(label: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(label)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private func successView(entry: ProjectEntry) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Installed \(entry.name)")
                .font(.title2.bold())
            Text(entry.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Button("Open Project") {
                onCompleted(entry)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Install Failed").font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") {
                viewModel.cancel()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func chooseParentDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Parent Folder")
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.pickParentDirectory(url.path)
        }
    }

}
