import SwiftUI
import ScarfCore
import ScarfDesign

/// Floating menu of available slash commands shown above the chat input when
/// the user types `/` as the first character. Purely presentational — the
/// parent filters the list and owns selection state.
struct SlashCommandMenu: View {
    /// Pre-filtered commands to display.
    let commands: [HermesSlashCommand]
    /// Whether the agent advertised any commands at all. Lets us distinguish
    /// "agent hasn't sent commands yet" from "filter matched nothing".
    let agentHasCommands: Bool
    @Binding var selectedIndex: Int
    var onSelect: (HermesSlashCommand) -> Void

    /// Case-insensitive prefix match on the command name. Exposed as a static
    /// helper so the parent can share filter logic with its key handlers.
    static func filter(commands: [HermesSlashCommand], query: String) -> [HermesSlashCommand] {
        let q = query.lowercased()
        if q.isEmpty { return commands }
        return commands.filter { $0.name.lowercased().hasPrefix(q) }
    }

    var body: some View {
        if !agentHasCommands {
            VStack(alignment: .leading, spacing: 4) {
                Text("No commands available")
                    .scarfStyle(.callout)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Text("The agent hasn't advertised any slash commands yet. Keep typing to send as a message, or press Esc.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            .padding(ScarfSpace.s3)
            .frame(minWidth: 360, alignment: .leading)
        } else if commands.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No matching commands")
                    .scarfStyle(.callout)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Text("Keep typing to send as a message, or press Esc.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            .padding(ScarfSpace.s3)
            .frame(minWidth: 360, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
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
                        .font(ScarfFont.mono)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSelected ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
                    if let hint = command.argumentHint {
                        Text("<\(hint)>")
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                    }
                    if command.source == .quickCommand {
                        Text("user")
                            .font(ScarfFont.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(ScarfColor.backgroundTertiary)
                            .clipShape(Capsule())
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                }
                if !command.description.isEmpty {
                    Text(command.description)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
        .background(isSelected ? ScarfColor.accentTint : Color.clear)
    }
}
