import SwiftUI

/// Preview-and-confirm sheet for uninstalling a template-installed
/// project. Symmetric with the install sheet: lists every file, cron
/// job, and memory block that will be removed BEFORE anything happens.
struct TemplateUninstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var viewModel: TemplateUninstallerViewModel
    /// Called on success with the project that was removed. Parent uses
    /// this to refresh its projects list and clear any selection.
    let onCompleted: (ProjectEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch viewModel.stage {
            case .idle:
                idleView
            case .loading:
                progress("Reading template.lock.json…")
            case .planned:
                if let plan = viewModel.plan {
                    plannedView(plan: plan)
                } else {
                    progress("Preparing…")
                }
            case .uninstalling:
                progress("Removing…")
            case .succeeded(let removed):
                successView(removed: removed)
            case .failed(let message):
                failureView(message: message)
            }
        }
        .frame(minWidth: 620, minHeight: 480)
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

    private func plannedView(plan: TemplateUninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(plan: plan)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectFilesSection(plan: plan)
                    if plan.skillsNamespaceDir != nil {
                        skillsSection(plan: plan)
                    }
                    cronSection(plan: plan)
                    memorySection(plan: plan)
                    registrySection(plan: plan)
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
                Text("\(plan.totalRemoveCount) changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove") { viewModel.confirmUninstall() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.top, 8)
        }
    }

    private func header(plan: TemplateUninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Remove “\(plan.lock.templateName)”").font(.title2.bold())
                Text("v\(plan.lock.templateVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(plan.lock.templateId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Installed \(plan.lock.installedAt)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func projectFilesSection(plan: TemplateUninstallPlan) -> some View {
        section(title: "Project directory", subtitle: plan.project.path) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.projectFilesToRemove, id: \.self) { path in
                    fileRow(
                        label: path,
                        systemImage: "minus.circle",
                        color: .red,
                        tag: "remove"
                    )
                }
                ForEach(plan.projectFilesAlreadyGone, id: \.self) { path in
                    fileRow(
                        label: path,
                        systemImage: "questionmark.circle",
                        color: .secondary,
                        tag: "already gone"
                    )
                }
                ForEach(plan.extraProjectEntries, id: \.self) { path in
                    fileRow(
                        label: path,
                        systemImage: "lock.shield",
                        color: .green,
                        tag: "keep (not installed by template)"
                    )
                }
                if plan.projectDirBecomesEmpty {
                    Text("Project directory will also be removed (nothing user-owned left inside).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else if !plan.extraProjectEntries.isEmpty {
                    Text("Project directory stays — it still holds files you created after install.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func skillsSection(plan: TemplateUninstallPlan) -> some View {
        section(
            title: "Skills",
            subtitle: plan.skillsNamespaceDir
        ) {
            HStack(spacing: 6) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text("Remove the entire namespace dir recursively")
                    .font(.caption)
            }
        }
    }

    private func cronSection(plan: TemplateUninstallPlan) -> some View {
        section(
            title: "Cron jobs",
            subtitle: plan.cronJobsToRemove.isEmpty && plan.cronJobsAlreadyGone.isEmpty
                ? "none"
                : nil
        ) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.cronJobsToRemove, id: \.id) { job in
                    HStack(spacing: 6) {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.name).font(.callout.monospaced())
                            Text(job.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(plan.cronJobsAlreadyGone, id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("\(name) — already gone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func memorySection(plan: TemplateUninstallPlan) -> some View {
        if plan.memoryBlockPresent {
            section(title: "Memory block", subtitle: plan.memoryPath) {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Strip the template's begin/end block, preserve everything else in MEMORY.md")
                        .font(.caption)
                }
            }
        } else if plan.lock.memoryBlockId != nil {
            section(title: "Memory block", subtitle: nil) {
                Text("A memory block was recorded in the lock but is no longer present in MEMORY.md — skipping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func registrySection(plan: TemplateUninstallPlan) -> some View {
        section(title: "Projects registry", subtitle: nil) {
            HStack(spacing: 6) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text("Remove \"\(plan.project.name)\" from Scarf's project list")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        title: LocalizedStringKey,
        subtitle: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
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

    private func fileRow(label: String, systemImage: String, color: Color, tag: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.caption)
            Text(label)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Text(tag)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func successView(removed: ProjectEntry) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Removed \(removed.name)")
                .font(.title2.bold())

            // Preserved-files banner. Only renders when the project dir
            // stayed and at least one file was left behind — that's the
            // case the user keeps getting surprised by ("I uninstalled
            // but my project folder is still there?"). Explicit
            // explanation + file list makes it obvious the files the
            // user (or the cron job) created are intentionally kept.
            if let outcome = viewModel.preservedOutcome,
               outcome.projectDirRemoved == false,
               outcome.preservedPaths.isEmpty == false {
                preservedFilesBanner(outcome: outcome)
            }

            Button("Done") {
                onCompleted(removed)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Orange informational banner listing the files the uninstaller
    /// left in the project directory. Caps the visible list at 8 rows
    /// with a "+N more…" tail so a long log (many runs = many status
    /// file entries) doesn't blow out the sheet height.
    private func preservedFilesBanner(
        outcome: TemplateUninstallerViewModel.PreservedOutcome
    ) -> some View {
        let visible = Array(outcome.preservedPaths.prefix(8))
        let overflow = outcome.preservedPaths.count - visible.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.questionmark")
                    .foregroundStyle(.orange)
                Text("Project folder kept")
                    .font(.headline)
            }
            Text("These files weren't installed by the template (the agent or you created them after install), so Scarf left them in place along with the folder itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visible, id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if overflow > 0 {
                    Text("+ \(overflow) more…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Delete \(outcome.projectDir) from Finder if you don't need these files anymore.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.10))
        )
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Uninstall Failed").font(.title2.bold())
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
}
