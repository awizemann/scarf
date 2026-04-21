import SwiftUI

struct SessionDetailView: View {
    let session: HermesSession
    let messages: [HermesMessage]
    var subagentSessions: [HermesSession] = []
    var preview: String?
    var onRename: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSelectSubagent: ((HermesSession) -> Void)?

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
                Text(preview ?? session.displayTitle)
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
                    MessageBubble(message: message)
                }
            }
            .padding()
        }
    }
}

struct MessageBubble: View {
    let message: HermesMessage

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.isUser { Spacer(minLength: 60) }
                VStack(alignment: .leading, spacing: 6) {
                    if message.hasReasoning {
                        DisclosureGroup("Reasoning") {
                            Text(message.reasoning ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
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
