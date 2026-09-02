// Gated on `canImport(SQLite3)` — `HermesDataService` only exists on
// Apple platforms (SQLite3 isn't a system module on Linux swift-corelibs).
#if canImport(SQLite3)

import Foundation
import Observation

@Observable
public final class ActivityViewModel {
    public let context: ServerContext
    private let dataService: HermesDataService

    public init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
    }


    public var toolMessages: [HermesMessage] = []
    public var filterKind: ToolKind?
    public var filterSessionId: String?
    public var selectedEntry: ActivityEntry?
    public var toolResult: String?
    public var sessionPreviews: [String: String] = [:]
    public var isLoading = true
    /// True while the Phase 2 background fill is paging through
    /// `hydrateAssistantToolCalls`. Drives a "Loading tool details…"
    /// pill in the page header so the user knows the placeholder
    /// rows on screen will fill in. v2.8.
    public var isHydratingToolCalls = false
    @ObservationIgnored
    private var hydrationTask: Task<Void, Never>?

    public var availableSessions: [(id: String, label: String)] {
        var seen = Set<String>()
        return toolMessages.compactMap { message in
            guard seen.insert(message.sessionId).inserted else { return nil }
            let label = sessionPreviews[message.sessionId] ?? message.sessionId
            return (id: message.sessionId, label: label)
        }
    }

    public var filteredActivity: [ActivityEntry] {
        let entries = toolMessages.flatMap { message -> [ActivityEntry] in
            // v2.8 — emit a single "Loading tool calls…" placeholder
            // entry per skeleton message (one whose tool_calls JSON
            // hasn't been hydrated yet). The user sees the timeline
            // shape immediately; real entries replace the placeholder
            // in-place when `hydrateAssistantToolCalls` returns.
            // Filtering still works (we apply the session filter
            // below) but kind filter hides placeholders since
            // .other is the placeholder's default kind.
            guard !message.toolCalls.isEmpty else {
                return [ActivityEntry(
                    id: "skeleton-\(message.id)",
                    sessionId: message.sessionId,
                    toolName: "Loading tool details…",
                    kind: .other,
                    summary: "",
                    arguments: "",
                    messageContent: "",
                    timestamp: message.timestamp,
                    isPlaceholder: true
                )]
            }
            return message.toolCalls.map { call in
                ActivityEntry(
                    id: call.callId,
                    sessionId: message.sessionId,
                    toolName: call.functionName,
                    kind: call.toolKind,
                    summary: call.argumentsSummary,
                    arguments: call.arguments,
                    messageContent: message.content,
                    timestamp: message.timestamp
                )
            }
        }
        return entries.filter { entry in
            // Placeholders bypass the kind filter so they don't all
            // disappear when the user picks a non-`.other` filter
            // chip — they still represent rows that may resolve to
            // the matching kind once hydrated.
            let kindOk = filterKind == nil || entry.isPlaceholder || entry.kind == filterKind
            let sessionOk = filterSessionId == nil || entry.sessionId == filterSessionId
            return kindOk && sessionOk
        }
    }

    /// Last load's transport-failure reason, if any. Activity surfaces
    /// this to the user instead of leaving the empty-state visible
    /// (which the user reads as "no activity" rather than "couldn't
    /// reach the host"). v2.8.
    public var loadError: String?

    /// Single in-flight load handle — the coalescing guard
    /// `DashboardViewModel` uses. `ActivityView` drives `load()` from
    /// `.task` and from the file watcher, and a watcher tick landing
    /// mid-load used to start a second pass that replaced `toolMessages`
    /// under the first one's hydration bookkeeping.
    @ObservationIgnored
    private var inFlightLoad: Task<Void, Never>?

    public func load() async {
        if let existing = inFlightLoad {
            await existing.value
            return
        }
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.loadImpl()
        }
        inFlightLoad = task
        await task.value
        inFlightLoad = nil
    }

    private func loadImpl() async {
        // Cancel any in-flight hydration from a prior load (e.g. a
        // file-watcher delta firing while the prior pass was still
        // paging). The new skeleton replaces the message set, so
        // hydrating against the old ids would just splice into rows
        // that no longer exist.
        hydrationTask?.cancel()
        hydrationTask = nil
        isHydratingToolCalls = false

        isLoading = true
        loadError = nil
        // refresh() = close + reopen, which forces a fresh snapshot pull on
        // remote contexts. Using open() here would short-circuit after the
        // first load and show stale data for the view's lifetime. The DB
        // stays open after load() returns so selectEntry() can read tool
        // results without re-opening — cleanup() closes on disappear.
        let opened = await dataService.refresh()
        guard opened else {
            loadError = "Couldn't reach \(context.displayName) — check the SSH connection and pull-to-refresh to retry."
            isLoading = false
            return
        }
        // v2.8 Phase L — skeleton-then-hydrate. Phase 1 metadata
        // fetch is bounded by 50 rows × ~50 bytes (id + session_id +
        // role + timestamp; tool_calls JSON is NULLed at the SQL
        // level) ≈ 3 KB on the wire regardless of how big the
        // underlying tool_calls blobs are. Comes back in
        // sub-second on healthy remotes; placeholder rows render
        // immediately. Phase 2 (paged hydrate) fills the real
        // tool details in via 5-id batches in the background.
        let outcome = await dataService.fetchRecentToolCallSkeleton(limit: 50)
        toolMessages = outcome.messages
        if let reason = outcome.transportError {
            loadError = "Couldn't load activity from \(context.displayName) — the connection timed out (\(reason)). Pull to refresh to retry."
            isLoading = false
            return
        }
        // Previews for exactly the sessions THESE rows belong to. The old
        // `fetchSessionPreviews(limit: 50)` answered a different question
        // — the 50 most recently started conversations — so the session
        // filter's labels were mostly raw UUIDs whenever the recent tool
        // calls came from older sessions, which is the normal case for a
        // long-running one.
        sessionPreviews = await dataService.fetchSessionPreviews(
            sessionIds: toolMessages.map(\.sessionId)
        )
        isLoading = false

        // Phase 2 — background hydrate. Mirrors the chat path's
        // `startToolHydration`. Newest-first (the splice happens in
        // batch order), cancellable via `cleanup()` / next `load()`.
        startToolCallHydration()
    }

    /// Phase 2 of the v2.8 Activity loader. Pages through
    /// `hydrateAssistantToolCalls` in batches of 5 ids and splices
    /// the parsed `[HermesToolCall]` arrays into the existing
    /// `toolMessages` skeleton. Once a message has its tool calls,
    /// `filteredActivity` swaps the placeholder entry for the real
    /// per-call entries on the next observation tick.
    private func startToolCallHydration() {
        let messageIds = toolMessages
            .filter { $0.toolCalls.isEmpty && $0.id > 0 }
            .map(\.id)
        guard !messageIds.isEmpty else {
            isHydratingToolCalls = false
            return
        }
        isHydratingToolCalls = true
        let dataService = self.dataService
        hydrationTask = Task { @MainActor [weak self] in
            defer { self?.isHydratingToolCalls = false }
            // Page in 5-id batches matching the chat path —
            // hydrateAssistantToolCalls already does the paging
            // internally; here we just hand it all the ids and
            // let it return whatever it could pull. Parent task
            // cancellation propagates down via the v2.8 SSH
            // cancellation handler we wired through SSHScriptRunner.
            let map = await dataService.hydrateAssistantToolCalls(messageIds: messageIds)
            guard let self else { return }
            if Task.isCancelled { return }
            if !map.isEmpty {
                self.toolMessages = self.toolMessages.map { msg in
                    guard msg.toolCalls.isEmpty, let calls = map[msg.id] else { return msg }
                    return msg.withToolCalls(calls)
                }
            }
        }
    }

    public func selectEntry(_ entry: ActivityEntry?) async {
        selectedEntry = entry
        if let entry {
            toolResult = await dataService.fetchToolResult(callId: entry.id)
        } else {
            toolResult = nil
        }
    }

    public func cleanup() async {
        hydrationTask?.cancel()
        hydrationTask = nil
        isHydratingToolCalls = false
        await dataService.close()
    }
}

public struct ActivityEntry: Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let toolName: String
    public let kind: ToolKind
    public let summary: String
    public let arguments: String
    public let messageContent: String
    public let timestamp: Date?
    /// True for skeleton entries emitted while the v2.8 two-phase
    /// loader is still hydrating tool_calls JSON for the underlying
    /// message. ActivityRow renders these as greyed "Loading…" rows
    /// so the user sees the timeline shape without the per-call
    /// detail. Splice happens in-place when hydration completes —
    /// the placeholder vanishes and the real entries take its slot.
    public let isPlaceholder: Bool

    public init(
        id: String,
        sessionId: String,
        toolName: String,
        kind: ToolKind,
        summary: String,
        arguments: String,
        messageContent: String,
        timestamp: Date?,
        isPlaceholder: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.toolName = toolName
        self.kind = kind
        self.summary = summary
        self.arguments = arguments
        self.messageContent = messageContent
        self.timestamp = timestamp
        self.isPlaceholder = isPlaceholder
    }

    public var prettyArguments: String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return arguments
        }
        return str
    }
}

#endif // canImport(SQLite3)
