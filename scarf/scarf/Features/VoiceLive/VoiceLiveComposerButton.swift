import SwiftUI
import ScarfCore
import ScarfDesign

/// What the composer needs to show the Live Voice button. Built by the chat
/// pane only when `VoiceLiveReadiness.availability` is `.ready`.
struct VoiceLiveComposerEntry {
    /// A session is running (the button ends it).
    let isActive: Bool
    /// A session can start: the chat has a live ACP session to hand turns to.
    let canStart: Bool
    let onToggle: () -> Void
}

/// The composer's Live Voice button, next to Send.
struct VoiceLiveComposerButton: View {
    let entry: VoiceLiveComposerEntry

    private var enabled: Bool { entry.isActive || entry.canStart }

    var body: some View {
        Button(action: entry.onToggle) {
            Image(systemName: entry.isActive ? "waveform.circle.fill" : "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    entry.isActive ? ScarfColor.onAccent
                        : (enabled ? ScarfColor.foregroundMuted : ScarfColor.foregroundFaint)
                )
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .fill(entry.isActive ? ScarfColor.accent : ScarfColor.backgroundTertiary)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(helpText)
        .accessibilityLabel(entry.isActive ? Text("End Live Voice") : Text("Start Live Voice"))
        .accessibilityHint(entry.isActive ? Text(verbatim: "") : Text("Talk with Hermes. GPT-Live bills about $0.05 per minute to the OpenAI key on the Hermes host."))
        .accessibilityIdentifier("chat.composer.voiceLive")
    }

    private var helpText: Text {
        if entry.isActive { return Text("End Live Voice (⌘.)") }
        if entry.canStart { return Text("Start Live Voice: talk with Hermes (about $0.05 per minute)") }
        return Text("Open a chat session to talk with Hermes.")
    }
}
