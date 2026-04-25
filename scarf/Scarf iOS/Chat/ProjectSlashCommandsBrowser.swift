import SwiftUI
import ScarfCore

/// Read-only sheet that lists every project-scoped slash command
/// available in the current project chat. Surfaced from the chat
/// project-context bar via the `slash.circle.fill` chip when the
/// project has at least one command.
///
/// **Read-only on purpose.** Authoring multi-line markdown bodies on
/// an iPhone keyboard is its own UX problem — Mac is the canonical
/// editor in v2.5. iOS users browse, tap-to-insert into the composer
/// (returning to the chat view), and let the slash menu drive
/// invocation from there.
struct ProjectSlashCommandsBrowser: View {
    let projectName: String
    let commands: [ProjectSlashCommand]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCommand: ProjectSlashCommand?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(commands) { cmd in
                        Button {
                            selectedCommand = cmd
                        } label: {
                            CommandRow(command: cmd)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Edit these in Scarf on macOS — they live at `<project>/.scarf/slash-commands/<name>.md` and ship with `.scarftemplate` bundles.")
                        .font(.caption)
                }
            }
            .navigationTitle(projectName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedCommand) { cmd in
                CommandDetailSheet(command: cmd)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct CommandRow: View {
    let command: ProjectSlashCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("/\(command.name)")
                    .font(.body.monospaced().weight(.medium))
                    .foregroundStyle(.tint)
                if let hint = command.argumentHint, !hint.isEmpty {
                    Text(hint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(command.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Detail view for a single command — shows the prompt template body
/// so users can preview what Hermes will receive.
private struct CommandDetailSheet: View {
    let command: ProjectSlashCommand

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("/\(command.name)")
                            .font(.title2.monospaced().weight(.medium))
                            .foregroundStyle(.tint)
                        Text(command.description)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }

                    if let hint = command.argumentHint, !hint.isEmpty {
                        metadataRow(label: "Argument hint", value: hint, mono: true)
                    }
                    if let model = command.model, !model.isEmpty {
                        metadataRow(label: "Model override", value: model, mono: true)
                    }
                    if let tags = command.tags, !tags.isEmpty {
                        metadataRow(label: "Tags", value: tags.joined(separator: ", "), mono: false)
                    }

                    Divider()

                    Text("Prompt template")
                        .font(.headline)
                    Text(command.body)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                    Text("`{{argument}}` is replaced with whatever you type after `/\(command.name)`. The agent receives the expanded body — never the literal slash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }
            .navigationTitle("/\(command.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func metadataRow(label: String, value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
        }
    }
}
