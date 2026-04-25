import SwiftUI
import ScarfCore
import ScarfDesign

/// Sheet for renaming a project in the registry. Preserves the
/// project's `path`, `folder`, and `archived` fields — the rename
/// only changes the user-visible name (and therefore the Identifiable
/// id). Duplicate-name / empty-name rejection lives in the VM.
struct RenameProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: ProjectEntry
    /// Current set of project names in the registry, used to flag
    /// duplicates before the user tries to Save. Excludes the
    /// project being renamed so same-name is a no-op (accepted).
    let existingNames: [String]
    /// Called with the trimmed new name. Caller is responsible for
    /// calling `ProjectsViewModel.renameProject(_:to:)`; this sheet
    /// just gathers input + validates inline.
    let onSave: (String) -> Void

    @State private var newName: String

    init(
        project: ProjectEntry,
        existingNames: [String],
        onSave: @escaping (String) -> Void
    ) {
        self.project = project
        self.existingNames = existingNames
        self.onSave = onSave
        _newName = State(initialValue: project.name)
    }

    /// Validation for the live input. Empty / whitespace-only / a
    /// collision with another project's name all disable Save.
    private var validation: (isValid: Bool, message: String?) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (false, nil) // no error message — just disabled
        }
        if trimmed != project.name && existingNames.contains(trimmed) {
            return (false, String(localized: "A project named \"\(trimmed)\" already exists."))
        }
        return (true, nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Rename project")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Text("The project directory on disk isn't changed — only the label Scarf shows in the sidebar.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)

            ScarfTextField("Project name", text: $newName)
                .onSubmit {
                    if validation.isValid {
                        save()
                    }
                }

            if let message = validation.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.danger)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(ScarfGhostButton())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(ScarfPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validation.isValid)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(minWidth: 420)
    }

    private func save() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed)
        dismiss()
    }
}
