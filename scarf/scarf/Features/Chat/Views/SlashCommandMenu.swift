import SwiftUI

/// Floating menu of available slash commands shown above the chat input when
/// the user types `/` as the first character. Read-only list — the parent
/// owns selection state and insertion.
struct SlashCommandMenu: View {
    let commands: [HermesSlashCommand]
    let query: String
    @Binding var selectedIndex: Int
    var onSelect: (HermesSlashCommand) -> Void

    var filtered: [HermesSlashCommand] {
        Self.filter(commands: commands, query: query)
    }

    static func filter(commands: [HermesSlashCommand], query: String) -> [HermesSlashCommand] {
        let q = query.lowercased()
        if q.isEmpty { return commands }
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(q) }
        if !prefix.isEmpty { return prefix }
        return commands.filter { $0.description.lowercased().contains(q) }
    }

    var body: some View {
        let items = filtered
        if commands.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No commands available")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("The agent hasn't advertised any slash commands yet. Keep typing to send as a message, or press Esc.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(minWidth: 360, alignment: .leading)
        } else if items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No matching commands")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Keep typing to send as a message, or press Esc.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(minWidth: 360, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, command in
                            SlashCommandRow(
                                command: command,
                                isSelected: index == selectedIndex
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                onSelect(command)
                            }
                        }
                    }
                }
                .frame(minWidth: 360, maxHeight: 260)
                .onChange(of: selectedIndex) { _, newValue in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct SlashCommandRow: View {
    let command: HermesSlashCommand
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("/\(command.name)")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                    if let hint = command.argumentHint {
                        Text("<\(hint)>")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if command.source == .quickCommand {
                        Text("user")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.8))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}
