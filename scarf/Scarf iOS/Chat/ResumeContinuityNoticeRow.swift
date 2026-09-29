import SwiftUI
import ScarfDesign

/// ScarfGo's persistent transcript notice for a resume that continued as a
/// new session (#146, `SessionResume.notice`) — the Mac's
/// `ResumeContinuityNoticeRow` in iOS spacing. Not dismissible: it stays
/// while the chat is on that session, so the replayed history above it
/// never passes for context the model still has.
struct ResumeContinuityNoticeRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(ScarfColor.foregroundMuted)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScarfColor.backgroundSecondary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}
