import AppKit
import ScarfCore
import ScarfDesign
import SwiftUI

/// Wizard for creating a new Scarf-standard project from scratch.
///
/// The wizard is intentionally minimal: project name, folder name
/// (auto-derived from the name but editable), parent directory, and
/// an optional one-liner about what the project is for. On commit,
/// `ProjectScaffolder` creates the directory tree with a placeholder
/// dashboard and a stub AGENTS.md (just the Scarf-managed marker
/// block). Then we hand off to the chat surface with an auto-prompt
/// that activates the bundled `scarf-template-author` skill, which
/// drives the rest conversationally — choosing widgets, designing a
/// config schema if needed, scheduling cron jobs.
///
/// This sheet replaces nothing. The existing `AddProjectSheet`
/// (registers an existing directory) and the template-install flow
/// (creates a project from a `.scarftemplate` bundle) both stay —
/// this is the third entry point covering the "I want a fresh,
/// hand-rolled project" gap.
struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppCoordinator.self) private var coordinator

    @State var viewModel: NewProjectViewModel
    /// Called with the freshly-registered project AFTER the sheet
    /// dismisses. Caller refreshes its registry view, updates file
    /// watches, and selects the new project for visual feedback.
    let onCreate: (ProjectEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    folderField
                    parentDirField
                    descriptionField
                    pathPreview
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 480)
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Project").scarfStyle(.title2)
                Text("Scarf scaffolds the directory; the agent helps you fill it in.")
                    .scarfStyle(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Project Name").scarfStyle(.headline)
                Text("*").scarfStyle(.headline).foregroundStyle(.red)
            }
            Text("Display name shown in Scarf's sidebar and at the top of the dashboard.")
                .scarfStyle(.caption)
                .foregroundStyle(.secondary)
            TextField("Acme Q3 Review", text: Bindable(viewModel).projectName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("newProject.name")
                .accessibilityLabel("Project Name")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var folderField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Folder Name").scarfStyle(.headline)
                Text("*").scarfStyle(.headline).foregroundStyle(.red)
            }
            Text("Lowercase letters, numbers, and dashes — created as `<parent>/<folder>`.")
                .scarfStyle(.caption)
                .foregroundStyle(.secondary)
            TextField("acme-q3", text: Bindable(viewModel).folderName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("newProject.folder")
                .accessibilityLabel("Folder Name")
            if !viewModel.folderName.isEmpty,
               !ProjectScaffolder.isValidSlug(viewModel.folderName) {
                Label(
                    "Folder name needs lowercase letters, digits, or dashes — no leading/trailing or doubled dashes.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .scarfStyle(.caption)
                .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var parentDirField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Parent Directory").scarfStyle(.headline)
                Text("*").scarfStyle(.headline).foregroundStyle(.red)
            }
            Text("Where the new project folder lands on disk.")
                .scarfStyle(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("~/Projects", text: Bindable(viewModel).parentDirectory)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("newProject.parent")
                    .accessibilityLabel("Parent Directory")
                Button("Choose…") {
                    chooseParentDirectory()
                }
                .accessibilityIdentifier("newProject.parent.choose")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's it for?").scarfStyle(.headline)
            Text("Optional — one-liner that helps the agent tailor the setup interview.")
                .scarfStyle(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Bindable(viewModel).description)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.secondary.opacity(0.3))
                )
                .accessibilityIdentifier("newProject.description")
                .accessibilityLabel("What's it for?")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pathPreview: some View {
        if !viewModel.folderName.isEmpty,
           !viewModel.parentDirectory.isEmpty,
           ProjectScaffolder.isValidSlug(viewModel.folderName) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("Will create").scarfStyle(.caption).foregroundStyle(.secondary)
                Text(viewModel.resolvedProjectPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.background.secondary)
            )
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .scarfStyle(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("newProject.cancelButton")
                Spacer()
                Button {
                    Task { await runCommit() }
                } label: {
                    if viewModel.isCommitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create & Open Chat")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ScarfPrimaryButton())
                .disabled(!viewModel.canCommit || viewModel.isCommitting)
                .accessibilityIdentifier("newProject.createButton")
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func chooseParentDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose Parent Directory"
        panel.message = "The new project folder will be created inside this directory."
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.parentDirectory = url.path
        }
    }

    private func runCommit() async {
        guard let entry = await viewModel.commit() else { return }
        // "New Project from Scratch" has no template concept at all — the
        // wizard is name/folder/parent-dir only, so `template` is always
        // this fixed token rather than anything the user typed.
        Analytics.record(.projectCreated(template: .custom, method: .scaffold))
        // Stage the chat handoff BEFORE dismissing so SwiftUI's
        // sheet dismissal doesn't preempt the coordinator update.
        let prompt = viewModel.buildInitialPrompt(for: entry)
        coordinator.pendingProjectChat = entry.path
        coordinator.pendingInitialPrompt = prompt
        coordinator.selectedSection = .chat
        onCreate(entry)
        dismiss()
    }
}
