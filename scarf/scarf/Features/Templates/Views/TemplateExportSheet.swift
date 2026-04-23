import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Author-facing sheet for exporting an existing project as a
/// `.scarftemplate`. Mirrors the profile-export flow: fill in a few fields,
/// pick which skills/cron jobs to include, save via NSSavePanel.
struct TemplateExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var viewModel: TemplateExporterViewModel

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.stage {
            case .idle:
                form
            case .exporting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Building template…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .succeeded(let path):
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Exported").font(.title2.bold())
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Export Failed").font(.title2.bold())
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .padding()
        .task { viewModel.load() }
    }

    @ViewBuilder
    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Export \"\(viewModel.project.name)\" as Template")
                    .font(.title2.bold())
                metadataGroup
                Divider()
                requiredFilesGroup
                Divider()
                instructionsGroup
                Divider()
                skillsGroup
                Divider()
                cronGroup
                Divider()
                memoryGroup
            }
            .padding(.bottom)
        }
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Export…") { runExport() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canExport)
        }
        .padding(.top, 8)
    }

    private var metadataGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata").font(.headline)
            LabeledContent("Template ID") {
                TextField("owner/name", text: $viewModel.templateId)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Display Name") {
                TextField("", text: $viewModel.templateName)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Version") {
                TextField("1.0.0", text: $viewModel.templateVersion)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Description") {
                TextField("One-line pitch", text: $viewModel.templateDescription, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Author") {
                TextField("Your name", text: $viewModel.authorName)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Author URL") {
                TextField("https://…", text: $viewModel.authorURL)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Category") {
                TextField("e.g. productivity", text: $viewModel.category)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Tags (comma-separated)") {
                TextField("focus, timer", text: $viewModel.tags)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var requiredFilesGroup: some View {
        let plan = viewModel.previewPlan()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Required Files").font(.headline)
            check(label: "dashboard.json (\(plan.projectDir)/.scarf/dashboard.json)", ok: plan.dashboardPresent)
            check(label: "README.md (\(plan.projectDir)/README.md)", ok: plan.readmePresent)
            check(label: "AGENTS.md (\(plan.projectDir)/AGENTS.md)", ok: plan.agentsMdPresent)
        }
    }

    private var instructionsGroup: some View {
        let plan = viewModel.previewPlan()
        return VStack(alignment: .leading, spacing: 4) {
            Text("Agent-specific instructions (optional)").font(.headline)
            if plan.instructionFiles.isEmpty {
                Text("No per-agent instruction files found in the project root.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(plan.instructionFiles, id: \.self) { file in
                    Label(file, systemImage: "doc.plaintext")
                        .font(.callout)
                }
            }
        }
    }

    private var skillsGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Include Skills").font(.headline)
            if viewModel.availableSkills.isEmpty {
                Text("No skills found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.availableSkills) { skill in
                    Toggle(isOn: Binding(
                        get: { viewModel.includeSkillIds.contains(skill.id) },
                        set: { on in
                            if on { viewModel.includeSkillIds.insert(skill.id) }
                            else { viewModel.includeSkillIds.remove(skill.id) }
                        }
                    )) {
                        Text(skill.id).font(.callout.monospaced())
                    }
                }
            }
        }
    }

    private var cronGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Include Cron Jobs").font(.headline)
            if viewModel.availableCronJobs.isEmpty {
                Text("No cron jobs found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.availableCronJobs) { job in
                    Toggle(isOn: Binding(
                        get: { viewModel.includeCronJobIds.contains(job.id) },
                        set: { on in
                            if on { viewModel.includeCronJobIds.insert(job.id) }
                            else { viewModel.includeCronJobIds.remove(job.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(job.name).font(.callout)
                            Text(job.schedule.display ?? job.schedule.expression ?? job.schedule.kind)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var memoryGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory Appendix (optional)").font(.headline)
            Text("Markdown that will be appended to the installer's MEMORY.md, wrapped in template-specific markers so it can be removed cleanly later.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.memoryAppendix)
                .font(.callout.monospaced())
                .frame(minHeight: 80, maxHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.secondary.opacity(0.4))
                )
        }
    }

    private func check(label: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
                .font(.caption)
                .foregroundStyle(ok ? .primary : .secondary)
        }
    }

    private var canExport: Bool {
        let plan = viewModel.previewPlan()
        return plan.dashboardPresent
            && plan.readmePresent
            && plan.agentsMdPresent
            && !viewModel.templateId.trimmingCharacters(in: .whitespaces).isEmpty
            && !viewModel.templateName.trimmingCharacters(in: .whitespaces).isEmpty
            && !viewModel.templateVersion.trimmingCharacters(in: .whitespaces).isEmpty
            && !viewModel.templateDescription.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = ProjectTemplateExporter.slugify(viewModel.templateName) + ".scarftemplate"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.export(to: url.path)
        }
    }
}
