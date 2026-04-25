import SwiftUI
import ScarfCore
import ScarfDesign

struct ToolCallCard: View {
    let call: HermesToolCall
    let result: HermesMessage?
    /// True when this card matches `chatViewModel.focusedToolCallId`.
    /// Bumps the card's tint + border so users can see at a glance
    /// which tool the inspector pane is currently showing.
    var isFocused: Bool = false
    /// Called when the user clicks the card. Wired to set
    /// `chatViewModel.focusedToolCallId = call.callId` from
    /// `RichMessageBubble` (Mac). Inline expansion still toggles on the
    /// same click — power users get both paths from one gesture.
    var onFocus: (() -> Void)? = nil

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onFocus?()
                withAnimation(ScarfAnimation.fast) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    HStack(spacing: 5) {
                        Image(systemName: call.toolKind.icon)
                            .foregroundStyle(toolColor)
                            .font(.system(size: 11))
                        Text(toolLabel)
                            .scarfStyle(.captionStrong)
                            .tracking(0.4)
                            .foregroundStyle(toolColor)
                    }
                    Text(call.functionName)
                        .font(ScarfFont.monoSmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Text(call.argumentsSummary)
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if result != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(ScarfColor.success)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(toolColor.opacity(isFocused ? 0.16 : 0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(
                                    toolColor.opacity(isFocused ? 0.55 : 0.30),
                                    lineWidth: isFocused ? 1.4 : 1
                                )
                        )
                )
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !call.arguments.isEmpty && call.arguments != "{}" {
                        Text("ARGUMENTS")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Text(formatJSON(call.arguments))
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(ScarfColor.backgroundSecondary)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(ScarfColor.border, lineWidth: 1)
                                    )
                            )
                    }
                    if let result, !result.content.isEmpty {
                        Text("RESULT")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        ToolResultContent(content: result.content)
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    private var toolLabel: String {
        switch call.toolKind {
        case .read: return "READ"
        case .edit: return "EDIT"
        case .execute: return "EXECUTE"
        case .fetch: return "FETCH"
        case .browser: return "BROWSER"
        case .other: return "TOOL"
        }
    }

    private var toolColor: Color {
        switch call.toolKind {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
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
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(ScarfColor.backgroundSecondary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(ScarfColor.border, lineWidth: 1)
                        )
                )

            if isLong {
                Button(showAll ? "Show less" : "Show all \(lines.count) lines") {
                    withAnimation { showAll.toggle() }
                }
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.accent)
                .buttonStyle(.plain)
            }
        }
    }
}
