import SwiftUI
import ScarfCore

struct ToolCallCard: View {
    let call: HermesToolCall
    let result: HermesMessage?

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(toolColor)
                        .frame(width: 3, height: 16)

                    Image(systemName: call.toolKind.icon)
                        .font(.caption)
                        .foregroundStyle(toolColor)

                    Text(call.functionName)
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(.primary)

                    Text(call.argumentsSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if result != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !call.arguments.isEmpty && call.arguments != "{}" {
                        Text("Arguments")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                        Text(formatJSON(call.arguments))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    if let result, !result.content.isEmpty {
                        Text("Result")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                        ToolResultContent(content: result.content)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var toolColor: Color {
        switch call.toolKind {
        case .read: return .green
        case .edit: return .blue
        case .execute: return .orange
        case .fetch: return .purple
        case .browser: return .indigo
        case .other: return .secondary
        }
    }

    private func formatJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return str
    }
}

struct ToolResultContent: View {
    let content: String

    @State private var showAll = false

    private var lines: [String] { content.components(separatedBy: "\n") }
    private var isLong: Bool { lines.count > 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showAll ? content : lines.prefix(8).joined(separator: "\n"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            if isLong {
                Button(showAll ? "Show less" : "Show all \(lines.count) lines") {
                    withAnimation { showAll.toggle() }
                }
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}
