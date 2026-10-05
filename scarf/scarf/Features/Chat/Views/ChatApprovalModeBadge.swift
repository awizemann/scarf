import SwiftUI
import ScarfCore
import ScarfDesign

/// Compact pill in `SessionInfoBar` showing the live ACP session's edit
/// auto-approval mode (Hermes v0.15+). Tap opens a menu listing the three
/// modes — picking one fires `onSwitch(mode)` (which the chat view model
/// wires to ACP's `session/set_mode` RPC).
///
/// This is the per-session toggle, distinct from the global
/// `approvals.mode` config / YOLO chip. Capability-gated by the bar
/// (`hasSessionEditAutoApproval`) so this view never renders on hosts
/// that can't actually switch.
struct ChatApprovalModeBadge: View {
    let mode: ACPApprovalMode
    let onSwitch: (ACPApprovalMode) -> Void

    var body: some View {
        Menu {
            ForEach(ACPApprovalMode.allCases, id: \.self) { candidate in
                Button {
                    onSwitch(candidate)
                } label: {
                    if candidate == mode {
                        Label(candidate.displayName, systemImage: "checkmark")
                    } else {
                        Text(candidate.displayName)
                    }
                    Text(candidate.summary)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(mode.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .opacity(0.6)
            }
            .scarfStyle(.caption)
            .padding(.horizontal, ScarfSpace.s2)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.tinted(0.12)))
            .foregroundStyle(tone.text)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Edit approval mode: \(mode.summary). Sensitive paths always prompt.")
    }

    private var icon: String {
        switch mode {
        case .default: return "hand.raised"
        case .acceptEdits: return "checkmark.shield"
        case .dontAsk: return "bolt.shield"
        }
    }

    /// Default mode stays neutral/info; the looser modes warn so the user
    /// can see at a glance they've opted into auto-approving edits.
    private var tone: ScarfBadgeKind {
        switch mode {
        case .default: return .info
        case .acceptEdits, .dontAsk: return .warning
        }
    }
}
