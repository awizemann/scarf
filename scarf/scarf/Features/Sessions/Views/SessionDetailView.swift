import SwiftUI
import ScarfCore

struct SessionDetailView: View {
    let session: HermesSession
    let messages: [HermesMessage]
    var subagentSessions: [HermesSession] = []
    var preview: String?
    var onRename: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSelectSubagent: ((HermesSession) -> Void)?
    /// Lazy loader for a message's `reasoning_content`, wired to
    /// `SessionsViewModel.reasoningContent(for:)`. The bulk message fetch
    /// NULLs that blob (`messageColumnsLight`), so without this the
    /// REASONING disclosure opened empty for every v0.16+ thinking-model
    /// message. `nil` (previews, callers with no data service) simply
    /// leaves the disclosure showing whatever the row already carries.
    var loadReasoningContent: ((Int) async -> String?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionHeader
            if !subagentSessions.isEmpty {
                subagentSection
            }
            Divider()
            messagesList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.displayLabel(preview: preview))
                    .font(.title3.bold())
                Spacer()
                if onRename != nil || onExport != nil || onDelete != nil {
                    Menu {
                        if let onRename { Button("Rename...") { onRename() } }
                        if let onExport { Button("Export...") { onExport() } }
                        if let onDelete {
                            Divider()
                            Button("Delete...", role: .destructive) { onDelete() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            HStack(spacing: 16) {
                Label(session.source, systemImage: session.sourceIcon)
                if session.isSubagent {
                    Label("Subagent", systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                }
                if let userId = session.userId, !userId.isEmpty, session.source != "cli" {
                    Label(userId, systemImage: "person")
                }
                Label(session.model ?? "unknown", systemImage: "cpu")
                Label("\(session.messageCount) msgs", systemImage: "bubble.left")
                Label("\(session.toolCallCount) tools", systemImage: "wrench")
                if session.apiCallCount > 0 {
                    // Hermes v2026.4.23+ — distinct from tool calls;
                    // every reasoning step costs an API call too.
                    Label("\(session.apiCallCount) API", systemImage: "network")
                }
                if session.reasoningTokens > 0 {
                    Label("\(session.reasoningTokens) reasoning", systemImage: "brain")
                }
                if let cost = session.displayCostUSD {
                    let formattedCost = cost.formatted(.currency(code: "USD").precision(.fractionLength(4)))
                    Label(session.costIsActual ? formattedCost : "\(formattedCost) est.", systemImage: "dollarsign.circle")
                }
                if let date = session.startedAt {
                    Label(date.formatted(.dateTime.month().day().hour().minute()), systemImage: "calendar")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(session.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding()
    }

    private var subagentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Subagent Sessions (\(subagentSessions.count))")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(subagentSessions) { sub in
                Button {
                    onSelectSubagent?(sub)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.orange)
                        Text(sub.displayTitle)
                            .lineLimit(1)
                        Spacer()
                        Text(sub.model ?? "")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(sub.messageCount) msgs")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var messagesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(messages) { message in
                    MessageBubble(message: message, loadReasoningContent: loadReasoningContent)
                }
            }
            .padding()
        }
    }
}

struct MessageBubble: View {
    let message: HermesMessage
    var loadReasoningContent: ((Int) async -> String?)?

    @State private var reasoningExpanded = false
    /// `reasoning_content` pulled on first disclosure-open, when the
    /// bulk-loaded row didn't carry it. Mirrors `RichMessageBubble`'s
    /// `lazyReasoningContent` (t-aud21).
    @State private var lazyReasoningContent: String?

    /// Whatever reasoning we can actually show: the lazily fetched blob
    /// first, then whichever channel the row arrived with.
    private var reasoningText: String {
        lazyReasoningContent ?? message.preferredReasoning ?? ""
    }

    /// Fetch the richer `reasoning_content` the first time the user opens
    /// the disclosure. No-op when the row already has it, when it's
    /// already been fetched, or on a pre-v0.11 host (the fetch returns nil).
    private func loadFullReasoningIfNeeded() async {
        guard let loadReasoningContent,
              message.id > 0,
              (message.reasoningContent ?? "").isEmpty,
              lazyReasoningContent == nil else { return }
        if let full = await loadReasoningContent(message.id), !full.isEmpty {
            lazyReasoningContent = full
        }
    }

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.isUser { Spacer(minLength: 60) }
                VStack(alignment: .leading, spacing: 6) {
                    if message.hasReasoning {
                        DisclosureGroup("Reasoning", isExpanded: $reasoningExpanded) {
                            Text(reasoningText)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .onChange(of: reasoningExpanded) { _, expanded in
                            guard expanded else { return }
                            Task { await loadFullReasoningIfNeeded() }
                        }
                    }
                    if !message.content.isEmpty {
                        if message.isAssistant {
                            MarkdownContentView(content: message.content)
                        } else {
                            Text(message.content)
                                .textSelection(.enabled)
                        }
                    }
                    if !message.toolCalls.isEmpty {
                        ForEach(message.toolCalls) { call in
                            ToolCallBadge(call: call)
                        }
                    }
                }
                .padding(10)
                .background(message.isUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if !message.isUser { Spacer(minLength: 60) }
            }
            if let time = message.timestamp {
                Text(time, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}

struct ToolCallBadge: View {
    let call: HermesToolCall

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: call.toolKind.icon)
                        .foregroundStyle(toolColor)
                    Text(call.functionName)
                        .font(.caption.monospaced())
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Text(call.argumentsSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(6)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
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
}
