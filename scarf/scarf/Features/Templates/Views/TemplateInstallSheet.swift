import AppKit
import ScarfCore
import SwiftUI

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
            case .awaitingConfig:
                configureView
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

    /// Configure step for schemaful templates. Inlines
    /// `TemplateConfigSheet` into the install flow rather than pushing
    /// a second sheet on top — keeps the user in one window. The
    /// nested VM is created freshly each time `.awaitingConfig` is
    /// entered so a Cancel + retry doesn't carry stale form state.
    @ViewBuilder
    private var configureView: some View {
        if let plan = viewModel.plan,
           let schema = plan.configSchema,
           let manifest = viewModel.inspection?.manifest {
            TemplateConfigSheet(
                viewModel: TemplateConfigViewModel(
                    schema: schema,
                    templateId: manifest.id,
                    templateSlug: manifest.slug,
                    initialValues: plan.configValues,
                    mode: .install
                ),
                title: "Configure \(manifest.name)",
                commitLabel: "Continue",
                project: ProjectEntry(name: plan.projectRegistryName, path: plan.projectDir),
                onCommit: { values in
                    viewModel.submitConfig(values: values)
                },
                onCancel: {
                    viewModel.cancelConfig()
                }
            )
        } else {
            progress("Preparing…")
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
                    if let schema = plan.configSchema, !schema.isEmpty {
                        configurationSection(plan: plan, schema: schema)
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
            // Inline-only markdown — descriptions are a sentence or two;
            // bold/italic/code/links are all that reasonable template
            // authors use there.
            TemplateMarkdown.inlineText(manifest.description)
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
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.cronJobs, id: \.name) { job in
                    VStack(alignment: .leading, spacing: 4) {
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
                        // Prompt preview — disclosed in an expandable
                        // group so the preview stays compact when the
                        // user doesn't care to read it. Markdown-rendered
                        // so prompts that include `code`, **bold**, or
                        // enumerated steps look right. Tokens like
                        // {{PROJECT_DIR}} are still visible here — they
                        // get substituted when the installer calls
                        // `hermes cron create`.
                        if let prompt = job.prompt, !prompt.isEmpty {
                            DisclosureGroup("Prompt") {
                                ScrollView {
                                    TemplateMarkdown.render(prompt)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 140)
                                .padding(8)
                                .background(.quaternary.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .font(.caption)
                            .padding(.leading, 26)
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

    /// Configuration values the user entered in the configure step.
    /// Secrets display masked so the preview never echoes a freshly
    /// typed API key back on screen.
    private func configurationSection(plan: TemplateInstallPlan, schema: TemplateConfigSchema) -> some View {
        section(title: "Configuration", subtitle: "written to \(plan.projectDir)/.scarf/config.json") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(schema.fields) { field in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(field.key)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 120, alignment: .leading)
                        Text(displayValue(for: field, in: plan.configValues))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    /// One-line display form for a value in the preview. Secrets are
    /// always masked; lists show a count + first entry; strings are
    /// truncated by `.lineLimit(1)` at the view level.
    private func displayValue(
        for field: TemplateConfigField,
        in values: [String: TemplateConfigValue]
    ) -> String {
        switch field.type {
        case .secret:
            return values[field.key] == nil ? "(not set)" : "••••••• (Keychain)"
        case .list:
            if case .list(let items) = values[field.key] {
                if items.isEmpty { return "(none)" }
                if items.count == 1 { return items[0] }
                return "\(items[0]) + \(items.count - 1) more"
            }
            return "(none)"
        default:
            return values[field.key]?.displayString ?? "(not set)"
        }
    }

    private var readmeSection: some View {
        Group {
            // The body is preloaded in the VM off MainActor when inspection
            // completes — no sync file I/O during View body evaluation.
            if let readme = viewModel.readmeBody {
                section(title: "README", subtitle: nil) {
                    ScrollView {
                        TemplateMarkdown.render(readme)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
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
