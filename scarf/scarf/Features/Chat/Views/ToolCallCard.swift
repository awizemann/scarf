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
    /// Number of identical consecutive calls this card stands for
    /// (ActivityBubble collapse). 1 = today's single-call rendering;
    /// > 1 shows a "×N" badge next to the function name.
    var repeatCount: Int = 1
    /// True when this card belongs to a settled (not in-flight) turn.
    /// A settled call with no loaded result/exit telemetry renders a
    /// muted done glyph — NEVER a spinner: `loadHistoricalToolResults`
    /// defaults false, so historical results are routinely absent and
    /// absence of data must not read as "running" (Alan, 2026-09-03).
    var isSettled: Bool = false

    @State private var expanded = false
    /// Pretty-printed `call.arguments`. Computed once per `call.callId`
    /// via `.task(id:)` instead of on every card re-render (issue #46).
    /// Seeded with the raw arguments so the first frame after expand
    /// shows readable text instead of a flicker of empty space while
    /// the task runs.
    @State private var formattedArgs: String = ""

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
                    if repeatCount > 1 {
                        Text(verbatim: "×\(repeatCount)")
                            .font(ScarfFont.monoSmall)
                            .fontWeight(.semibold)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    Text(call.argumentsSummary)
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    switch runState {
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(ScarfColor.success)
                    case .failure:
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(ScarfColor.danger)
                    case .settledUnknown:
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(ScarfColor.foregroundFaint)
                    case .running:
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
            // The header button merges to "READ, read_file, path/to/x" and
            // then stops: the completion checkmark / spinner and the
            // disclosure chevron are glyphs with no spoken form.
            .accessibilityLabel(
                repeatCount > 1
                    ? Text("Tool call \(call.functionName), repeated \(repeatCount) times, \(call.argumentsSummary)")
                    : Text("Tool call \(call.functionName), \(call.argumentsSummary)")
            )
            .accessibilityValue(
                runState == .running
                    ? Text(expanded ? "Running, expanded" : "Running, collapsed")
                    : Text(expanded ? "Finished, expanded" : "Finished, collapsed")
            )
            .accessibilityAddTraits(isFocused ? [.isSelected] : [])

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !call.arguments.isEmpty && call.arguments != "{}" {
                        Text("ARGUMENTS")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Text(formattedArgs.isEmpty ? call.arguments : formattedArgs)
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
        // Keyed on arguments length too: the P3 backfill can replace a
        // "{}" placeholder with real arguments under the SAME callId,
        // and a callId-only key would leave the expanded view stale.
        .task(id: "\(call.callId)#\(call.arguments.utf8.count)") {
            formattedArgs = formatJSON(call.arguments)
        }
    }

    private var runState: ToolCallRunState {
        ToolCallRunState.state(
            hasResult: result != nil,
            exitCode: call.exitCode,
            isSettled: isSettled
        )
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
    /// Cached line split. The previous computed-property pair
    /// (`lines` + `isLong`) split `content` twice on every render —
    /// once for the count check, once for the prefix join. With long
    /// tool outputs (file contents, command output) this was O(n)
    /// per render, repeated for every settled card on every chunk
    /// (issue #46). Now split once per content change via `.task(id:)`.
    @State private var lines: [String] = []
    @State private var preview: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showAll ? content : preview)
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

            if lines.count > 8 {
                Button(showAll ? "Show less" : "Show all \(lines.count) lines") {
                    withAnimation { showAll.toggle() }
                }
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.accent)
                .buttonStyle(.plain)
            }
        }
        .task(id: content) {
            let split = content.components(separatedBy: "\n")
            lines = split
            preview = split.prefix(8).joined(separator: "\n")
        }
    }
}
