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
            } else if let user = chatViewModel.focusedUserMessage {
                // v2.10.2 — long user-message bubbles were overflowing
                // (no lineLimit / maxHeight / scroll on Text → overlapped
                // later bubbles). Route the long content to the inspector
                // pane, which already has a working ScrollView. Header is
                // simpler than the tool-call header (no segmented tabs);
                // close button calls `setInspectorFocus(.none)`.
                userMessageHeader(user)
                ScrollView {
                    userMessageBody(user)
                        .padding(ScarfSpace.s4)
                }
                userMessageFooter(user)
            } else {
                emptyState
            }
        }
        .background(ScarfColor.backgroundSecondary)
        // v2.8 — lazy-load the tool result content when the inspector
        // opens for a call whose result wasn't auto-hydrated. The
        // chat-resume path skips Phase 2b by default (the bulk fetch
        // can blow past the 30s SSH timeout on remote contexts), so
        // the inspector is the user-initiated lazy path.
        .task(id: chatViewModel.focusedToolCallId) {
            guard let id = chatViewModel.focusedToolCallId,
                  chatViewModel.focusedToolCall?.result == nil else { return }
            await chatViewModel.richChatViewModel.loadToolResultIfMissing(callId: id)
        }
    }

    // MARK: - User-message focus (v2.10.2)

    private func userMessageHeader(_ message: HermesMessage) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ScarfColor.accent.opacity(0.16))
                Image(systemName: "person.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(ScarfColor.accent)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("USER MESSAGE")
                    .scarfStyle(.captionStrong)
                    .tracking(0.5)
                    .foregroundStyle(ScarfColor.accent)
                if let time = message.timestamp {
                    Text(time, style: .time)
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
            Spacer()
            Button {
                chatViewModel.setInspectorFocus(.none)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Close inspector")
        }
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, ScarfSpace.s3)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private func userMessageBody(_ message: HermesMessage) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Text("\(message.content.count) characters")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text(message.content)
                .font(ScarfFont.body)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScarfSpace.s3)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(ScarfColor.backgroundTertiary)
                )
        }
    }

    private func userMessageFooter(_ message: HermesMessage) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Spacer()
            Button("Copy") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(message.content, forType: .string)
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

    // MARK: - Header

    private func header(_ call: HermesToolCall) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack(spacing: ScarfSpace.s2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(call.toolKind.tone.wash)
                    Image(systemName: call.toolKind.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(call.toolKind.tone.color)
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(toolLabel(call)) CALL")
                        .scarfStyle(.captionStrong)
                        .tracking(0.5)
                        .foregroundStyle(call.toolKind.tone.color)
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
                    .foregroundStyle(statusTone(call: call, result: result).text)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle(call: call, result: result))
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(statusTone(call: call, result: result).text)
                    Text(statusSubtitle(call: call))
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer()
            }
            .padding(ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(statusTone(call: call, result: result).tinted(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(statusTone(call: call, result: result).text.opacity(0.25), lineWidth: 1)
                    )
            )
        }
    }

    private func argumentsSection(call: HermesToolCall) -> some View {
        section("ARGUMENTS") {
            // A live built-in call arrives without arguments (Hermes sends
            // `rawInput` only for unknown tools); show Hermes's own preview
            // of it rather than a bare `{}`.
            Text(call.hasNoArguments ? (call.livePreview ?? call.arguments) : formatJSON(call.arguments))
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
            // No "Re-run" (gh#147): Hermes's ACP adapter offers no retry
            // (`/retry` is CLI/gateway only), and a client-side resend would
            // duplicate the turn in Hermes's history. A permanently disabled
            // button promised a feature that isn't coming from this side.
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

    /// Status text and icon use the tone's `text` step on its `color` wash.
    private func statusTone(call: HermesToolCall, result: HermesMessage?) -> ScarfBadgeKind {
        if let exit = call.exitCode { return exit == 0 ? .success : .danger }
        if result != nil { return .success }
        return .neutral
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
