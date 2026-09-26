import SwiftUI
import ScarfCore
import ScarfDesign

/// Pre-first-event waiting indicator (#145): "Working · 0:12", ticking
/// once a second from the turn's start so a slow first token reads as
/// progress, not a frozen app (the three dots it replaces never
/// animated — `.symbolEffect(.pulse)` is a no-op on plain `Circle`s).
///
/// The 1 Hz tick is confined to this view's own `TimelineView`: the
/// transcript (`RichChatMessageList`) only re-renders when `since`
/// changes, which is twice per turn (gh#140 — never drive transcript
/// invalidation from a clock). `TimelineView` also pauses while the
/// view is off-screen.
///
/// VoiceOver: one element with a static label and the elapsed time as
/// its value, so the running time is readable on demand but never
/// re-announced each second (no `.updatesFrequently` trait).
struct WorkingElapsedIndicator: View {
    /// Start of the busy period; nil renders "Working" with no clock
    /// (defensive — `workingSince` is set whenever the list is working).
    let since: Date?
    @Environment(\.chatFontScale) private var chatFontScale: Double

    var body: some View {
        HStack {
            Group {
                if let since {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        content(elapsed: context.date.timeIntervalSince(since))
                    }
                } else {
                    content(elapsed: nil)
                }
            }
            .font(ChatFontScale.caption2(chatFontScale))
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer(minLength: 80)
        }
    }

    private func content(elapsed: TimeInterval?) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            if let elapsed {
                Text("Working · \(RichChatViewModel.formatElapsedClock(elapsed))")
                    .monospacedDigit()
            } else {
                Text("Working")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Agent is working"))
        .accessibilityValue(elapsed.map(Self.spokenElapsed) ?? Text(verbatim: ""))
    }

    /// "12 seconds", "1 minute, 5 seconds" — clock digits read badly
    /// aloud ("zero colon twelve").
    private static func spokenElapsed(_ seconds: TimeInterval) -> Text {
        let whole = max(0, Int(seconds.rounded(.down)))
        return Text(Duration.seconds(whole).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide)
        ))
    }
}
