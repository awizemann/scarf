//
//  ScarfChatView.swift
//  Scarf — Chat surface
//
//  Faithful SwiftUI port of the macOS Chat UI from the design-system kit.
//  Three-pane layout:  session list  ·  transcript  ·  inspector.
//
//  Wire it up to your real session/message model by replacing the demo data
//  in `ChatViewModel`. Everything visual uses tokens from ScarfTheme + ScarfFont
//  + ScarfComponents — no raw hex, no hardcoded fonts.
//
//  How to integrate:
//    NavigationSplitView column / detail / inspector aren't used here because
//    Scarf uses a custom 3-pane layout (matches the kit). Drop ChatRootView
//    into your routing where the existing chat lives.
//

import SwiftUI

// MARK: - Tool kinds

public enum ChatToolKind: String, Hashable, CaseIterable {
    case read, edit, execute, fetch, browser, search

    var label: String {
        switch self {
        case .read:    return "READ"
        case .edit:    return "EDIT"
        case .execute: return "EXECUTE"
        case .fetch:   return "FETCH"
        case .browser: return "BROWSER"
        case .search:  return "SEARCH"
        }
    }

    var color: Color {
        switch self {
        case .read:    return ScarfColor.success         // green
        case .edit:    return ScarfColor.info            // blue
        case .execute: return ScarfColor.warning         // amber
        case .fetch:   return ScarfColor.Tool.web        // purple
        case .browser: return ScarfColor.Tool.search     // indigo
        case .search:  return ScarfColor.accent          // brand rust
        }
    }

    var tint: Color { color.opacity(0.12) }

    var icon: String {
        switch self {
        case .read:    return "book"
        case .edit:    return "doc.text"
        case .execute: return "terminal"
        case .fetch:   return "globe"
        case .browser: return "safari"
        case .search:  return "magnifyingglass"
        }
    }
}

// MARK: - Models

public struct ChatSession: Identifiable, Hashable {
    public let id: String
    public var title: String
    public var project: String
    public var preview: String
    public var time: String
    public var model: String
    public var unread: Int = 0
    public var pinned: Bool = false
    public var status: Status = .idle

    public enum Status { case idle, live, error }
}

public struct ChatToolCall: Identifiable, Hashable {
    public let id: String
    public var kind: ChatToolKind
    public var name: String
    public var arg: String
    public var duration: String
    public var startedAt: String
    public var tokens: Int
    public var exitCode: Int? = nil
    public var cwd: String? = nil
    public var linesAdded: Int? = nil
    public var linesRemoved: Int? = nil
}

public enum ChatBlock: Identifiable, Hashable {
    case user(id: String, text: String, time: String)
    case reasoning(id: String, tokens: Int, preview: String, full: String)
    case tool(ChatToolCall, expanded: Bool, hasDiff: Bool)
    case assistantText(id: String, markdown: AttributedString, time: String, model: String, tokens: Int, durationMs: Int, inProgress: Bool)
    case dateMarker(id: String, label: String)

    public var id: String {
        switch self {
        case .user(let id, _, _),
             .reasoning(let id, _, _, _),
             .assistantText(let id, _, _, _, _, _, _),
             .dateMarker(let id, _): return id
        case .tool(let call, _, _): return call.id
        }
    }
}

// MARK: - View model (replace with your real one)

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var sessions: [ChatSession]
    @Published var activeSessionID: String
    @Published var blocks: [ChatBlock]
    @Published var focusedToolID: String?
    @Published var draft: String = ""

    init() {
        sessions = [
            .init(id: "s1", title: "Cron diagnostics",      project: "scarf",        preview: "The daily-summary job ran 14 minutes ago…", time: "14m", model: "sonnet-4.5", pinned: true, status: .live),
            .init(id: "s2", title: "Release notes draft",   project: "hermes-blog",  preview: "Pulled the merged PRs from this week…",     time: "42m", model: "haiku-4.5", unread: 2),
            .init(id: "s3", title: "PR review summary",     project: "hermes-blog",  preview: "Three PRs are ready for review.",            time: "2h",  model: "sonnet-4.5"),
            .init(id: "s4", title: "Function calling models", project: "—",          preview: "Sonnet handles structured tool use…",        time: "3h",  model: "haiku-4.5"),
            .init(id: "s5", title: "Memory layout question", project: "scarf",       preview: "The shared memory keys live at…",            time: "yest.", model: "sonnet-4.5"),
            .init(id: "s6", title: "Catalog publish flow",   project: "hermes-blog", preview: "Walked through the .scarftemplate bundle…",  time: "yest.", model: "sonnet-4.5"),
            .init(id: "s7", title: "SSH tunnel debug",       project: "scarf-remote", preview: "Connection drops after ~90s of idle…",      time: "Mon", model: "sonnet-4.5", status: .error),
        ]
        activeSessionID = "s1"

        let calls: [ChatToolCall] = [
            .init(id: "tc-1", kind: .read,    name: "read_file",   arg: "~/.scarf/cron/jobs.json",                 duration: "86 ms", startedAt: "09:42:18.214", tokens: 412),
            .init(id: "tc-2", kind: .execute, name: "execute",     arg: "hermes cron status daily-summary",        duration: "1.4 s", startedAt: "09:42:18.302", tokens: 86, exitCode: 0, cwd: "~/.scarf"),
            .init(id: "tc-3", kind: .read,    name: "read_file",   arg: "~/.scarf/cron/output/daily-summary.md",   duration: "42 ms", startedAt: "09:43:01.190", tokens: 1284),
            .init(id: "tc-4", kind: .edit,    name: "apply_patch", arg: "~/.scarf/cron/jobs.json",                 duration: "120 ms", startedAt: "09:43:03.910", tokens: 88, linesAdded: 1, linesRemoved: 1),
        ]
        focusedToolID = "tc-2"

        let summary = try! AttributedString(
            markdown: "The `daily-summary` job ran **14 minutes ago** and completed successfully in 14.2 s, using 1,847 tokens. Next run is tomorrow at 09:00 — safe to ship the schedule changes."
        )

        blocks = [
            .dateMarker(id: "d1", label: "Today · 9:42 AM"),
            .user(id: "u1", text: "What's the status of the daily-summary cron job? I need to know if it's healthy before I push the new schedule changes.", time: "9:42 AM"),
            .reasoning(id: "r1", tokens: 127,
                preview: "Check the registry first, then the most recent execution.",
                full: "The user wants the status of a specific cron job named \"daily-summary\". I should check the cron registry first, then look at the most recent execution via `hermes cron status`. If exit_code is 0, the job is healthy and the schedule push is safe."),
            .tool(calls[0], expanded: false, hasDiff: false),
            .tool(calls[1], expanded: true,  hasDiff: false),
            .assistantText(id: "a1", markdown: summary, time: "9:42 AM", model: "sonnet-4.5", tokens: 284, durationMs: 2140, inProgress: false),
            .user(id: "u2", text: "Show me what it produced.", time: "9:43 AM"),
            .tool(calls[2], expanded: false, hasDiff: false),
            .tool(calls[3], expanded: false, hasDiff: true),
        ]
    }

    func focused() -> ChatToolCall? {
        guard let fid = focusedToolID else { return nil }
        for case let .tool(call, _, _) in blocks where call.id == fid { return call }
        return nil
    }
}

// MARK: - Root

public struct ChatRootView: View {
    @StateObject private var vm = ChatViewModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            ChatSessionListPane(vm: vm)
                .frame(width: 264)

            Divider().background(ScarfColor.border)

            ChatTranscriptPane(vm: vm)
                .frame(maxWidth: .infinity)

            Divider().background(ScarfColor.border)

            ChatInspectorPane(vm: vm)
                .frame(width: 320)
        }
        .background(ScarfColor.backgroundPrimary)
    }
}

// MARK: - Pane 1 · session list

struct ChatSessionListPane: View {
    @ObservedObject var vm: ChatViewModel
    @State private var filter = "all"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: ScarfSpace.s2) {
                Text("Chats").scarfStyle(.headline)
                Spacer()
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Button { } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text("New")
                    }
                }.buttonStyle(ScarfPrimaryButton())
            }
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.top, ScarfSpace.s3)
            .padding(.bottom, ScarfSpace.s2)

            // Filter segmented
            Picker("", selection: $filter) {
                Text("All").tag("all")
                Text("Live").tag("live")
                Text("Pinned").tag("pinned")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.bottom, ScarfSpace.s2)

            // List
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(vm.sessions.prefix(4)) { s in
                            ChatSessionRow(session: s, isActive: s.id == vm.activeSessionID)
                                .onTapGesture { vm.activeSessionID = s.id }
                        }
                    } header: {
                        sectionHeader("Today")
                    }
                    Section {
                        ForEach(vm.sessions.suffix(from: 4)) { s in
                            ChatSessionRow(session: s, isActive: s.id == vm.activeSessionID)
                                .onTapGesture { vm.activeSessionID = s.id }
                        }
                    } header: {
                        sectionHeader("Earlier")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, ScarfSpace.s2)
            }

            // Footer
            HStack(spacing: ScarfSpace.s2) {
                Image(systemName: "bubble.left").font(.system(size: 10))
                Text("\(vm.sessions.count) chats")
                Spacer()
                Text("1.2 MB · state.db").font(ScarfFont.monoSmall)
            }
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, ScarfSpace.s2)
            .overlay(Rectangle().fill(ScarfColor.border).frame(height: 1), alignment: .top)
        }
        .background(ScarfColor.backgroundTertiary)
    }

    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text).scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, ScarfSpace.s2).padding(.bottom, ScarfSpace.s1)
        .background(ScarfColor.backgroundTertiary)
    }
}

struct ChatSessionRow: View {
    let session: ChatSession
    let isActive: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                statusDot
                if session.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(ScarfColor.accent)
                }
                Text(session.title)
                    .scarfStyle(.bodyEmph)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
                Spacer(minLength: 0)
                Text(session.time)
                    .font(ScarfFont.caption2)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            HStack(spacing: 6) {
                if session.project != "—" {
                    Text(session.project)
                        .font(ScarfFont.caption2)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: ScarfRadius.sm).fill(ScarfColor.backgroundSecondary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: ScarfRadius.sm)
                                        .strokeBorder(ScarfColor.border, lineWidth: 1)
                                )
                        )
                }
                Text(session.preview)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(1)
                if session.unread > 0 {
                    Text("\(session.unread)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(ScarfColor.accent))
                }
            }
            .padding(.leading, 14)
        }
        .padding(.horizontal, 10).padding(.vertical, ScarfSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? ScarfColor.accentTint :
                      (hover ? ScarfColor.border : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch session.status {
        case .live:
            Circle().fill(ScarfColor.success).frame(width: 7, height: 7)
                .overlay(Circle().stroke(ScarfColor.success.opacity(0.20), lineWidth: 2))
        case .error:
            Circle().fill(ScarfColor.danger).frame(width: 6, height: 6)
        case .idle:
            Circle().fill(ScarfColor.foregroundFaint.opacity(0.4)).frame(width: 6, height: 6)
        }
    }
}

// MARK: - Pane 2 · transcript

struct ChatTranscriptPane: View {
    @ObservedObject var vm: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            transcriptHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ScarfSpace.s4) {
                    ForEach(vm.blocks, id: \.id) { block in
                        renderBlock(block)
                    }
                    suggestedReplies
                }
                .padding(.horizontal, 28).padding(.top, ScarfSpace.s5).padding(.bottom, ScarfSpace.s2)
            }
            ChatComposer(text: $vm.draft)
        }
        .background(ScarfColor.backgroundPrimary)
    }

    private var transcriptHeader: some View {
        HStack(spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: ScarfSpace.s2) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ScarfColor.accent)
                    Text("Cron diagnostics").scarfStyle(.bodyEmph)
                    ScarfBadge("live", kind: .success)
                }
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").font(.system(size: 10))
                        .foregroundStyle(ScarfColor.accent)
                    Text("scarf").scarfStyle(.caption).foregroundStyle(ScarfColor.accent).fontWeight(.semibold)
                    metaSeparator
                    Text("claude-sonnet-4.5").font(ScarfFont.monoSmall)
                    metaSeparator
                    Text("14 messages").scarfStyle(.caption)
                    metaSeparator
                    Text("12,847 tok").font(ScarfFont.monoSmall)
                    metaSeparator
                    Text("$0.0421").font(ScarfFont.monoSmall)
                }
                .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            Button("Branch") { }.buttonStyle(ScarfGhostButton())
            Button("Share")  { }.buttonStyle(ScarfSecondaryButton())
        }
        .padding(.horizontal, ScarfSpace.s6).padding(.vertical, ScarfSpace.s3)
        .background(ScarfColor.backgroundSecondary)
        .overlay(Rectangle().fill(ScarfColor.border).frame(height: 1), alignment: .bottom)
    }

    private var metaSeparator: some View {
        Text("·").foregroundStyle(ScarfColor.foregroundFaint)
    }

    @ViewBuilder
    private func renderBlock(_ block: ChatBlock) -> some View {
        switch block {
        case .dateMarker(_, let label):
            HStack(spacing: 10) {
                Rectangle().fill(ScarfColor.border).frame(height: 1)
                Text(label).scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Rectangle().fill(ScarfColor.border).frame(height: 1)
            }
        case .user(_, let text, let time):
            UserMessageBubble(text: text, time: time)
        case .reasoning(_, let tokens, let preview, let full):
            ReasoningBlock(tokens: tokens, preview: preview, full: full)
        case .tool(let call, let expanded, let hasDiff):
            ToolCallCard(call: call, defaultExpanded: expanded, hasDiff: hasDiff,
                         isFocused: vm.focusedToolID == call.id) {
                vm.focusedToolID = call.id
            }
        case .assistantText(_, let markdown, let time, let model, let tokens, let durMs, let inProgress):
            AssistantBubble(markdown: markdown, time: time, model: model,
                            tokens: tokens, durationMs: durMs, inProgress: inProgress)
        }
    }

    private var suggestedReplies: some View {
        HStack(spacing: 6) {
            ForEach(["Schedule a dry run", "Show last 5 runs", "Disable daily-summary"], id: \.self) { s in
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 10))
                        .foregroundStyle(ScarfColor.accent)
                    Text(s).scarfStyle(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    Capsule().fill(ScarfColor.backgroundSecondary)
                        .overlay(Capsule().strokeBorder(ScarfColor.borderStrong, lineWidth: 1))
                )
            }
        }
        .padding(.leading, 36).padding(.top, 2)
    }
}

// MARK: · User bubble

struct UserMessageBubble: View {
    let text: String
    let time: String
    var body: some View {
        HStack { Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(
                        UnevenRoundedRectangle(cornerRadii:
                            .init(topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14))
                            .fill(ScarfColor.accent)
                    )
                    .frame(maxWidth: 540, alignment: .trailing)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(ScarfColor.success)
                    Text(time).font(ScarfFont.caption2)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
            }
        }
    }
}

// MARK: · Assistant bubble

struct AssistantBubble: View {
    let markdown: AttributedString
    let time: String
    let model: String
    let tokens: Int
    let durationMs: Int
    let inProgress: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ScarfGradient.brand)
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "sparkles")
                    .foregroundStyle(.white).font(.system(size: 12, weight: .semibold)))
                .scarfShadow(.sm)

            VStack(alignment: .leading, spacing: 4) {
                ScarfCard(padding: ScarfSpace.s3) {
                    Text(markdown).scarfStyle(.body)
                }
                HStack(spacing: 8) {
                    if inProgress {
                        HStack(spacing: 4) {
                            Circle().fill(ScarfColor.accent).frame(width: 7, height: 7)
                                .modifier(PulseModifier())
                            Text("thinking…").foregroundStyle(ScarfColor.accent).fontWeight(.semibold)
                        }
                    }
                    Text(model).font(ScarfFont.monoSmall)
                    Text("·")
                    Text("\(tokens) tok").font(ScarfFont.monoSmall)
                    Text("·")
                    Text("\(String(format: "%.1f", Double(durationMs) / 1000))s")
                    Text("·")
                    Text(time)
                }
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on.toggle() }
    }
}

// MARK: · Reasoning

struct ReasoningBlock: View {
    let tokens: Int
    let preview: String
    let full: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(ScarfAnimation.smooth) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                    Text("REASONING").tracking(0.5)
                    Text("· \(tokens) tok").font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                }
                .scarfStyle(.captionStrong)
                .foregroundStyle(ScarfColor.warning)
            }
            .buttonStyle(.plain)

            if open {
                Text(full).scarfStyle(.footnote)
                    .italic()
                    .foregroundStyle(ScarfColor.foregroundMuted)
            } else {
                Text(preview).scarfStyle(.footnote)
                    .italic()
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(ScarfColor.warning.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ScarfColor.warning.opacity(0.30), lineWidth: 1))
        )
    }
}

// MARK: · ToolCall card

struct ToolCallCard: View {
    let call: ChatToolCall
    let defaultExpanded: Bool
    let hasDiff: Bool
    let isFocused: Bool
    let onTap: () -> Void

    @State private var open: Bool

    init(call: ChatToolCall, defaultExpanded: Bool, hasDiff: Bool,
         isFocused: Bool, onTap: @escaping () -> Void) {
        self.call = call
        self.defaultExpanded = defaultExpanded
        self.hasDiff = hasDiff
        self.isFocused = isFocused
        self.onTap = onTap
        self._open = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onTap()
                withAnimation(ScarfAnimation.fast) { open.toggle() }
            } label: {
                HStack(spacing: 9) {
                    HStack(spacing: 5) {
                        Image(systemName: call.kind.icon)
                            .foregroundStyle(call.kind.color)
                            .font(.system(size: 11))
                        Text(call.kind.label).tracking(0.4)
                            .scarfStyle(.captionStrong)
                            .foregroundStyle(call.kind.color)
                    }
                    Text(call.name).font(ScarfFont.monoSmall).fontWeight(.semibold)
                    Text(call.arg).font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(call.duration).font(ScarfFont.caption2)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(ScarfColor.success)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(ScarfColor.foregroundFaint)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isFocused ? call.kind.tint : ScarfColor.border.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(isFocused ? call.kind.color : ScarfColor.border, lineWidth: isFocused ? 1.4 : 1)
                        )
                )
            }
            .buttonStyle(.plain)

            if open {
                if hasDiff {
                    DiffPreview()
                } else if call.kind == .execute {
                    TerminalOutput()
                } else {
                    JSONPreview()
                }
            }
        }
    }
}

private struct TerminalOutput: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                Text("$ ").foregroundStyle(Color(red: 0.48, green: 0.45, blue: 0.40))
                + Text("hermes").foregroundStyle(Color(red: 0.94, green: 0.77, blue: 0.62))
                + Text(" cron status daily-summary").foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
            }
            .font(ScarfFont.monoSmall)
            VStack(alignment: .leading, spacing: 2) {
                line("✓ last_run:    2026-04-25T09:28:14Z")
                line("✓ duration:    14.2s")
                line("✓ exit_code:   0")
                line("✓ tokens_used: 1,847")
                line("  next_run:    2026-04-26T09:00:00Z", muted: true)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(red: 0.07, green: 0.06, blue: 0.05))
        )
    }
    private func line(_ s: String, muted: Bool = false) -> some View {
        Text(s).font(ScarfFont.monoSmall)
            .foregroundStyle(muted
                             ? Color(red: 0.64, green: 0.61, blue: 0.57)
                             : Color(red: 0.91, green: 0.88, blue: 0.82))
    }
}

private struct JSONPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row(1, "{")
            row(2, #"  "name": "daily-summary","#)
            row(3, #"  "schedule": "0 9 * * *","#)
            row(4, #"  "enabled": true"#)
            row(5, "}")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(ScarfColor.backgroundSecondary)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ScarfColor.border, lineWidth: 1))
        )
    }
    private func row(_ n: Int, _ s: String) -> some View {
        HStack(spacing: 0) {
            Text(String(format: "%2d", n))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("  ").font(ScarfFont.monoSmall)
            Text(s).foregroundStyle(ScarfColor.foregroundMuted)
        }
        .font(ScarfFont.monoSmall)
    }
}

private struct DiffPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row("3", "  \"schedule\": \"0 9 * * *\",", bg: nil, color: ScarfColor.foregroundPrimary)
            row("-", "  \"timezone\": \"UTC\",", bg: ScarfColor.danger.opacity(0.10), color: ScarfColor.danger)
            row("+", "  \"timezone\": \"America/New_York\",", bg: ScarfColor.success.opacity(0.10), color: ScarfColor.success)
            row("5", "  \"enabled\": true", bg: nil, color: ScarfColor.foregroundPrimary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(ScarfColor.backgroundSecondary)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ScarfColor.border, lineWidth: 1))
        )
    }
    private func row(_ marker: String, _ text: String, bg: Color?, color: Color) -> some View {
        HStack(spacing: 0) {
            Text(marker).frame(width: 22, alignment: .center)
                .foregroundStyle(color)
            Text(text).foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer(minLength: 0)
        }
        .font(ScarfFont.monoSmall)
        .padding(.vertical, 1)
        .background(bg ?? Color.clear)
    }
}

// MARK: · Composer

struct ChatComposer: View {
    @Binding var text: String
    @State private var slashOpen = false

    var body: some View {
        VStack(spacing: ScarfSpace.s2) {
            // Context chips row
            HStack(spacing: 6) {
                contextChip("folder", "scarf", brand: true)
                contextChip("doc.text", "cron/jobs.json", brand: false)
                contextChip("plus", "Add context", muted: true)
                Spacer()
            }
            // Input
            TextField("Message Hermes…  /  for commands  ·  @  for files",
                      text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .scarfStyle(.body)
                .lineLimit(1...6)
                .onChange(of: text) { _, newValue in
                    slashOpen = newValue.trimmingCharacters(in: .whitespaces).hasPrefix("/")
                }
            // Footer row
            HStack(spacing: 6) {
                composerIcon("paperclip")
                composerIcon("at")
                composerIcon("photo")
                Divider().frame(height: 14)
                composerChip("cpu", "sonnet-4.5")
                composerChip("folder", "scarf")
                Spacer()
                Text("↵ send · ⇧↵ newline")
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Button {} label: {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(.white)
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(ScarfColor.accent)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(ScarfSpace.s3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(slashOpen ? ScarfColor.accent : ScarfColor.borderStrong,
                                      lineWidth: 1)
                )
        )
        .scarfShadow(slashOpen ? .md : .sm)
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.vertical, ScarfSpace.s3)
        .background(ScarfColor.backgroundSecondary)
        .overlay(Rectangle().fill(ScarfColor.border).frame(height: 1), alignment: .top)
        .overlay(alignment: .bottomLeading) {
            if slashOpen { SlashMenu().padding(.horizontal, ScarfSpace.s6).offset(y: -56) }
        }
    }

    private func contextChip(_ icon: String, _ label: String, brand: Bool = false, muted: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(brand ? ScarfFont.caption : ScarfFont.monoSmall)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .foregroundStyle(brand ? ScarfColor.accentActive
                         : muted ? ScarfColor.foregroundMuted : ScarfColor.foregroundPrimary)
        .background(
            Capsule().fill(brand ? ScarfColor.accentTint : ScarfColor.border.opacity(0.5))
                .overlay(
                    Capsule().strokeBorder(
                        muted ? ScarfColor.borderStrong : Color.clear,
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
        )
    }

    private func composerIcon(_ icon: String) -> some View {
        Button {} label: {
            Image(systemName: icon).font(.system(size: 12))
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(4)
        }.buttonStyle(.plain)
    }

    private func composerChip(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(ScarfFont.monoSmall)
        }
        .foregroundStyle(ScarfColor.foregroundMuted)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(ScarfColor.border.opacity(0.4)))
    }
}

private struct SlashMenu: View {
    let items: [(cmd: String, desc: String, icon: String)] = [
        ("compress", "Compress conversation context", "arrow.down.right.and.arrow.up.left"),
        ("clear",    "Clear and start fresh",         "trash"),
        ("model",    "Switch model",                  "cpu"),
        ("project",  "Change project",                "folder"),
        ("memory",   "Edit AGENTS.md",                "externaldrive"),
        ("cost",     "Show token / cost report",      "dollarsign.circle"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SLASH COMMANDS").scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(spacing: 9) {
                    Image(systemName: item.icon).font(.system(size: 13))
                    Text("/\(item.cmd)").font(ScarfFont.mono).fontWeight(.semibold)
                    Text(item.desc).scarfStyle(.footnote)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Spacer()
                    if idx == 0 {
                        Text("↵").font(ScarfFont.monoSmall)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(ScarfColor.border))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(idx == 0 ? ScarfColor.accentTint : Color.clear)
                .foregroundStyle(idx == 0 ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(4)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ScarfColor.border, lineWidth: 1))
        )
        .scarfShadow(.lg)
    }
}

// MARK: - Pane 3 · Inspector

struct ChatInspectorPane: View {
    @ObservedObject var vm: ChatViewModel
    @State private var tab = "details"

    var body: some View {
        let call = vm.focused()
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                HStack(spacing: ScarfSpace.s2) {
                    if let call {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(call.kind.tint)
                            .frame(width: 24, height: 24)
                            .overlay(Image(systemName: call.kind.icon)
                                .foregroundStyle(call.kind.color)
                                .font(.system(size: 11)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(call.kind.label) CALL").tracking(0.5)
                                .scarfStyle(.captionStrong)
                                .foregroundStyle(call.kind.color)
                            Text(call.name).font(ScarfFont.mono).fontWeight(.semibold)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { } label: {
                        Image(systemName: "xmark").font(.system(size: 11))
                            .foregroundStyle(ScarfColor.foregroundMuted).padding(4)
                    }.buttonStyle(.plain)
                }
                Picker("", selection: $tab) {
                    Text("Details").tag("details")
                    Text("Output").tag("output")
                    Text("Raw").tag("raw")
                }.pickerStyle(.segmented)
            }
            .padding(.horizontal, ScarfSpace.s4).padding(.vertical, ScarfSpace.s3)
            .overlay(Rectangle().fill(ScarfColor.border).frame(height: 1), alignment: .bottom)

            // Body
            ScrollView {
                if let call {
                    Group {
                        switch tab {
                        case "details": InspectorDetails(call: call)
                        case "output":  InspectorOutput()
                        default:        InspectorRaw(call: call)
                        }
                    }
                    .padding(ScarfSpace.s4)
                } else {
                    VStack { Text("No tool selected") }
                        .padding(ScarfSpace.s4)
                }
            }

            // Footer
            HStack(spacing: 6) {
                Button("Re-run") {}.buttonStyle(ScarfSecondaryButton()).frame(maxWidth: .infinity)
                Button("Copy")   {}.buttonStyle(ScarfGhostButton())
            }
            .padding(.horizontal, ScarfSpace.s4).padding(.vertical, ScarfSpace.s2)
            .overlay(Rectangle().fill(ScarfColor.border).frame(height: 1), alignment: .top)
        }
        .background(ScarfColor.backgroundSecondary)
    }
}

private struct InspectorDetails: View {
    let call: ChatToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s5) {
            // Status banner
            section("STATUS") {
                HStack(spacing: ScarfSpace.s2) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ScarfColor.success).font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Completed").scarfStyle(.captionStrong)
                            .foregroundStyle(ScarfColor.success)
                        Text("Exit 0 · No errors").scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    Spacer()
                }
                .padding(ScarfSpace.s2)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(ScarfColor.success.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ScarfColor.success.opacity(0.25), lineWidth: 1))
                )
            }
            section("ARGUMENTS") {
                Text(call.arg).font(ScarfFont.monoSmall)
                    .padding(ScarfSpace.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(ScarfColor.border.opacity(0.4)))
            }
            section("TELEMETRY") {
                VStack(spacing: 0) {
                    kv("Started",  call.startedAt, mono: true)
                    kv("Duration", call.duration, mono: true)
                    kv("Tokens",   call.tokens.formatted(), mono: true)
                    if let exit = call.exitCode {
                        kv("Exit code", "\(exit)", mono: true, color: ScarfColor.success)
                    }
                    if let cwd = call.cwd { kv("CWD", cwd, mono: true) }
                    if let added = call.linesAdded, let removed = call.linesRemoved {
                        kv("Diff", "+\(added) / −\(removed)", mono: true)
                    }
                }
            }
            section("PERMISSIONS", hint: "Tool gateway policy applied at run time") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill").font(.system(size: 11))
                            .foregroundStyle(ScarfColor.success)
                        (Text("Allowed by ")
                         + Text("scarf-default").font(ScarfFont.monoSmall)
                         + Text(" profile"))
                            .scarfStyle(.caption)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 11))
                            .foregroundStyle(ScarfColor.success)
                        Text("No human approval required").scarfStyle(.caption)
                    }
                }
                .padding(ScarfSpace.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(ScarfColor.border.opacity(0.4)))
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        hint: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack {
                Text(title).scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Spacer()
            }
            content()
            if let hint {
                Text(hint).scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
    }

    private func kv(_ k: String, _ v: String, mono: Bool, color: Color? = nil) -> some View {
        HStack {
            Text(k).scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Spacer()
            Text(v)
                .font(mono ? ScarfFont.monoSmall : ScarfFont.caption)
                .foregroundStyle(color ?? ScarfColor.foregroundPrimary)
        }
        .padding(.vertical, 5)
        .overlay(Rectangle().fill(ScarfColor.border).frame(height: 1), alignment: .bottom)
    }
}

private struct InspectorOutput: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s4) {
            Text("STDOUT").scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    Text("$ ").foregroundStyle(Color(red: 0.48, green: 0.45, blue: 0.40))
                    + Text("hermes").foregroundStyle(Color(red: 0.94, green: 0.77, blue: 0.62))
                    + Text(" cron status daily-summary").foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
                }
                Text("✓ last_run:    2026-04-25T09:28:14Z").foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
                Text("✓ duration:    14.2s").foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
                Text("✓ exit_code:   0").foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
                Text("✓ tokens_used: 1,847").foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
            }
            .font(ScarfFont.monoSmall)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.07, green: 0.06, blue: 0.05)))
        }
    }
}

private struct InspectorRaw: View {
    let call: ChatToolCall
    var body: some View {
        Text(rawJSON)
            .font(ScarfFont.monoSmall)
            .foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.07, green: 0.06, blue: 0.05)))
    }
    private var rawJSON: String {
        """
        {
          "id": "\(call.id)",
          "type": "tool_use",
          "name": "\(call.name)",
          "input": {
            "command": "\(call.arg)"
          },
          "result": {
            "exit_code": \(call.exitCode ?? 0),
            "duration": "\(call.duration)"
          }
        }
        """
    }
}

// MARK: - Preview

#Preview("Chat — Light") {
    ChatRootView()
        .frame(width: 1200, height: 800)
        .preferredColorScheme(.light)
}

#Preview("Chat — Dark") {
    ChatRootView()
        .frame(width: 1200, height: 800)
        .preferredColorScheme(.dark)
}
