import SwiftUI

struct SessionInfoBar: View {
    let session: HermesSession?
    let isWorking: Bool
    /// Fallback token counts from ACP prompt results (DB may have zeros for ACP sessions).
    var acpInputTokens: Int = 0
    var acpOutputTokens: Int = 0
    var acpThoughtTokens: Int = 0

    var body: some View {
        HStack(spacing: 16) {
            if let session {
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
                    Label(String(format: "$%.4f%@", cost, session.costIsActual ? "" : " est."), systemImage: "dollarsign.circle")
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
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
