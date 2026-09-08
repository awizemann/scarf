import SwiftUI
import ScarfDesign

/// The app's one **outcome-typed** message bar (GW-F4, AX H3/H4).
///
/// Before this existed, twenty-one surfaces each open-coded the same
/// stanza — `Label(msg, systemImage: "checkmark.circle.fill")` in green —
/// over a channel that carries BOTH "Saved — restart gateway to apply" and
/// "Failed to write .env". Every guarded-write refusal the GW-E arc added
/// therefore rendered as a green checkmark: a success badge over a save
/// that did not happen. That misleads sighted users as much as VoiceOver
/// ones, which is why the fix is a colour/glyph change and not only an
/// accessibility annotation.
///
/// The rules, taken from `BotRoutinesView`'s in-repo model implementation:
/// - **Colour and glyph come from the view model's typed outcome, never
///   from the string.** A channel that decides "did this fail?" by
///   comparing the message text is one copy-edit away from lying again.
/// - **A failure never auto-clears.** Success toasts fade after three
///   seconds; a refusal stays until the user acts on it (the owning view
///   model simply skips its clear timer — see
///   ``OutcomeMessageHosting/applySaveOutcome(_:)``).
/// - **The transition is announced.** A toast appearing in a corner is
///   invisible to VoiceOver, so the bar posts an announcement when the
///   text changes, guarded by the last-announced value so an `@Observable`
///   republish of the same message doesn't repeat itself
///   (`RegistryDamageBanner`'s house pattern).
/// - **The glyph is hidden and the pair combined into one stop**, with an
///   explicit label naming the outcome first — `BotAgentView.failure`'s
///   triad. The dismiss button stays OUTSIDE the combined group so it
///   remains reachable.
struct OutcomeMessageBar: View {
    /// The message to show. `nil` renders nothing, so call sites drop
    /// their own `if let`.
    let text: String?
    /// Whether `text` describes a FAILURE. Supplied by the view model as a
    /// stored outcome, never inferred here.
    let isFailure: Bool
    /// Optional dismiss action. Rendered only for a failure — a success
    /// message clears itself.
    var onDismiss: (() -> Void)?

    /// Guards against re-announcing an unchanged message when the owning
    /// `@Observable` republishes (a re-save producing the same text, a
    /// parent body pass).
    @State private var lastAnnounced: String?

    var body: some View {
        if let text, !text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                    Image(systemName: isFailure
                          ? "exclamationmark.triangle.fill"
                          : "checkmark.circle.fill")
                        // Redundant with the outcome word in the label below.
                        .accessibilityHidden(true)
                    Text(text)
                        .scarfStyle(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .foregroundStyle(isFailure ? ScarfColor.danger : ScarfColor.success)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spoken(text))
                if isFailure, let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .accessibilityLabel(String(localized: "Dismiss this failure message"))
                }
            }
            .onChange(of: text) { _, new in announce(new) }
            .onAppear { announce(text) }
        }
    }

    /// Outcome word first, then the message — a VoiceOver user hitting this
    /// element mid-sentence should learn whether it worked before they
    /// learn the detail.
    ///
    /// Composed from `String(localized:)` fragments with the message
    /// interpolated: passing a bare `String` variable to
    /// `.accessibilityLabel` binds the `StringProtocol` overload, which is
    /// never extracted for translation.
    private func spoken(_ text: String) -> String {
        isFailure
            ? String(localized: "Failed: \(text)")
            : String(localized: "Succeeded: \(text)")
    }

    private func announce(_ text: String) {
        guard lastAnnounced != text else { return }
        lastAnnounced = text
        AccessibilityNotification.Announcement(AttributedString(spoken(text))).post()
    }
}
