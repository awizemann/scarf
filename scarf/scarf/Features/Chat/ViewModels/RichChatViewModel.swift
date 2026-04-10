import Foundation

enum ChatDisplayMode: String, CaseIterable {
    case terminal
    case richChat
}

struct MessageGroup: Identifiable {
    let id: Int
    let userMessage: HermesMessage?
    let assistantMessages: [HermesMessage]
    let toolResults: [String: HermesMessage]

    var allMessages: [HermesMessage] {
        var result: [HermesMessage] = []
        if let user = userMessage { result.append(user) }
        result.append(contentsOf: assistantMessages)
        return result
    }

    var toolCallCount: Int {
        assistantMessages.reduce(0) { $0 + $1.toolCalls.count }
    }
}

@Observable
final class RichChatViewModel {
    private let dataService = HermesDataService()

    var messages: [HermesMessage] = []
    var currentSession: HermesSession?
    var messageGroups: [MessageGroup] = []
    var isAgentWorking = false
    var pendingPermission: PendingPermission?
    /// Mutated to trigger a scroll-to-bottom in the message list.
    var scrollTrigger = UUID()

    // Cumulative ACP token tracking (ACP returns tokens per prompt but DB has none)
    private(set) var acpInputTokens = 0
    private(set) var acpOutputTokens = 0
    private(set) var acpThoughtTokens = 0
    private(set) var acpCachedReadTokens = 0

    var hasMessages: Bool { !messages.isEmpty }

    func requestScrollToBottom() {
        scrollTrigger = UUID()
    }

    private(set) var sessionId: String?
    /// The original CLI session ID when resuming a CLI session via ACP.
    /// Used to combine old CLI messages with new ACP messages.
    private(set) var originSessionId: String?
    private var nextLocalId = -1
    private var streamingAssistantText = ""
    private var streamingThinkingText = ""
    private var streamingToolCalls: [HermesToolCall] = []

    // DB polling state (used in terminal mode fallback)
    private var lastKnownFingerprint: HermesDataService.MessageFingerprint?
    private var debounceTask: Task<Void, Never>?
    private var resetTimestamp: Date?
    private var userSendPending = false
    private var activePollingTimer: Timer?

    struct PendingPermission {
        let requestId: Int
        let title: String
        let kind: String
        let options: [(optionId: String, name: String)]
    }

    // MARK: - Reset

    func reset() {
        debounceTask?.cancel()
        stopActivePolling()
        Task { await dataService.close() }
        messages = []
        messageGroups = []
        currentSession = nil
        lastKnownFingerprint = nil
        sessionId = nil
        originSessionId = nil
        isAgentWorking = false
        userSendPending = false
        resetTimestamp = Date()
        nextLocalId = -1
        streamingAssistantText = ""
        streamingThinkingText = ""
        streamingToolCalls = []
        acpInputTokens = 0
        acpOutputTokens = 0
        acpThoughtTokens = 0
        acpCachedReadTokens = 0
        pendingPermission = nil
    }

    func setSessionId(_ id: String?) {
        sessionId = id
        lastKnownFingerprint = nil
    }

    func cleanup() async {
        stopActivePolling()
        debounceTask?.cancel()
        await dataService.close()
    }

    /// Re-fetch session metadata from DB to pick up cost/token updates.
    func refreshSessionFromDB() async {
        guard let sessionId else { return }
        let opened = await dataService.open()
        guard opened else { return }
        if let session = await dataService.fetchSession(id: sessionId) {
            currentSession = session
        }
        await dataService.close()
    }

    // MARK: - ACP Event Handling

    /// Add a user message immediately (before DB write) for instant UI feedback.
    func addUserMessage(text: String) {
        let id = nextLocalId
        nextLocalId -= 1
        let message = HermesMessage(
            id: id,
            sessionId: sessionId ?? "",
            role: "user",
            content: text,
            toolCallId: nil,
            toolCalls: [],
            toolName: nil,
            timestamp: Date(),
            tokenCount: nil,
            finishReason: nil,
            reasoning: nil
        )
        messages.append(message)
        isAgentWorking = true
        streamingAssistantText = ""
        streamingThinkingText = ""
        streamingToolCalls = []
        buildMessageGroups()
    }

    /// Process a streaming ACP event and update the message list.
    func handleACPEvent(_ event: ACPEvent) {
        switch event {
        case .messageChunk(_, let text):
            appendMessageChunk(text: text)
        case .thoughtChunk(_, let text):
            appendThoughtChunk(text: text)
        case .toolCallStart(_, let call):
            handleToolCallStart(call)
        case .toolCallUpdate(_, let update):
            handleToolCallComplete(update)
        case .permissionRequest(_, let requestId, let request):
            pendingPermission = PendingPermission(
                requestId: requestId,
                title: request.toolCallTitle,
                kind: request.toolCallKind,
                options: request.options
            )
        case .promptComplete(_, let response):
            handlePromptComplete(response: response)
        case .connectionLost(let reason):
            handleConnectionLost(reason: reason)
        case .availableCommands, .unknown:
            break
        }
    }

    private func appendMessageChunk(text: String) {
        streamingAssistantText += text
        upsertStreamingMessage()
    }

    private func appendThoughtChunk(text: String) {
        streamingThinkingText += text
        upsertStreamingMessage()
    }

    private func handleToolCallStart(_ call: ACPToolCallEvent) {
        let toolCall = HermesToolCall(
            callId: call.toolCallId,
            functionName: call.functionName,
            arguments: call.argumentsJSON
        )
        streamingToolCalls.append(toolCall)
        upsertStreamingMessage()
    }

    private func handleToolCallComplete(_ update: ACPToolCallUpdateEvent) {
        // Finalize the streaming assistant message (with its tool calls) as a permanent message
        finalizeStreamingMessage()

        // Add tool result message
        let id = nextLocalId
        nextLocalId -= 1
        messages.append(HermesMessage(
            id: id,
            sessionId: sessionId ?? "",
            role: "tool",
            content: update.rawOutput ?? update.content,
            toolCallId: update.toolCallId,
            toolCalls: [],
            toolName: nil,
            timestamp: Date(),
            tokenCount: nil,
            finishReason: nil,
            reasoning: nil
        ))
        buildMessageGroups()
    }

    private func handlePromptComplete(response: ACPPromptResult) {
        finalizeStreamingMessage()
        // Accumulate token usage from this prompt
        acpInputTokens += response.inputTokens
        acpOutputTokens += response.outputTokens
        acpThoughtTokens += response.thoughtTokens
        acpCachedReadTokens += response.cachedReadTokens
        isAgentWorking = false
        buildMessageGroups()
    }

    private func handleConnectionLost(reason: String) {
        finalizeStreamingMessage()
        let id = nextLocalId
        nextLocalId -= 1
        messages.append(HermesMessage(
            id: id,
            sessionId: sessionId ?? "",
            role: "system",
            content: "Connection lost: \(reason). Use the Session menu to start or resume a session.",
            toolCallId: nil,
            toolCalls: [],
            toolName: nil,
            timestamp: Date(),
            tokenCount: nil,
            finishReason: nil,
            reasoning: nil
        ))
        isAgentWorking = false
        pendingPermission = nil
        buildMessageGroups()
    }

    // MARK: - Streaming Message Management

    private static let streamingId = 0

    /// Insert or update the in-progress streaming assistant message (id=0).
    private func upsertStreamingMessage() {
        let msg = HermesMessage(
            id: Self.streamingId,
            sessionId: sessionId ?? "",
            role: "assistant",
            content: streamingAssistantText,
            toolCallId: nil,
            toolCalls: streamingToolCalls,
            toolName: nil,
            timestamp: Date(),
            tokenCount: nil,
            finishReason: nil,
            reasoning: streamingThinkingText.isEmpty ? nil : streamingThinkingText
        )

        if let idx = messages.firstIndex(where: { $0.id == Self.streamingId }) {
            messages[idx] = msg
        } else {
            messages.append(msg)
        }
        buildMessageGroups()
    }

    /// Convert the streaming message (id=0) into a permanent message and reset streaming state.
    private func finalizeStreamingMessage() {
        guard let idx = messages.firstIndex(where: { $0.id == Self.streamingId }) else { return }

        // Only finalize if there's actual content
        let hasContent = !streamingAssistantText.isEmpty
            || !streamingThinkingText.isEmpty
            || !streamingToolCalls.isEmpty

        if hasContent {
            let id = nextLocalId
            nextLocalId -= 1
            messages[idx] = HermesMessage(
                id: id,
                sessionId: sessionId ?? "",
                role: "assistant",
                content: streamingAssistantText,
                toolCallId: nil,
                toolCalls: streamingToolCalls,
                toolName: nil,
                timestamp: Date(),
                tokenCount: nil,
                finishReason: streamingToolCalls.isEmpty ? "stop" : nil,
                reasoning: streamingThinkingText.isEmpty ? nil : streamingThinkingText
            )
        } else {
            // Remove empty streaming placeholder
            messages.remove(at: idx)
        }

        // Reset streaming state for next chunk
        streamingAssistantText = ""
        streamingThinkingText = ""
        streamingToolCalls = []
    }

    // MARK: - Disconnect Recovery

    /// Finalize streaming state on disconnect, before reconnection attempts begin.
    /// Saves partial content as a permanent message without adding a system message.
    func finalizeOnDisconnect() {
        finalizeStreamingMessage()
        isAgentWorking = false
        pendingPermission = nil
        buildMessageGroups()
    }

    /// Reconcile in-memory messages with DB state after a successful reconnection.
    /// Merges DB-persisted messages with any local-only messages (e.g., user messages
    /// that the ACP process may not have persisted before crashing).
    func reconcileWithDB(sessionId: String) async {
        let opened = await dataService.open()
        guard opened else { return }

        var dbMessages = await dataService.fetchMessages(sessionId: sessionId)

        // If we have an origin session (CLI session continued via ACP),
        // include those messages too
        if let origin = originSessionId, origin != sessionId {
            let originMessages = await dataService.fetchMessages(sessionId: origin)
            if !originMessages.isEmpty {
                dbMessages = originMessages + dbMessages
                dbMessages.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
            }
        }

        let session = await dataService.fetchSession(id: sessionId)
        await dataService.close()

        // Find local-only user messages not yet in DB.
        // Local messages have negative IDs; DB messages have positive IDs.
        let dbUserContents = Set(dbMessages.filter(\.isUser).map(\.content))
        let localOnlyMessages = messages.filter { msg in
            msg.id < 0 && msg.isUser && !dbUserContents.contains(msg.content)
        }

        // Build reconciled list: DB messages + unmatched local user messages
        var reconciled = dbMessages
        for localMsg in localOnlyMessages {
            if let ts = localMsg.timestamp,
               let insertIdx = reconciled.firstIndex(where: { ($0.timestamp ?? .distantPast) > ts }) {
                reconciled.insert(localMsg, at: insertIdx)
            } else {
                reconciled.append(localMsg)
            }
        }

        messages = reconciled
        currentSession = session
        let minId = reconciled.map(\.id).min() ?? 0
        nextLocalId = min(minId - 1, -1)
        buildMessageGroups()
    }

    // MARK: - Load History from DB (for resumed sessions)

    /// Load message history from the DB, optionally combining an origin session
    /// (e.g., CLI session) with the current ACP session.
    func loadSessionHistory(sessionId: String, acpSessionId: String? = nil) async {
        self.sessionId = sessionId
        let opened = await dataService.open()
        guard opened else { return }

        var allMessages = await dataService.fetchMessages(sessionId: sessionId)
        let session = await dataService.fetchSession(id: sessionId)

        // If the ACP session is different from the origin, load its messages too
        // and combine them chronologically
        if let acpId = acpSessionId, acpId != sessionId {
            originSessionId = sessionId
            self.sessionId = acpId
            let acpMessages = await dataService.fetchMessages(sessionId: acpId)
            if !acpMessages.isEmpty {
                allMessages.append(contentsOf: acpMessages)
                allMessages.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
            }
        }

        messages = allMessages
        currentSession = session
        let minId = allMessages.map(\.id).min() ?? 0
        nextLocalId = min(minId - 1, -1)
        buildMessageGroups()
    }

    // MARK: - DB Polling (terminal mode fallback)

    func markAgentWorking() {
        isAgentWorking = true
        userSendPending = true
        startActivePolling()
    }

    func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await self?.refreshMessages()
        }
    }

    func refreshMessages() async {
        let opened = await dataService.open()
        guard opened else { return }

        if sessionId == nil {
            if let resetTime = resetTimestamp {
                if let candidate = await dataService.fetchMostRecentlyStartedSessionId(after: resetTime) {
                    sessionId = candidate
                }
            }
            if sessionId == nil {
                sessionId = await dataService.fetchMostRecentlyActiveSessionId()
            }
        }

        guard let sessionId else { return }

        let fingerprint = await dataService.fetchMessageFingerprint(sessionId: sessionId)

        if fingerprint != lastKnownFingerprint {
            let fetched = await dataService.fetchMessages(sessionId: sessionId)
            let session = await dataService.fetchSession(id: sessionId)
            lastKnownFingerprint = fingerprint

            messages = fetched
            currentSession = session
            buildMessageGroups()

            let derivedWorking = deriveAgentWorking(from: fetched)
            if userSendPending {
                if fetched.last?.isUser == true {
                    userSendPending = false
                }
                isAgentWorking = true
            } else {
                let wasWorking = isAgentWorking
                isAgentWorking = derivedWorking
                if wasWorking && !derivedWorking {
                    stopActivePolling()
                }
            }
        }
    }

    private func startActivePolling() {
        stopActivePolling()
        activePollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshMessages()
            }
        }
    }

    private func stopActivePolling() {
        activePollingTimer?.invalidate()
        activePollingTimer = nil
    }

    private func deriveAgentWorking(from fetched: [HermesMessage]) -> Bool {
        guard let last = fetched.last else { return false }
        if last.isUser { return true }
        if last.isToolResult { return true }
        if last.isAssistant {
            if !last.toolCalls.isEmpty {
                let allCallIds = Set(last.toolCalls.map(\.callId))
                let resultCallIds = Set(fetched.compactMap { $0.isToolResult ? $0.toolCallId : nil })
                return !allCallIds.subtracting(resultCallIds).isEmpty
            }
            return last.finishReason == nil
        }
        return false
    }

    // MARK: - Message Grouping

    private func buildMessageGroups() {
        var groups: [MessageGroup] = []
        var currentUser: HermesMessage?
        var currentAssistant: [HermesMessage] = []
        var currentToolResults: [String: HermesMessage] = [:]
        var groupIndex = 0

        func flushGroup() {
            if currentUser != nil || !currentAssistant.isEmpty {
                // Use stable sequential IDs so SwiftUI doesn't re-create views
                // when streaming messages finalize (id changes from 0 to -N)
                groups.append(MessageGroup(
                    id: groupIndex,
                    userMessage: currentUser,
                    assistantMessages: currentAssistant,
                    toolResults: currentToolResults
                ))
                groupIndex += 1
            }
            currentUser = nil
            currentAssistant = []
            currentToolResults = [:]
        }

        for message in messages {
            if message.isUser {
                flushGroup()
                currentUser = message
            } else if message.isToolResult {
                if let callId = message.toolCallId {
                    currentToolResults[callId] = message
                }
                currentAssistant.append(message)
            } else {
                if currentUser == nil && !currentAssistant.isEmpty && message.isAssistant {
                    flushGroup()
                }
                currentAssistant.append(message)
            }
        }
        flushGroup()

        messageGroups = groups
    }
}
