import SwiftUI
import ScarfCore

/// Sheet for assigning a project to a folder in the sidebar. Folders
/// are implicit — they exist because at least one project references
/// them via its `folder` field. The "create" action here just seeds
/// a new label the user types; it becomes real once any project is
/// assigned to it.
struct MoveToFolderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: ProjectEntry
    /// Existing folder labels in the registry, sorted. Computed by
    /// the caller via `ProjectsViewModel.folders`.
    let existingFolders: [String]
    /// Called with the chosen folder. `nil` means "move back to top
    /// level". Caller wires this through
    /// `ProjectsViewModel.moveProject(_:toFolder:)`.
    let onMove: (String?) -> Void

    @State private var mode: Mode
    @State private var newFolderName: String = ""

    private enum Mode: Hashable {
        case topLevel
        case existing(String)
        case new
    }

    init(
        project: ProjectEntry,
        existingFolders: [String],
        onMove: @escaping (String?) -> Void
    ) {
        self.project = project
        self.existingFolders = existingFolders
        self.onMove = onMove
        // Start selection on the project's current folder if any,
        // otherwise "Top Level". Feels right — Move sheet should
        // reflect where the project currently lives.
        if let current = project.folder, existingFolders.contains(current) {
            _mode = State(initialValue: .existing(current))
        } else {
            _mode = State(initialValue: .topLevel)
        }
    }

    private var canMove: Bool {
        switch mode {
        case .topLevel, .existing:
            return true
        case .new:
            return !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \"\(project.name)\" to folder").font(.headline)
            Text("Folders only affect how projects are grouped in Scarf's sidebar. Nothing on disk changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Destination", selection: $mode) {
                Text("Top Level").tag(Mode.topLevel)
                if !existingFolders.isEmpty {
                    Section {
                        ForEach(existingFolders, id: \.self) { folder in
                            Text(folder).tag(Mode.existing(folder))
                        }
                    }
                }
                Text("New folder…").tag(Mode.new)
            }
            .labelsHidden()
            .pickerStyle(.inline)

            if case .new = mode {
                TextField("New folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if canMove { commit() }
                    }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canMove)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 320)
    }

    private func commit() {
        switch mode {
        case .topLevel:
            onMove(nil)
        case .existing(let folder):
            onMove(folder)
        case .new:
            let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onMove(trimmed)
        }
        dismiss()
    }
}
