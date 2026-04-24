import SwiftUI
import ScarfCore

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

    var body: some View {
        HStack(spacing: 16) {
            if let session {
                // Project indicator first — visually anchors the session
                // as "scoped to project X" before the working dot and
                // title. Hidden for non-project chats so the bar looks
                // identical to v2.2.1 behavior.
                if let projectName {
                    Label(projectName, systemImage: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .help("Chat is scoped to Scarf project \"\(projectName)\"")
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(isWorking ? .green : .secondary)
                        .frame(width: 6, height: 6)
                        .opacity(isWorking ? 1 : 0.6)
                    if isWorking {
                        Text("Working")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                if let title = session.title, !title.isEmpty {
                    Text(title)
                        .font(.caption.bold())
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
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func formatTokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
