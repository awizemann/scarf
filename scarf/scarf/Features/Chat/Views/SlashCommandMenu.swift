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
    /// Names that render greyed-out + ignore taps. v2.8 uses this only
    /// for `/steer` on pre-v0.13 idle sessions; v0.13 hosts allow steer
    /// on idle and the set is empty.
    var disabledCommandNames: Set<String> = []
    /// Tooltip shown on disabled rows. Reused per-row in v2.8 — only
    /// one disabled case ships, so a single shared string is enough.
    var disabledReason: String? = nil
    @Binding var selectedIndex: Int
    var onSelect: (HermesSlashCommand) -> Void

    /// Case-insensitive prefix match on the command name. Thin forwarder
    /// to the shared `RichChatViewModel.filterSlashCommands` so the Mac
    /// and iOS chat surfaces apply identical filtering.
    static func filter(commands: [HermesSlashCommand], query: String) -> [HermesSlashCommand] {
        RichChatViewModel.filterSlashCommands(commands, query: query)
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
                            let isDisabled = disabledCommandNames.contains(command.name)
                            SlashCommandRow(
                                command: command,
                                isSelected: index == selectedIndex,
                                isDisabled: isDisabled,
                                disabledReason: isDisabled ? disabledReason : nil
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !isDisabled else { return }
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
    var isDisabled: Bool = false
    var disabledReason: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("/\(command.name)")
                        .font(ScarfFont.mono)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSelected ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
                    if let hint = command.argumentHint {
                        // v0.13: Hermes may emit hints already wrapped in
                        // brackets (e.g. `[name]` for the optional `/new
                        // <name>` argument exposed by `hasNewWithSessionName`).
                        // Avoid double-wrapping — bracketed hints pass through
                        // verbatim while older `guidance`-style hints (no
                        // brackets) still render as `<guidance>`.
                        let display = hint.hasPrefix("<") || hint.hasPrefix("[")
                            ? hint
                            : "<\(hint)>"
                        Text(display)
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                    }
                }
                if !command.description.isEmpty {
                    Text(command.description)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(2)
                }
                if isDisabled, let reason = disabledReason {
                    Text(reason)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
        .background(isSelected ? ScarfColor.accentTint : Color.clear)
        .opacity(isDisabled ? 0.55 : 1.0)
        .help(isDisabled ? (disabledReason ?? "") : "")
    }
}
