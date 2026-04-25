import SwiftUI
import ScarfCore

/// The "Slash Commands" tab on the per-project surface. Lists the
/// project-scoped commands stored at `<project>/.scarf/slash-commands/`
/// and provides authoring affordances (add, edit, duplicate, delete).
///
/// Project-scoped commands are a Scarf-side primitive added in v2.5 —
/// they ship in `.scarftemplate` bundles and are intercepted by the chat
/// view models for client-side prompt expansion (see
/// `ProjectSlashCommandService.expand(_:withArgument:)`). The agent never
/// sees the slash; it sees the expanded prompt.
struct ProjectSlashCommandsView: View {
    let project: ProjectEntry

    @Environment(\.serverContext) private var serverContext
    @State private var viewModel: ProjectSlashCommandsViewModel

    init(project: ProjectEntry) {
        self.project = project
        _viewModel = State(initialValue: ProjectSlashCommandsViewModel(project: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Rerun on project change so switching the sidebar selection
        // rebuilds the VM under the new path. Re-inits with the host's
        // serverContext so remote projects read over SSH.
        .task(id: project.id) {
            viewModel = ProjectSlashCommandsViewModel(project: project, context: serverContext)
            await viewModel.load()
        }
        .sheet(item: Binding(
            get: { viewModel.draft },
            set: { newValue in
                if newValue == nil { viewModel.cancelEdit() }
            }
        )) { _ in
            SlashCommandEditorSheet(viewModel: viewModel)
                .frame(minWidth: 720, minHeight: 560)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Slash Commands")
                    .font(.headline)
                Text("`/<name>` shortcuts that expand into prompt templates. Stored at `<project>/.scarf/slash-commands/` so they ship with `.scarftemplate` bundles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                viewModel.beginNew()
            } label: {
                Label("Add Command", systemImage: "plus.circle.fill")
            }
            .controlSize(.regular)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView("Loading commands…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.commands.isEmpty {
            ContentUnavailableView {
                Label("No slash commands yet", systemImage: "slash.circle")
            } description: {
                Text("Add reusable prompt templates here. Each command shows up in the chat slash menu when you're chatting in this project.")
            } actions: {
                Button("Add Command") { viewModel.beginNew() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let err = viewModel.lastError {
                    errorBanner(err)
                }
                List {
                    ForEach(viewModel.commands) { cmd in
                        CommandRow(command: cmd)
                            .contextMenu {
                                Button("Edit…") { viewModel.beginEdit(cmd) }
                                Button("Duplicate") { viewModel.beginDuplicate(of: cmd) }
                                Divider()
                                Button("Delete…", role: .destructive) {
                                    Task { await viewModel.delete(cmd) }
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't update slash commands")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss") { viewModel.lastError = nil }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - Row

private struct CommandRow: View {
    let command: ProjectSlashCommand

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slash.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("/\(command.name)")
                        .font(.body.monospaced().weight(.medium))
                    if let hint = command.argumentHint, !hint.isEmpty {
                        Text(hint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                    if let model = command.model, !model.isEmpty {
                        Label(model, systemImage: "cpu")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }
                }
                Text(command.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let tags = command.tags, !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Editor sheet

/// Modal editor for a single slash command. Form on the left, live
/// preview pane on the right showing the expanded prompt with a
/// sample-argument field so the author can see what the agent will
/// actually receive.
struct SlashCommandEditorSheet: View {
    @Bindable var viewModel: ProjectSlashCommandsViewModel
    @State private var sampleArgument: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.draft?.isNew == true ? "Add Slash Command" : "Edit Slash Command")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { viewModel.cancelEdit() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await viewModel.saveDraft() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saveDisabled)
            }
            .padding()
            Divider()

            HSplitView {
                form
                    .frame(minWidth: 360, idealWidth: 380)
                preview
                    .frame(minWidth: 320)
            }
        }
    }

    private var saveDisabled: Bool {
        guard let d = viewModel.draft else { return true }
        return d.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || d.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var form: some View {
        if let _ = viewModel.draft {
            Form {
                Section("Identity") {
                    TextField("Name", text: Binding(
                        get: { viewModel.draft?.name ?? "" },
                        set: { viewModel.draft?.name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("Lowercase letters, digits, and hyphens. Must start with a letter.")
                    if let nameError = nameValidationMessage {
                        Text(nameError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    TextField("Description", text: Binding(
                        get: { viewModel.draft?.description ?? "" },
                        set: { viewModel.draft?.description = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("Shown as the subtitle in the chat slash menu.")
                }

                Section("Optional") {
                    TextField("Argument hint", text: Binding(
                        get: { viewModel.draft?.argumentHint ?? "" },
                        set: { viewModel.draft?.argumentHint = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("Placeholder shown after `/<name> ` in the menu — e.g. `<focus area>`.")
                    TextField("Model override", text: Binding(
                        get: { viewModel.draft?.model ?? "" },
                        set: { viewModel.draft?.model = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("Optional. Sets the LLM model for this turn.")
                    TextField("Tags (comma-separated)", text: Binding(
                        get: { viewModel.draft?.tags ?? "" },
                        set: { viewModel.draft?.tags = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                Section("Prompt template") {
                    Text("Use `{{argument}}` to substitute the user's input. `{{argument | default: \"…\"}}` provides a fallback when the user invokes the command without arguments.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { viewModel.draft?.body ?? "" },
                        set: { viewModel.draft?.body = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .border(Color.secondary.opacity(0.3))
                }
            }
            .formStyle(.grouped)
            .padding(.bottom)
        } else {
            ProgressView()
        }
    }

    private var nameValidationMessage: String? {
        guard let name = viewModel.draft?.name, !name.isEmpty else { return nil }
        return ProjectSlashCommand.validateName(name)
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
            }
            HStack {
                Text("Sample argument")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("(empty)", text: $sampleArgument)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                Text(viewModel.previewExpansion(forArgument: sampleArgument))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
            Text("This is the prompt Hermes will receive. The user sees the literal `/\(viewModel.draft?.name ?? "name")` they typed in their own bubble; the expanded body goes to the agent with a `<!-- scarf-slash:<name> -->` marker.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }
}
