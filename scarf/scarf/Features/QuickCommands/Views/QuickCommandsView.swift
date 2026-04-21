import SwiftUI

struct QuickCommandsView: View {
    @State private var viewModel: QuickCommandsViewModel
    @State private var showAddSheet = false
    @State private var editTarget: HermesQuickCommand?

    init(context: ServerContext) {
        _viewModel = State(initialValue: QuickCommandsViewModel(context: context))
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                intro
                if viewModel.commands.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Quick Commands")
        .onAppear { viewModel.load() }
        .sheet(isPresented: $showAddSheet) {
            QuickCommandEditor(initial: nil) { name, cmd in
                viewModel.addOrUpdate(name: name, command: cmd)
                showAddSheet = false
            } onCancel: {
                showAddSheet = false
            }
        }
        .sheet(item: $editTarget) { target in
            QuickCommandEditor(initial: target) { name, cmd in
                viewModel.addOrUpdate(name: name, command: cmd)
                editTarget = nil
            } onCancel: {
                editTarget = nil
            }
        }
    }

    private var header: some View {
        HStack {
            if let msg = viewModel.message {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button {
                showAddSheet = true
            } label: {
                Label("Add Command", systemImage: "plus")
            }
            .controlSize(.small)
            Button("Reload") { viewModel.load() }
                .controlSize(.small)
        }
    }

    private var intro: some View {
        Text("Quick commands are shell shortcuts hermes exposes in chat as `/command_name`. They live under `quick_commands:` in config.yaml.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "command.square")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No quick commands configured")
                .foregroundStyle(.secondary)
            Button("Add your first command") { showAddSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var list: some View {
        VStack(spacing: 1) {
            ForEach(viewModel.commands) { cmd in
                HStack(spacing: 12) {
                    Image(systemName: "command.square")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("/\(cmd.name)")
                                .font(.system(.body, design: .monospaced, weight: .medium))
                            if QuickCommandsViewModel.isDangerous(cmd.command) {
                                Label("dangerous", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.red)
                            }
                        }
                        Text(cmd.command)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                    Spacer()
                    Button("Edit") { editTarget = cmd }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.3))
            }
            HStack {
                Spacer()
                Button("Remove via config.yaml…") { viewModel.openConfigForRemoval() }
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }
}

/// Inline editor for add/update. Removal requires hand-editing config.yaml because
/// `hermes config set` has no unset primitive for nested keys.
private struct QuickCommandEditor: View {
    let initial: HermesQuickCommand?
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var command: String

    init(initial: HermesQuickCommand?, onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initial?.name ?? "")
        _command = State(initialValue: initial?.command ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (initial == nil ? Text("Add Quick Command") : Text("Edit /\(initial!.name)"))
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Name (no leading slash)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. deploy", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(initial != nil)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Shell Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $command)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 100)
                    .padding(4)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if QuickCommandsViewModel.isDangerous(command) {
                Label("Command looks destructive. Double-check before saving.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { onSave(name, command) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 320)
    }
}
