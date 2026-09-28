import SwiftUI
import ScarfCore
import ScarfDesign

/// One-time sheet shown the first time a user sends `/goal …` when
/// Scarf's chats have no kanban tools. On 0.21.5+ (`.offerEnable`) the
/// fix is adding `kanban` to `platform_toolsets.acp`; below that
/// (`.unavailableInChat`) no config can give ACP chats kanban tools, so the
/// sheet says so and offers no Enable button. Surfaces the
/// otherwise-invisible upstream constraint that goals and kanban are
/// two separate Hermes mechanisms — without the toolset enabled, the
/// agent can't decompose a goal into kanban tasks even if it wanted
/// to.
///
/// The sheet doesn't block the prompt itself — it is raised from the
/// `default:` arm of `ChatViewModel.sendPrompt`'s slash switch, after the
/// text has gone to Hermes as an ordinary prompt (P55: `/goal` is not an
/// ACP command at any tag, so there is no goal state to gate). The sheet
/// exists to teach + offer one-click enablement.
struct ChatKanbanOnboardingSheet: View {
    let prompt: KanbanChatToolsetPrompt
    let onEnable: () async -> Void
    let onOpenTools: () -> Void
    let onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isEnabling = false
    @State private var enableError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body_
            Divider()
            footer
        }
        .frame(width: 460)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            Image(systemName: "rectangle.split.3x1.fill")
                .font(.title2)
                .foregroundStyle(ScarfColor.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Watch your goal on the Kanban board")
                    .scarfStyle(.headline)
                Text(prompt == .unavailableInChat
                     ? LocalizedStringKey("Chat kanban tools need a newer Hermes")
                     : LocalizedStringKey("Enable kanban tools to let the agent track progress as a live board"))
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(ScarfSpace.s4)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            switch prompt {
            case .offerEnable(let platform):
                Text("Goals and Kanban are two separate mechanisms in Hermes. Goals lock the agent onto a target across turns inside a single chat. Kanban gives the agent a shared task board it can fan work out onto — but only when the chat platform's toolset includes `kanban`.")
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Right now your config has the kanban toolset disabled for chat. The agent in this chat has zero kanban tools, so it can't create tasks for you to watch.")
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Enabling adds `kanban` to `platform_toolsets.\(platform)` in config.yaml. Existing chats keep their tools until you start a new one.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailableInChat:
                Text("Goals and Kanban are two separate mechanisms in Hermes. Goals lock the agent onto a target across turns inside a single chat; Kanban is a shared task board.")
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Kanban tools in Scarf's rich chat need Hermes 0.21.5 or later. On this Hermes version, rich chat sessions never get kanban tools, whatever the config says. The Kanban board itself works as usual.")
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let enableError {
                Label(enableError, systemImage: "exclamationmark.triangle")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, ScarfSpace.s3)
    }

    @ViewBuilder
    private var footer: some View {
        if prompt == .unavailableInChat {
            // Nothing to enable on this Hermes: one acknowledgement, which
            // also records the dismissal so the sheet does not come back.
            HStack {
                Spacer()
                Button("OK") {
                    onSkip()
                    dismiss()
                }
                .buttonStyle(ScarfPrimaryButton())
                .keyboardShortcut(.return)
            }
            .padding(ScarfSpace.s4)
        } else {
            enableFooter
        }
    }

    private var enableFooter: some View {
        HStack(spacing: ScarfSpace.s2) {
            Button("Skip") {
                onSkip()
                dismiss()
            }
            .buttonStyle(ScarfGhostButton())
            .disabled(isEnabling)
            Spacer()
            Button("Open Tools…") {
                onOpenTools()
                dismiss()
            }
            .buttonStyle(ScarfSecondaryButton())
            .disabled(isEnabling)
            Button {
                Task {
                    isEnabling = true
                    enableError = nil
                    await onEnable()
                    isEnabling = false
                    dismiss()
                }
            } label: {
                if isEnabling {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Text("Enable kanban tools")
                }
            }
            .buttonStyle(ScarfPrimaryButton())
            .disabled(isEnabling)
            .keyboardShortcut(.return)
        }
        .padding(ScarfSpace.s4)
    }
}
