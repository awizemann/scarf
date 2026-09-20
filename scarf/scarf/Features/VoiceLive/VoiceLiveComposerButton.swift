import SwiftUI
import ScarfCore
import ScarfDesign

/// What the composer needs to show the voice button. Built by the chat pane
/// only when `VoiceLiveReadiness.availability` names an engine — one button
/// for both, since the verdict decides what it mounts (P7b).
struct VoiceLiveComposerEntry {
    /// Which engine a start would mount. Only the wording differs: chained
    /// costs nothing and keeps the audio on this Mac, GPT-Live bills the
    /// host's OpenAI key per minute.
    let engineKind: VoiceEngineKind
    /// A session is running (the button ends it).
    let isActive: Bool
    /// A session can start: the chat has a live ACP session to hand turns to.
    let canStart: Bool
    /// Another window holds the app's one Live Voice session.
    var blockedByAnotherWindow = false
    let onToggle: () -> Void
}

/// The composer's Live Voice button, next to Send.
struct VoiceLiveComposerButton: View {
    let entry: VoiceLiveComposerEntry

    private var enabled: Bool { entry.isActive || (entry.canStart && !entry.blockedByAnotherWindow) }

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
        .accessibilityLabel(entry.isActive ? Text("End voice session") : Text("Start voice session"))
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("chat.composer.voiceLive")
    }

    private var accessibilityHint: Text {
        if entry.isActive { return Text(verbatim: "") }
        if entry.blockedByAnotherWindow { return Text("A voice session is running in another Scarf window. End it there first.") }
        switch entry.engineKind {
        case .gptLive:
            return Text("Talk with Hermes. GPT-Live bills about $0.05 per minute to the OpenAI key on the Hermes host.")
        case .chained:
            return Text("Talk with Hermes. Your voice is transcribed on this Mac and the reply is read aloud. Free.")
        }
    }

    private var helpText: Text {
        if entry.isActive { return Text("End voice session (⌘.)") }
        if entry.blockedByAnotherWindow { return Text("A voice session is running in another Scarf window. End it there first.") }
        guard entry.canStart else { return Text("Open a chat session to talk with Hermes.") }
        switch entry.engineKind {
        case .gptLive: return Text("Start Live Voice: talk with Hermes (about $0.05 per minute)")
        case .chained: return Text("Start talking with Hermes (free; your voice stays on this Mac)")
        }
    }
}
