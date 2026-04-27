import SwiftUI
import ScarfCore
import ScarfDesign

struct SessionInfoBar: View {
    let session: HermesSession?
    let isWorking: Bool
    /// Fallback token counts from ACP prompt results (DB may have zeros for ACP sessions).
    var acpInputTokens: Int = 0
    var acpOutputTokens: Int = 0
    var acpThoughtTokens: Int = 0
    /// Name of the Scarf project this session is attributed to, when
    /// applicable. Nil for plain global chats. Drives the folder-chip
    /// indicator rendered before the session title. Resolved by
    /// `ChatViewModel.currentProjectName` — the view just passes it
    /// through.
    var projectName: String? = nil
    /// Current git branch of the project's working directory, when
    /// resolved (v2.5). Renders as a tinted chip after the project
    /// name. Nil for non-project chats and for projects that aren't
    /// git repos.
    var gitBranch: String? = nil

    /// Active Hermes profile name (issue #50). Resolved on each body
    /// re-evaluation; the resolver caches for 5s so this is cheap.
    /// Chip renders only when not "default" so existing (non-profile)
    /// installations see no change in the bar.
    private var activeProfile: String {
        HermesProfileResolver.activeProfileName()
    }

    var body: some View {
        HStack(spacing: 16) {
            if let session {
                // Profile chip leftmost — surfaces which Hermes profile
                // Scarf is reading (issue #50). Without this users couldn't
                // tell whether the visible session list came from the
                // profile they thought they switched to.
                if activeProfile != "default" {
                    Label(activeProfile, systemImage: "person.crop.square")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.warning)
                        .lineLimit(1)
                        .help("Scarf is reading from Hermes profile \"\(activeProfile)\". Switch profiles with `hermes profile use <name>` and relaunch Scarf.")
                }
                // Project indicator first — visually anchors the session
                // as "scoped to project X" before the working dot and
                // title. Hidden for non-project chats so the bar looks
                // identical to v2.2.1 behavior.
                if let projectName {
                    Label(projectName, systemImage: "folder.fill")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.accent)
                        .lineLimit(1)
                        .help("Chat is scoped to Scarf project \"\(projectName)\"")
                    if let gitBranch {
                        Label(gitBranch, systemImage: "arrow.triangle.branch")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.accent)
                            .lineLimit(1)
                            .help("Project's current git branch")
                    }
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(isWorking ? ScarfColor.success : ScarfColor.foregroundFaint)
                        .frame(width: 6, height: 6)
                        .opacity(isWorking ? 1 : 0.6)
                    if isWorking {
                        Text("Working")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.success)
                    }
                }

                if let title = session.title, !title.isEmpty {
                    Text(title)
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let model = session.model {
                    Label(model, systemImage: "cpu")
                }

                let inputToks = session.inputTokens > 0 ? session.inputTokens : acpInputTokens
                let outputToks = session.outputTokens > 0 ? session.outputTokens : acpOutputTokens
                Label("\(formatTokens(inputToks)) in / \(formatTokens(outputToks)) out", systemImage: "number")
                    .contentTransition(.numericText())

                let reasonToks = session.reasoningTokens > 0 ? session.reasoningTokens : acpThoughtTokens
                if reasonToks > 0 {
                    Label("\(formatTokens(reasonToks)) reasoning", systemImage: "brain")
                }

                if let cost = session.displayCostUSD {
                    let formattedCost = cost.formatted(.currency(code: "USD").precision(.fractionLength(4)))
                    Label(session.costIsActual ? formattedCost : "\(formattedCost) est.", systemImage: "dollarsign.circle")
                        .contentTransition(.numericText())
                }

                if let start = session.startedAt {
                    Label {
                        Text(start, style: .relative)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "clock")
                    }
                }

                Spacer()

                Label(session.source, systemImage: session.sourceIcon)
            } else {
                Text("No active session")
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Spacer()
            }
        }
        .scarfStyle(.caption)
        .foregroundStyle(ScarfColor.foregroundMuted)
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundSecondary)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private func formatTokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
