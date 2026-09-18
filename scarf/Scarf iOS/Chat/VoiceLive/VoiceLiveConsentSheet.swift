import SwiftUI
import ScarfCore
import ScarfDesign

/// The one-time consent before the first Live Voice session on this device
/// (F4, t-ba3ccc85), also shown read-only from Settings. The Mac twin is
/// `VoiceLiveConsentSheet` in `scarf/Features/VoiceLive/`.
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                    Image(systemName: "waveform.circle")
                        .font(.largeTitle)
                        .foregroundStyle(ScarfColor.accent)
                        .accessibilityHidden(true)
                    Text("Live Voice sends your voice to \(recipient.displayName)")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                            Label {
                                point
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                            }
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("ScarfGo asks once on this device. You can review or reset this in Settings.")
                        .font(.footnote)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScarfSpace.s5)
            }
            .safeAreaInset(edge: .bottom) {
                if case .ask(let onContinue, _) = mode {
                    Button {
                        onContinue()
                        dismiss()
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ScarfPrimaryButton())
                    .accessibilityHint("Starts Live Voice.")
                    .padding(ScarfSpace.s4)
                    .background(.bar)
                }
            }
            .toolbar {
                switch mode {
                case .ask(_, let onCancel):
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            onCancel()
                            dismiss()
                        }
                    }
                case .review:
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .accessibilityIdentifier("voiceLive.consent")
    }

    /// One plain sentence per fact the user agrees to.
    private var points: [Text] {
        guard recipient == .openAI else {
            return [
                Text("Your voice streams from this device to \(recipient.displayName), which also sees this device's network address."),
                Text("Recent messages from this chat are shared with \(recipient.displayName) for context."),
            ]
        }
        return [
            Text("Your voice streams directly from this device to OpenAI. The Hermes host only sets up the session, so OpenAI also sees this device's network address."),
            Text("Each session shares recent messages from this chat with OpenAI for context: up to 24 messages, about 6,000 characters."),
            Text("OpenAI bills the OpenAI key on the Hermes host about $0.05 per minute while a session is open."),
            Text("GPT-Live mode is a Hermes setting for the whole profile. It also changes voice in Hermes's own apps."),
        ]
    }
}
