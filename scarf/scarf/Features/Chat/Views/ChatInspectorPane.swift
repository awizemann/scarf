import AppKit
import SwiftUI
import ScarfCore
import ScarfDesign

/// Right pane of the 3-pane chat layout — mirrors the inspector in
/// `design/static-site/ui-kit/Chat.jsx` + `ScarfChatView.swift`. Reads
/// `chatViewModel.focusedToolCall` to resolve the focus target. Closing
/// (xmark) clears `focusedToolCallId`.
struct ChatInspectorPane: View {
    @Bindable var chatViewModel: ChatViewModel

    @State private var tab: Tab = .details

    enum Tab: String, CaseIterable, Identifiable {
        case details, output, raw
        var id: String { rawValue }
        var label: String {
            switch self {
            case .details: return "Details"
            case .output:  return "Output"
            case .raw:     return "Raw"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let focus = chatViewModel.focusedToolCall {
                header(focus.call)
                ScrollView {
                    Group {
                        switch tab {
                        case .details: detailsBody(call: focus.call, result: focus.result)
                        case .output:  outputBody(result: focus.result)
                        case .raw:     rawBody(call: focus.call, result: focus.result)
                        }
                    }
                    .padding(ScarfSpace.s4)
                }
                footer(call: focus.call, result: focus.result)
            } else {
                emptyState
            }
        }
        .background(ScarfColor.backgroundSecondary)
    }

    // MARK: - Header

    private func header(_ call: HermesToolCall) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack(spacing: ScarfSpace.s2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(toolColor(call).opacity(0.16))
                    Image(systemName: call.toolKind.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(toolColor(call))
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(toolLabel(call)) CALL")
                        .scarfStyle(.captionStrong)
                        .tracking(0.5)
                        .foregroundStyle(toolColor(call))
                    Text(call.functionName)
                        .font(ScarfFont.mono)
                        .fontWeight(.semibold)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    chatViewModel.focusedToolCallId = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Close inspector")
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, ScarfSpace.s3)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Details body

    private func detailsBody(call: HermesToolCall, result: HermesMessage?) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s5) {
            statusSection(call: call, result: result)
            argumentsSection(call: call)
            telemetrySection(call: call, result: result)
            permissionsSection
        }
    }

    private func statusSection(call: HermesToolCall, result: HermesMessage?) -> some View {
        section("STATUS") {
            HStack(spacing: ScarfSpace.s2) {
                Image(systemName: statusIcon(call: call, result: result))
                    .font(.system(size: 14))
                    .foregroundStyle(statusColor(call: call, result: result))
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle(call: call, result: result))
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(statusColor(call: call, result: result))
                    Text(statusSubtitle(call: call))
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer()
            }
            .padding(ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(statusColor(call: call, result: result).opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(statusColor(call: call, result: result).opacity(0.25), lineWidth: 1)
                    )
            )
        }
    }

    private func argumentsSection(call: HermesToolCall) -> some View {
        section("ARGUMENTS") {
            Text(formatJSON(call.arguments))
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .textSelection(.enabled)
                .padding(ScarfSpace.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(ScarfColor.backgroundTertiary)
                )
        }
    }

    private func telemetrySection(call: HermesToolCall, result: HermesMessage?) -> some View {
        section("TELEMETRY") {
            VStack(spacing: 0) {
                kv("Started",  call.startedAt.map { Self.timestampString($0) } ?? "—", mono: true)
                kv("Duration", call.duration.map { Self.durationString($0) } ?? "—", mono: true)
                if let tokens = result?.tokenCount, tokens > 0 {
                    kv("Tokens", tokens.formatted(), mono: true)
                } else {
                    kv("Tokens", "—", mono: true)
                }
                if let exit = call.exitCode {
                    kv("Exit code", "\(exit)", mono: true,
                       color: exit == 0 ? ScarfColor.success : ScarfColor.danger)
                } else {
                    kv("Exit code", "—", mono: true)
                }
            }
        }
    }

    private var permissionsSection: some View {
        section("PERMISSIONS", hint: "Tool gateway policy applied at run time") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ScarfColor.success)
                    (Text("Allowed by ")
                     + Text("scarf-default").font(ScarfFont.monoSmall)
                     + Text(" profile"))
                        .scarfStyle(.caption)
                }
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(ScarfColor.success)
                    Text("No human approval required")
                        .scarfStyle(.caption)
                }
            }
            .padding(ScarfSpace.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(ScarfColor.backgroundTertiary)
            )
        }
    }

    // MARK: - Output body

    private func outputBody(result: HermesMessage?) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s4) {
            Text("OUTPUT")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            if let content = result?.content, !content.isEmpty {
                Text(content)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
                    .textSelection(.enabled)
                    .padding(ScarfSpace.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(red: 0.07, green: 0.06, blue: 0.05))
                    )
            } else {
                Text("No output yet.")
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ScarfSpace.s3)
            }
        }
    }

    // MARK: - Raw body

    private func rawBody(call: HermesToolCall, result: HermesMessage?) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s4) {
            Text("RAW JSON")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text(rawJSONString(call: call, result: result))
                .font(ScarfFont.monoSmall)
                .foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
                .textSelection(.enabled)
                .padding(ScarfSpace.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(red: 0.07, green: 0.06, blue: 0.05))
                )
        }
    }

    // MARK: - Footer

    private func footer(call: HermesToolCall, result: HermesMessage?) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Button("Re-run") {
                // TODO: wire to a /retry slash command or equivalent ACP path.
                // No-op until that lands; button stays so the affordance is
                // visible per the design.
            }
            .buttonStyle(ScarfSecondaryButton())
            .disabled(true)
            .help("Re-run isn't wired yet")
            .frame(maxWidth: .infinity)

            Button("Copy") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(rawJSONString(call: call, result: result), forType: .string)
            }
            .buttonStyle(ScarfGhostButton())
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, ScarfSpace.s2)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: ScarfSpace.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("No tool selected")
                .scarfStyle(.bodyEmph)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Text("Click a tool call in the transcript to inspect it.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ScarfSpace.s5)
    }

    // MARK: - Section primitive

    @ViewBuilder
    private func section<Content: View>(_ title: String, hint: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Text(title)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            content()
            if let hint {
                Text(hint)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
    }

    private func kv(_ key: String, _ value: String, mono: Bool, color: Color? = nil) -> some View {
        HStack {
            Text(key)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Spacer()
            Text(value)
                .font(mono ? ScarfFont.monoSmall : ScarfFont.caption)
                .foregroundStyle(color ?? ScarfColor.foregroundPrimary)
        }
        .padding(.vertical, 5)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Helpers

    private func toolColor(_ call: HermesToolCall) -> Color {
        switch call.toolKind {
        case .read:    return ScarfColor.success
        case .edit:    return ScarfColor.info
        case .execute: return ScarfColor.warning
        case .fetch:   return ScarfColor.Tool.web
        case .browser: return ScarfColor.Tool.search
        case .other:   return ScarfColor.foregroundMuted
        }
    }

    private func toolLabel(_ call: HermesToolCall) -> String {
        switch call.toolKind {
        case .read: return "READ"
        case .edit: return "EDIT"
        case .execute: return "EXECUTE"
        case .fetch: return "FETCH"
        case .browser: return "BROWSER"
        case .other: return "TOOL"
        }
    }

    private func statusIcon(call: HermesToolCall, result: HermesMessage?) -> String {
        if let exit = call.exitCode { return exit == 0 ? "checkmark.circle.fill" : "xmark.circle.fill" }
        if result != nil { return "checkmark.circle.fill" }
        return "circle"
    }

    private func statusColor(call: HermesToolCall, result: HermesMessage?) -> Color {
        if let exit = call.exitCode { return exit == 0 ? ScarfColor.success : ScarfColor.danger }
        if result != nil { return ScarfColor.success }
        return ScarfColor.foregroundMuted
    }

    private func statusTitle(call: HermesToolCall, result: HermesMessage?) -> String {
        if let exit = call.exitCode { return exit == 0 ? "Completed" : "Failed" }
        if result != nil { return "Completed" }
        return "In progress"
    }

    private func statusSubtitle(call: HermesToolCall) -> String {
        if let exit = call.exitCode { return "Exit \(exit)" }
        if let started = call.startedAt {
            return "Started \(Self.timestampString(started))"
        }
        return "Awaiting result"
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

    private func rawJSONString(call: HermesToolCall, result: HermesMessage?) -> String {
        let resultBody: String
        if let r = result {
            let escaped = r.content.replacingOccurrences(of: "\"", with: "\\\"")
                                   .replacingOccurrences(of: "\n", with: "\\n")
            resultBody = "\"\(escaped)\""
        } else {
            resultBody = "null"
        }
        return """
        {
          "id": "\(call.callId)",
          "type": "tool_use",
          "name": "\(call.functionName)",
          "input": \(formatJSON(call.arguments)),
          "result": {
            "exit_code": \(call.exitCode.map { "\($0)" } ?? "null"),
            "duration_seconds": \(call.duration.map { String(format: "%.3f", $0) } ?? "null"),
            "content": \(resultBody)
          }
        }
        """
    }

    private static func timestampString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }

    private static func durationString(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int(seconds * 1000)) ms" }
        return String(format: "%.2f s", seconds)
    }
}
