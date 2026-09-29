import SwiftUI
import ScarfDesign

/// The persistent transcript notice for a resume that continued as a new
/// session (#146, `SessionResume.notice`). Deliberately not dismissible: it
/// stays for as long as the chat is on that session, so the replayed
/// history above it never passes for context the model still has.
struct ResumeContinuityNoticeRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(ScarfColor.foregroundMuted)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScarfColor.backgroundSecondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ScarfColor.border))
        // `.combine` alone surfaced an element with an EMPTY label (the
        // selectable Text doesn't fold in), so VoiceOver and UI tests
        // read nothing; name it explicitly.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityIdentifier("chat.resumeContinuityNotice")
    }
}
