import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS slash command autocomplete that surfaces above the composer when
/// the user types `/`. Mirrors the Mac `SlashCommandMenu` data shape,
/// but is tap-driven (no arrow-key navigation) since iOS composers
/// don't have a consistent hardware-keyboard story. Pure presentational
/// — the parent filters the list and handles selection.
///
/// Behavioral parity with Mac: same command set (via shared
/// `RichChatViewModel.availableCommands`), same prefix filtering (via
/// `RichChatViewModel.filterSlashCommands`), same disabled-row gating
/// (via `RichChatViewModel.disabledSlashCommandNames`).
struct IOSSlashCommandMenu: View {
    let commands: [HermesSlashCommand]
    let agentHasCommands: Bool
    var disabledCommandNames: Set<String> = []
    var disabledReason: String? = nil
    var onSelect: (HermesSlashCommand) -> Void

    var body: some View {
        if !agentHasCommands {
            emptyStateRow(
                title: "No commands available",
                detail: "The agent hasn't advertised any slash commands yet. Keep typing to send as a message."
            )
        } else if commands.isEmpty {
            emptyStateRow(
                title: "No matching commands",
                detail: "Keep typing to send as a message."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(commands) { command in
                        let isDisabled = disabledCommandNames.contains(command.name)
                        IOSSlashCommandRow(
                            command: command,
                            isDisabled: isDisabled,
                            disabledReason: isDisabled ? disabledReason : nil
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isDisabled else { return }
                            onSelect(command)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    @ViewBuilder
    private func emptyStateRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text(detail)
                .font(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
        }
        .padding(ScarfSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IOSSlashCommandRow: View {
    let command: HermesSlashCommand
    var isDisabled: Bool = false
    var disabledReason: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("/\(command.name)")
                        .font(.headline.monospaced())
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    if let hint = command.argumentHint {
                        let display = hint.hasPrefix("<") || hint.hasPrefix("[")
                            ? hint
                            : "<\(hint)>"
                        Text(display)
                            .font(.caption.monospaced())
                            .foregroundStyle(ScarfColor.foregroundFaint)
                    }
                }
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(2)
                }
                if isDisabled, let reason = disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
        .opacity(isDisabled ? 0.55 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("/\(command.name)"))
        .accessibilityHint(Text(command.description))
    }
}
