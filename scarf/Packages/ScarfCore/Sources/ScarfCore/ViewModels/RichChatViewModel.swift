// Gated on `canImport(SQLite3)` — `RichChatViewModel` reads message
// history from `HermesDataService`, which is SQLite-gated. iOS + macOS
// compile this unchanged; Linux CI skips it.
#if canImport(SQLite3)

import Foundation
import Observation

public enum ChatDisplayMode: String, CaseIterable {
    case terminal
    case richChat
}

public struct MessageGroup: Identifiable {
    public let id: Int
    public let userMessage: HermesMessage?
    public let assistantMessages: [HermesMessage]
    public let toolResults: [String: HermesMessage]

    public var allMessages: [HermesMessage] {
        var result: [HermesMessage] = []
        if let user = userMessage { result.append(user) }
        result.append(contentsOf: assistantMessages)
        return result
    }

    public var toolCallCount: Int {
        assistantMessages.reduce(0) { $0 + $1.toolCalls.count }
    }
}

@Observable
public final class RichChatViewModel {
    public let context: ServerContext
    private let dataService: HermesDataService

    public init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
        loadQuickCommands()
    }


    public var messages: [HermesMessage] = []
    public var currentSession: HermesSession?
    public var messageGroups: [MessageGroup] = []
    public var isAgentWorking = false
    public var pendingPermission: PendingPermission?
    /// Mutated to trigger a scroll-to-bottom in the message list.
    public var scrollTrigger = UUID()

    // Cumulative ACP token tracking (ACP returns tokens per prompt but DB has none)
    private(set) var acpInputTokens = 0
    private(set) var acpOutputTokens = 0
    private(set) var acpThoughtTokens = 0
    private(set) var acpCachedReadTokens = 0

    /// Slash commands advertised by the ACP server via `available_commands_update`.
    private(set) var acpCommands: [HermesSlashCommand] = []
    /// User-defined commands parsed from `config.yaml` `quick_commands`.
    private(set) var quickCommands: [HermesSlashCommand] = []

    /// Merged list, ACP-first, de-duplicated by name.
    public var availableCommands: [HermesSlashCommand] {
        let acpNames = Set(acpCommands.map(\.name))
        return acpCommands + quickCommands.filter { !acpNames.contains($0.name) }
    }

    public var supportsCompress: Bool { availableCommands.contains { $0.name == "compress" } }

    /// True when the menu carries more than just `/compress` — used to hide
    /// the dedicated compress button in favor of the full slash menu.
    public var hasBroaderCommandMenu: Bool { availableCommands.count > 1 }

    public var hasMessages: Bool { !messages.isEmpty }

    public func requestScrollToBottom() {
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

    public struct PendingPermission {
        let requestId: Int
        let title: String
        let kind: String
        let options: [(optionId: String, name: String)]
    }

    // MARK: - Reset

    public func reset() {
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
        acpCommands = []
        pendingPermission = nil
        loadQuickCommands()
    }

    public func setSessionId(_ id: String?) {
        sessionId = id
        lastKnownFingerprint = nil
    }

    public func cleanup() async {
        stopActivePolling()
        debounceTask?.cancel()
        await dataService.close()
    }

    /// Re-fetch session metadata from DB to pick up cost/token updates.
    public func refreshSessionFromDB() async {
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
    public func addUserMessage(text: String) {
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
        // User just submitted — jump to the bottom so they see their message
        // and the incoming response. `.defaultScrollAnchor(.bottom)` handles
        // slow streaming fine, but rapid responses (slash commands especially)
        // arrive faster than the anchor can track.
        requestScrollToBottom()
    }

    /// Process a streaming ACP event and update the message list.
    public func handleACPEvent(_ event: ACPEvent) {
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
        case .availableCommands(_, let commands):
            acpCommands = parseACPCommands(commands)
        case .unknown:
            break
        }
    }

    private func parseACPCommands(_ commands: [[String: Any]]) -> [HermesSlashCommand] {
        var result: [HermesSlashCommand] = []
        for entry in commands {
            guard let rawName = entry["name"] as? String else { continue }
            // Hermes sends names either as "compress" or "/compress"
            let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty else { continue }
            let description = (entry["description"] as? String) ?? ""
            var hint: String? = nil
            if let input = entry["input"] as? [String: Any],
               let h = input["hint"] as? String,
               !h.isEmpty {
                hint = h
            }
            result.append(HermesSlashCommand(
                name: name,
                description: description,
                argumentHint: hint,
                source: .acp
            ))
        }
        return result
    }

    /// Load `quick_commands` from `config.yaml` off the main actor and publish
    /// them as slash commands. Safe to call repeatedly — replaces the existing list.
    public func loadQuickCommands() {
        let ctx = context
        Task.detached { [weak self] in
            let loaded = QuickCommandsViewModel.loadQuickCommands(context: ctx)
            let mapped = loaded.map { qc -> HermesSlashCommand in
                let truncated = qc.command.count > 60
                    ? String(qc.command.prefix(60)) + "…"
                    : qc.command
                return HermesSlashCommand(
                    name: qc.name,
                    description: "Run: \(truncated)",
                    argumentHint: nil,
                    source: .quickCommand
                )
            }
            await MainActor.run { [weak self] in
                self?.quickCommands = mapped
            }
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
        // Detect a failed prompt that produced no assistant output — e.g.
        // Hermes returning `stopReason: "refusal"` when the session was
        // silently garbage-collected, or `"error"` when the ACP call itself
        // threw. Without surfacing this, the user sees their prompt sitting
        // alone under "Agent working…" that never completes with any text.
        let hadAssistantOutput = streamingAssistantText.isEmpty == false
            || messages.last?.isAssistant == true
        finalizeStreamingMessage()

        if !hadAssistantOutput, response.stopReason != "end_turn" {
            let reason: String
            switch response.stopReason {
            case "refusal":
                reason = "The agent refused to respond (the session may have been cleared on the server). Try starting a new session from the Session menu."
            case "error":
                reason = "The prompt failed — check the ACP error banner above for details."
            case "max_tokens":
                reason = "The response was cut off before the agent could produce any output (max_tokens reached before any tokens were emitted)."
            default:
                reason = "The prompt ended without a response (stopReason: \(response.stopReason))."
            }
            let id = nextLocalId
            nextLocalId -= 1
            messages.append(HermesMessage(
                id: id,
                sessionId: sessionId ?? "",
                role: "system",
                content: reason,
                toolCallId: nil,
                toolCalls: [],
                toolName: nil,
                timestamp: Date(),
                tokenCount: nil,
                finishReason: response.stopReason,
                reasoning: nil
            ))
        }

        // Accumulate token usage from this prompt
        acpInputTokens += response.inputTokens
        acpOutputTokens += response.outputTokens
        acpThoughtTokens += response.thoughtTokens
        acpCachedReadTokens += response.cachedReadTokens
        isAgentWorking = false
        buildMessageGroups()
        // Final position after the prompt settles. Catches fast responses
        // (slash commands, short replies) where `.defaultScrollAnchor(.bottom)`
        // didn't quite track the abrupt content growth.
        requestScrollToBottom()
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
    public func finalizeOnDisconnect() {
        finalizeStreamingMessage()
        isAgentWorking = false
        pendingPermission = nil
        buildMessageGroups()
    }

    /// Reconcile in-memory messages with DB state after a successful reconnection.
    /// Merges DB-persisted messages with any local-only messages (e.g., user messages
    /// that the ACP process may not have persisted before crashing).
    public func reconcileWithDB(sessionId: String) async {
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
    public func loadSessionHistory(sessionId: String, acpSessionId: String? = nil) async {
        self.sessionId = sessionId
        // Force a fresh snapshot pull on remote contexts. An earlier open()
        // would have cached a stale copy — on resume we need whatever
        // Hermes has actually persisted since then, or the resumed session
        // will show only history up to the moment the snapshot was taken.
        let opened = await dataService.refresh()
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

    public func markAgentWorking() {
        isAgentWorking = true
        userSendPending = true
        startActivePolling()
    }

    public func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await self?.refreshMessages()
        }
    }

    public func refreshMessages() async {
        // Polling tick (terminal mode): pull a fresh snapshot so remote
        // reflects Hermes writes since the last tick. On local this is a
        // cheap reopen of the live DB.
        let opened = await dataService.refresh()
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

#endif // canImport(SQLite3)
