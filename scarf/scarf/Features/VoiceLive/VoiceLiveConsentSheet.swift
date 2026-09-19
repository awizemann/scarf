import SwiftUI
import ScarfCore
import ScarfDesign

/// What the Live Voice consent says, per recipient (F4, t-ba3ccc85). Pure
/// so the wording is unit-tested. ScarfGo's twin is
/// `VoiceLiveConsentSheet` in `Scarf iOS/Chat/VoiceLive/`.
enum VoiceLiveConsentCopy {

    static func title(_ recipient: VoiceDataRecipient) -> String {
        String(localized: "Live Voice sends your voice to \(recipient.displayName)")
    }

    /// One plain sentence per fact the user agrees to.
    static func points(_ recipient: VoiceDataRecipient) -> [String] {
        guard recipient == .openAI else {
            // A future engine's recipient: the general facts, until it
            // gets its own wording.
            return [
                String(localized: "Your voice streams from this Mac to \(recipient.displayName). \(recipient.displayName) also sees this Mac's network address."),
                String(localized: "Recent messages from this chat are shared with \(recipient.displayName) for context."),
            ]
        }
        return [
            String(localized: "Your voice streams directly from this Mac to OpenAI. The Hermes host only sets up the session, so OpenAI also sees this Mac's network address."),
            String(localized: "Each session shares recent messages from this chat with OpenAI for context: up to 24 messages, about 6,000 characters."),
            String(localized: "OpenAI bills the OpenAI key on the Hermes host about $0.05 per minute while a session is open."),
            String(localized: "GPT-Live mode is a Hermes setting for the whole profile. It also changes voice in Hermes's own apps."),
        ]
    }

    static var footnote: String {
        String(localized: "Scarf asks once on this Mac. You can review or reset this in Settings › Voice.")
    }
}

/// The one-time consent before the first Live Voice session on this Mac,
/// also shown read-only from Settings › Voice.
struct VoiceLiveConsentSheet: View {
    enum Mode {
        /// Before the first session: Cancel or Continue.
        case ask(onContinue: () -> Void, onCancel: () -> Void)
        /// From Settings: Done only.
        case review
    }

    let recipient: VoiceDataRecipient
    let mode: Mode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Label {
                Text(verbatim: VoiceLiveConsentCopy.title(recipient))
            } icon: {
                Image(systemName: "waveform.circle")
            }
            .scarfStyle(.headline)
            .foregroundStyle(ScarfColor.foregroundPrimary)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                ForEach(VoiceLiveConsentCopy.points(recipient), id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                        Text(verbatim: "•")
                            .accessibilityHidden(true)
                        Text(verbatim: point)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                }
            }

            Text(verbatim: VoiceLiveConsentCopy.footnote)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                switch mode {
                case .ask(let onContinue, let onCancel):
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .buttonStyle(ScarfGhostButton())
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Continue") {
                        onContinue()
                        dismiss()
                    }
                    .buttonStyle(ScarfPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(Text("Starts Live Voice."))
                case .review:
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(ScarfPrimaryButton())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 460)
        .accessibilityIdentifier("voiceLive.consent")
    }
}
