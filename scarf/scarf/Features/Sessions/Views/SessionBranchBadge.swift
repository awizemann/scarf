import SwiftUI
import ScarfCore
import ScarfDesign

/// Small "Branch" capsule for a session created by Hermes's `/branch`
/// (GitHub #145). Rendered only when `HermesSession.isBranch`, which is
/// false on hosts without lineage data — those rows render exactly as
/// before.
///
/// Deliberately a TEXT capsule, not `arrow.triangle.branch`: that glyph
/// already means "Subagent" in `SessionDetailView`, and a branch is a
/// user-facing fork of the conversation, not a delegated run.
struct SessionBranchBadge: View {
    let session: HermesSession

    var body: some View {
        Text("Branch", comment: "Badge on a session created with /branch from another session.")
            .font(ScarfFont.caption2)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(ScarfColor.border, lineWidth: 1))
            .fixedSize()
            .help(Text(verbatim: Self.description(for: session)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Self.description(for: session)))
            .accessibilityIdentifier("session.branchBadge")
    }

    /// "Branch of “Parent”" when the parent's title is known, else a
    /// generic phrase. Used for the tooltip, the badge's accessibility
    /// label and the Sessions row's composed accessibility label.
    static func description(for session: HermesSession) -> String {
        if let parent = session.branchParentTitle, !parent.isEmpty {
            return String(localized: "Branch of “\(parent)”",
                          comment: "Tooltip/VoiceOver for a branched session; the argument is the parent session's title.")
        }
        return String(localized: "Branch of another session",
                      comment: "Tooltip/VoiceOver for a branched session whose parent has no title.")
    }
}
