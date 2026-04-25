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
        // Quick-commands load happens in `reset()`, which every chat-start
        // path calls before the user can interact (iOS: ChatController.start;
        // Mac: ChatViewModel.startNewSession/resumeSession/continueLastSession).
        // Calling it here too caused two parallel SFTP reads of config.yaml
        // on iOS chat startup.
    }


    public var messages: [HermesMessage] = []
    public var currentSession: HermesSession?
    public var messageGroups: [MessageGroup] = []
    /// True from the moment the user sends a prompt until the ACP
    /// `promptComplete` event arrives. Covers the whole round-trip
    /// including auxiliary post-processing (title generation, usage
    /// accounting, etc.). UIs should prefer the `isGenerating` /
    /// `isPostProcessing` pair below — they distinguish "agent is
    /// thinking about your message" from "agent is closing out" and
    /// avoid the misleading "spinner after the reply has landed" UX
    /// we saw in pass-1 (M7 #4).
    public var isAgentWorking = false
    public var pendingPermission: PendingPermission?
    /// Mutated to trigger a scroll-to-bottom in the message list.
    public var scrollTrigger = UUID()

    /// True while the assistant hasn't yet emitted a complete reply
    /// for the latest user prompt. Renders the prominent "Agent is
    /// thinking…" indicator in the chat. Flips false as soon as we've
    /// finalized an assistant message with content — even if the ACP
    /// `promptComplete` event hasn't arrived yet (Hermes auxiliary
    /// work like title generation delays that event).
    public var isGenerating: Bool {
        isAgentWorking && !isPostProcessing
    }

    /// True while ACP hasn't closed out the prompt but the assistant
    /// has already finalized a reply the user can see. Renders a
    /// subtle "Finishing up…" pill instead of the prominent spinner.
    /// Avoids the pass-1 M7 #4 UX where users stared at "Agent is
    /// working…" forever because `promptComplete` was held up by
    /// auxiliary server-side work.
    public var isPostProcessing: Bool {
        guard isAgentWorking else { return false }
        guard let last = messages.last else { return false }
        return last.isAssistant && !last.content.isEmpty
    }

    // MARK: - Error banner state (shared macOS + iOS)

    /// Human-readable error message shown in the chat's error banner.
    /// Nil = no active error. Populated from `recordACPFailure(...)`
    /// (throws from ACP ops) and from `handlePromptComplete` when the
    /// response's `stopReason` is `"error"` (non-retryable provider
    /// failures like Nous Portal HTTP 404 for an unknown model —
    /// pass-1 M7 #2).
    public var acpError: String?

    /// Short hint derived from the error + stderr tail (e.g.
    /// "set ANTHROPIC_API_KEY" or "pick a different model — this
    /// one isn't in the provider's catalog"). Shown above the raw
    /// error in the banner when present. Classified by
    /// `ACPErrorHint.classify(errorMessage:stderrTail:)`.
    public var acpErrorHint: String?

    /// Tail of stderr captured from `hermes acp` at the time of the
    /// failure. Shown in a collapsible "Show details" section so
    /// users can copy-paste the raw output into a bug report.
    public var acpErrorDetails: String?

    /// Optional stderr-tail provider the controller can hook up when it
    /// creates the ACPClient. Used by `handlePromptComplete` to enrich
    /// the error banner on non-retryable stopReasons. The closure is
    /// called async so callers can await `ACPClient.recentStderr`
    /// without blocking the MainActor. Defaults to nil (no stderr in
    /// banner, just the hint fallback).
    public var acpStderrProvider: (@Sendable () async -> String)?

    /// Clear the error triplet. Call on session reset / new chat /
    /// successful new prompt so stale errors don't linger.
    public func clearACPErrorState() {
        acpError = nil
        acpErrorHint = nil
        acpErrorDetails = nil
    }

    /// Populate the error triplet from a thrown Error + the ACPClient
    /// we can query for recent stderr. Safe to call from anywhere
    /// that catches an ACP op failure.
    ///
    /// Swallows `CancellationError` silently — it's how Swift's task
    /// tree signals cooperative cleanup (e.g. when startResuming
    /// tears down a prior live session via stop(), the event-task
    /// awaits throw as they unwind). That's expected plumbing, not a
    /// user-visible failure — showing "The operation couldn't be
    /// completed (Swift.CancellationError)" in the chat banner would
    /// alarm users whose session actually loaded fine. Pass-2 UX fix.
    public func recordACPFailure(_ error: Error, client: ACPClient?) async {
        if error is CancellationError { return }
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled {
            return
        }
        let msg = error.localizedDescription
        let stderrTail = await client?.recentStderr ?? ""
        let hint = ACPErrorHint.classify(errorMessage: msg, stderrTail: stderrTail)
        acpError = msg
        acpErrorHint = hint
        acpErrorDetails = stderrTail.isEmpty ? nil : stderrTail
    }

    /// Populate the error triplet when `handlePromptComplete` sees a
    /// non-`end_turn` stopReason (i.e. the provider rejected the
    /// prompt and Hermes correctly surfaced it via ACP). The hint
    /// classifier reads the stderr tail; for stopReason="error" cases
    /// the tail typically contains the provider's HTTP status + reason.
    public func recordPromptStopFailure(stopReason: String, client: ACPClient?) async {
        let msg = "Prompt ended without a response (stopReason: \(stopReason))."
        let stderrTail = await client?.recentStderr ?? ""
        let hint = ACPErrorHint.classify(errorMessage: msg, stderrTail: stderrTail)
            ?? Self.fallbackHint(for: stopReason)
        acpError = msg
        acpErrorHint = hint
        acpErrorDetails = stderrTail.isEmpty ? nil : stderrTail
    }

    /// Same as `recordPromptStopFailure` but pulls stderr from the
    /// `acpStderrProvider` closure the controller registered. Used by
    /// `handlePromptComplete` where we don't have direct ACPClient
    /// access.
    private func recordPromptStopFailureUsingProvider(stopReason: String) async {
        let msg = "Prompt ended without a response (stopReason: \(stopReason))."
        let stderrTail = await acpStderrProvider?() ?? ""
        let hint = ACPErrorHint.classify(errorMessage: msg, stderrTail: stderrTail)
            ?? Self.fallbackHint(for: stopReason)
        acpError = msg
        acpErrorHint = hint
        acpErrorDetails = stderrTail.isEmpty ? nil : stderrTail
    }

    private static func fallbackHint(for stopReason: String) -> String? {
        switch stopReason {
        case "error":    return "The provider returned an error. Check the details below — often the configured model isn't in the provider's catalog."
        case "refusal":  return "The session may have been cleared on the server. Start a new chat to continue."
        case "max_tokens": return "The response was cut off before any content was produced. Try a shorter prompt or raise the max-tokens limit in Settings."
        default: return nil
        }
    }

    // Cumulative ACP token tracking (ACP returns tokens per prompt but DB has none)
    public private(set) var acpInputTokens = 0
    public private(set) var acpOutputTokens = 0
    public private(set) var acpThoughtTokens = 0
    public private(set) var acpCachedReadTokens = 0

    /// Slash commands advertised by the ACP server via `available_commands_update`.
    public private(set) var acpCommands: [HermesSlashCommand] = []
    /// User-defined commands parsed from `config.yaml` `quick_commands`.
    public private(set) var quickCommands: [HermesSlashCommand] = []
    /// Project-scoped, Scarf-managed commands at
    /// `<project>/.scarf/slash-commands/<name>.md`. Loaded by
    /// `loadProjectScopedCommands(at:)` when a project chat starts; cleared
    /// on `reset()`. The full `ProjectSlashCommand` payload is kept here
    /// (not just the surface metadata) because expansion happens in
    /// `ChatViewModel.sendPrompt` and needs the body + model override.
    public private(set) var projectScopedCommands: [ProjectSlashCommand] = []

    /// Hardcoded ACP-native commands that don't interrupt the current
    /// turn. v2.5 ships `/steer` as the flagship — applies user
    /// guidance after the next tool call without aborting. Fronted by
    /// Hermes v2026.4.23+ but listed here unconditionally so older
    /// hosts that don't advertise it still surface the trigger; the
    /// agent will respond appropriately or no-op gracefully.
    public static let nonInterruptiveCommands: [HermesSlashCommand] = [
        HermesSlashCommand(
            name: "steer",
            description: "Nudge the agent mid-run (applies after the next tool call)",
            argumentHint: "<guidance>",
            source: .acpNonInterruptive
        )
    ]

    /// Transient hint shown above the composer, e.g. "Guidance queued —
    /// applies after the next tool call." for `/steer`. The chat view
    /// auto-clears it after a short delay (handled in the view); the
    /// model just owns the value.
    public var transientHint: String?

    /// Wall-clock start time of the current agent turn. Set when a fresh
    /// user prompt enters an idle session (not for `/steer` which sends
    /// during an active turn); cleared on `finalizeStreamingMessage`
    /// after the duration is captured. Used to compute the per-turn
    /// stopwatch displayed below assistant bubbles. v2.5.
    private var currentTurnStart: Date?

    /// Wall-clock duration of completed assistant turns, keyed by the
    /// finalised assistant message's local id. Render the value in the
    /// chat UI as a small "4.2s" pill below the bubble. Map grows
    /// alongside the message list; cleared on `reset()`.
    public private(set) var turnDurations: [Int: TimeInterval] = [:]

    /// Look up a completed turn's duration. Nil for the streaming
    /// placeholder (still in flight) and for any assistant message
    /// that pre-dates the v2.5 stopwatch (e.g., loaded from state.db
    /// for a resumed session).
    public func turnDuration(forMessageId id: Int) -> TimeInterval? {
        turnDurations[id]
    }

    /// Format a duration as a compact stopwatch label used by the chat
    /// UI: `0.8s`, `4.2s`, `1m 12s`. Sub-second values render with one
    /// decimal place; ≥60s switches to `<m>m <s>s`.
    public static func formatTurnDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return "\(minutes)m \(remainder)s"
    }

    /// Merged slash-menu list. Precedence: **ACP > project-scoped >
    /// quick_commands** (most specific source wins). De-duplicated by name.
    /// Non-interruptive ACP commands (`/steer`) are always appended at
    /// the end so they don't crowd the more frequently-used options.
    public var availableCommands: [HermesSlashCommand] {
        let acpNames = Set(acpCommands.map(\.name))
        let projectAsHermes: [HermesSlashCommand] = projectScopedCommands
            .filter { !acpNames.contains($0.name) }
            .map { cmd in
                HermesSlashCommand(
                    name: cmd.name,
                    description: cmd.description,
                    argumentHint: cmd.argumentHint,
                    source: .projectScoped
                )
            }
        let projectNames = Set(projectAsHermes.map(\.name))
        let quicks = quickCommands.filter {
            !acpNames.contains($0.name) && !projectNames.contains($0.name)
        }
        let occupied = acpNames.union(projectNames).union(Set(quicks.map(\.name)))
        let nonInterruptive = Self.nonInterruptiveCommands.filter {
            !occupied.contains($0.name)
        }
        return acpCommands + projectAsHermes + quicks + nonInterruptive
    }

    /// True when `text` is a non-interruptive command that should NOT
    /// flip `isAgentWorking` to true on send. Used by the Mac/iOS chat
    /// view models to skip the "agent working" overlay change for
    /// `/steer` (the agent's still on its current turn).
    public func isNonInterruptiveSlash(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let withoutSlash = trimmed.dropFirst()
        let name: String
        if let space = withoutSlash.firstIndex(of: " ") {
            name = String(withoutSlash[..<space])
        } else {
            name = String(withoutSlash)
        }
        return Self.nonInterruptiveCommands.contains { $0.name == name }
    }

    /// Look up the full project-scoped command payload by slash trigger.
    /// `ChatViewModel.sendPrompt` calls this when the input matches a
    /// `.projectScoped` source and needs the body for client-side
    /// expansion.
    public func projectScopedCommand(named name: String) -> ProjectSlashCommand? {
        projectScopedCommands.first { $0.name == name }
    }

    public var supportsCompress: Bool { availableCommands.contains { $0.name == "compress" } }

    /// True when the menu carries more than just `/compress` — used to hide
    /// the dedicated compress button in favor of the full slash menu.
    public var hasBroaderCommandMenu: Bool { availableCommands.count > 1 }

    public var hasMessages: Bool { !messages.isEmpty }

    public func requestScrollToBottom() {
        scrollTrigger = UUID()
    }

    public private(set) var sessionId: String?
    /// The original CLI session ID when resuming a CLI session via ACP.
    /// Used to combine old CLI messages with new ACP messages.
    public private(set) var originSessionId: String?
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
        public let requestId: Int
        public let title: String
        public let kind: String
        public let options: [(optionId: String, name: String)]

        public init(
            requestId: Int,
            title: String,
            kind: String,
            options: [(optionId: String, name: String)]
        ) {
            self.requestId = requestId
            self.title = title
            self.kind = kind
            self.options = options
        }
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
        acpError = nil
        acpErrorHint = nil
        acpErrorDetails = nil
        acpCachedReadTokens = 0
        acpCommands = []
        projectScopedCommands = []
        currentTurnStart = nil
        turnDurations = [:]
        transientHint = nil
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
        // Fresh prompt → clear any stale error banner from a prior
        // failed attempt so we don't show "old error" + "still thinking…"
        // simultaneously. Matches the Mac ChatViewModel pattern.
        clearACPErrorState()
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
        // Per-turn stopwatch (v2.5): record the start time only when
        // we're entering a fresh agent turn. /steer-style mid-run sends
        // arrive while isAgentWorking is already true; preserve the
        // existing start so the captured duration reflects the FULL
        // turn (initial prompt → final reply), not just the time since
        // the user nudged.
        if !isAgentWorking {
            currentTurnStart = Date()
        }
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
            let loaded = Self.loadQuickCommands(context: ctx)
            let mapped = loaded.map { (name, command) -> HermesSlashCommand in
                let truncated = command.count > 60
                    ? String(command.prefix(60)) + "…"
                    : command
                return HermesSlashCommand(
                    name: name,
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

    /// Load project-scoped slash commands from
    /// `<projectPath>/.scarf/slash-commands/` off the main actor and
    /// publish them. Safe to call repeatedly — replaces the existing
    /// list (e.g., when the user adds / edits / deletes commands).
    /// Pass `nil` to clear (e.g., on session de-attribution from a
    /// project, or quick-chat sessions).
    public func loadProjectScopedCommands(at projectPath: String?) {
        guard let projectPath else {
            projectScopedCommands = []
            return
        }
        let ctx = context
        Task.detached { [weak self] in
            let svc = ProjectSlashCommandService(context: ctx)
            let loaded = svc.loadCommands(at: projectPath)
            await MainActor.run { [weak self] in
                self?.projectScopedCommands = loaded
            }
        }
    }

    /// Parse `quick_commands` from `<context>/config.yaml`. Returns
    /// `[(name, command)]` for every well-formed `type: exec` entry.
    /// Mac-side `QuickCommandsViewModel` uses a richer model + adds
    /// an `isDangerous` check; here we only need the slash-menu
    /// projection, so we keep the parser minimal and ScarfCore-local.
    nonisolated static func loadQuickCommands(context: ServerContext) -> [(name: String, command: String)] {
        guard let yaml = context.readText(context.paths.configYAML) else { return [] }
        let parsed = HermesYAML.parseNestedYAML(yaml)
        var byName: [String: (type: String, command: String)] = [:]
        for (key, value) in parsed.values where key.hasPrefix("quick_commands.") {
            let parts = key.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let name = String(parts[1])
            let field = String(parts[2])
            var existing = byName[name] ?? (type: "exec", command: "")
            let stripped = HermesYAML.stripYAMLQuotes(value)
            if field == "type" { existing.type = stripped }
            if field == "command" { existing.command = stripped }
            byName[name] = existing
        }
        return byName.compactMap { (name, entry) in
            guard entry.type == "exec", !entry.command.isEmpty else { return nil }
            return (name: name, command: entry.command)
        }
        .sorted { $0.name < $1.name }
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
            arguments: call.argumentsJSON,
            startedAt: Date()
        )
        streamingToolCalls.append(toolCall)
        upsertStreamingMessage()
    }

    private func handleToolCallComplete(_ update: ACPToolCallUpdateEvent) {
        // Populate live telemetry on the matching streaming call BEFORE
        // finalizing — once finalize runs, streamingToolCalls is cleared
        // and the call is locked into the parent HermesMessage's `let
        // toolCalls`. Mutating here lets `finalizeStreamingMessage()`
        // promote a HermesToolCall that already carries duration +
        // exitCode for the inspector to render. No-op for sessions
        // loaded from `state.db` (no live event ever fires).
        if let idx = streamingToolCalls.firstIndex(where: { $0.callId == update.toolCallId }) {
            let started = streamingToolCalls[idx].startedAt
            if let started {
                streamingToolCalls[idx].duration = Date().timeIntervalSince(started)
            }
            streamingToolCalls[idx].exitCode = Self.exitCode(forStatus: update.status)
        }

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

    /// Derive a synthetic exit code from the ACP update event's status
    /// string. Hermes reports `completed`/`error`/`failed`/`canceled`;
    /// we collapse to 0 for success, 1 for known-failure variants, nil
    /// for anything else (so the inspector renders "—" rather than
    /// fabricating a value).
    private static func exitCode(forStatus status: String) -> Int? {
        switch status.lowercased() {
        case "completed", "success", "ok": return 0
        case "error", "failed", "canceled", "cancelled": return 1
        default: return nil
        }
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
            // Pass-1 M7 #2: surface the same failure as a top-of-chat
            // error banner with the stderr tail, so users don't have
            // to rely solely on the system-message to understand why
            // nothing happened. The controller registers
            // `acpStderrProvider`; if absent, the banner still shows
            // with the hint fallback.
            Task { await self.recordPromptStopFailureUsingProvider(stopReason: response.stopReason) }
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
            // Capture per-turn duration so the chat UI can render the
            // stopwatch pill (v2.5). Skips assistants we don't have a
            // start time for — e.g., the .promptComplete fired but the
            // turn began before this VM was constructed (shouldn't
            // happen in practice but guards an edge case).
            if let start = currentTurnStart {
                turnDurations[id] = Date().timeIntervalSince(start)
                currentTurnStart = nil
            }
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
