import Testing
import Foundation
@testable import ScarfCore

/// Exercises the portable ViewModels moved in M0d.
///
/// Three of the six VMs (`ActivityViewModel`, `InsightsViewModel`,
/// `RichChatViewModel`) are gated on `#if canImport(SQLite3)` because they
/// depend on `HermesDataService`. Tests for those are inside the same gate
/// so Linux CI compiles without them; Apple-target CI covers them fully.
@Suite struct M0dViewModelsTests {

    // MARK: - ConnectionStatusViewModel (no SQLite3 dep)

    @Test @MainActor func connectionStatusLocalContextIsAlwaysConnected() {
        let vm = ConnectionStatusViewModel(context: .local)
        #expect(vm.status == .connected)
        #expect(vm.lastSuccess != nil)
        #expect(vm.context.id == ServerContext.local.id)
    }

    @Test @MainActor func connectionStatusRemoteStartsIdle() {
        let ctx = ServerContext(
            id: UUID(),
            displayName: "r",
            kind: .ssh(SSHConfig(host: "nonexistent.invalid"))
        )
        let vm = ConnectionStatusViewModel(context: ctx)
        #expect(vm.status == .idle)
        #expect(vm.lastSuccess == nil)
    }

    @Test func connectionStatusEquatable() {
        // The pill's Equatable conformance on Status drives UI re-render
        // suppression. Pin the expected behaviour.
        let a: ConnectionStatusViewModel.Status = .connected
        let b: ConnectionStatusViewModel.Status = .connected
        #expect(a == b)

        let c: ConnectionStatusViewModel.Status = .degraded(reason: "x", hint: "y", cause: .unknown)
        let d: ConnectionStatusViewModel.Status = .degraded(reason: "x", hint: "y", cause: .unknown)
        #expect(c == d)

        let e: ConnectionStatusViewModel.Status = .idle
        #expect(a != c)
        #expect(a != e)
    }

    // MARK: - LogsViewModel (HermesLogService dep — portable)

    @Test @MainActor func logsViewModelInitsWithLocalContext() {
        let vm = LogsViewModel(context: .local)
        #expect(vm.context.id == ServerContext.local.id)
        #expect(vm.entries.isEmpty)
        #expect(vm.selectedLogFile == .agent)
        #expect(vm.filterLevel == nil)
        #expect(vm.selectedComponent == .all)
        #expect(vm.searchText == "")
    }

    @Test @MainActor func logsViewModelFilteredEntriesByLevel() {
        let vm = LogsViewModel(context: .local)
        vm.entries = [
            LogEntry(id: 1, timestamp: "t", level: .info, sessionId: nil, logger: "a", message: "m", raw: "r"),
            LogEntry(id: 2, timestamp: "t", level: .error, sessionId: nil, logger: "a", message: "boom", raw: "r"),
            LogEntry(id: 3, timestamp: "t", level: .debug, sessionId: nil, logger: "a", message: "d", raw: "r"),
        ]
        vm.filterLevel = .error
        let filtered = vm.filteredEntries
        #expect(filtered.count == 1)
        #expect(filtered.first?.level == .error)
    }

    @Test @MainActor func logsViewModelFilteredEntriesBySearch() {
        let vm = LogsViewModel(context: .local)
        vm.entries = [
            LogEntry(id: 1, timestamp: "t", level: .info, sessionId: nil, logger: "a", message: "connecting to db", raw: "connecting to db"),
            LogEntry(id: 2, timestamp: "t", level: .info, sessionId: nil, logger: "a", message: "starting agent", raw: "starting agent"),
        ]
        vm.searchText = "agent"
        #expect(vm.filteredEntries.count == 1)
        #expect(vm.filteredEntries.first?.message.contains("agent") == true)
    }

    @Test @MainActor func logsViewModelFilteredEntriesByComponent() {
        let vm = LogsViewModel(context: .local)
        vm.entries = [
            LogEntry(id: 1, timestamp: "t", level: .info, sessionId: nil, logger: "gateway.main",  message: "up", raw: "r"),
            LogEntry(id: 2, timestamp: "t", level: .info, sessionId: nil, logger: "agent.loop",    message: "tick", raw: "r"),
            LogEntry(id: 3, timestamp: "t", level: .info, sessionId: nil, logger: "tools.compile", message: "done", raw: "r"),
        ]
        vm.selectedComponent = .gateway
        let gateway = vm.filteredEntries
        #expect(gateway.count == 1)
        #expect(gateway.first?.logger == "gateway.main")

        vm.selectedComponent = .all
        #expect(vm.filteredEntries.count == 3)
    }

    @Test func logsViewModelEnumsIdentifiable() {
        for f in LogsViewModel.LogFile.allCases {
            #expect(f.id == f.rawValue)
        }
        for c in LogsViewModel.LogComponent.allCases {
            #expect(c.id == c.rawValue)
        }
        #expect(LogsViewModel.LogComponent.all.loggerPrefix == nil)
        #expect(LogsViewModel.LogComponent.gateway.loggerPrefix == "gateway")
    }

    // MARK: - ProjectsViewModel (ProjectDashboardService dep — portable)

    @Test @MainActor func projectsViewModelInits() {
        let vm = ProjectsViewModel(context: .local)
        #expect(vm.context.id == ServerContext.local.id)
    }

    // MARK: - Activity / Insights / RichChat — only on Apple targets

    #if canImport(SQLite3)

    @Test @MainActor func activityViewModelInits() {
        let vm = ActivityViewModel(context: .local)
        #expect(vm.context.id == ServerContext.local.id)
        #expect(vm.toolMessages.isEmpty)
    }

    @Test @MainActor func insightsViewModelInits() {
        let vm = InsightsViewModel(context: .local)
        #expect(vm.context.id == ServerContext.local.id)
        #expect(vm.period == .month)
        #expect(vm.isLoading == true)
    }

    @Test func insightsPeriodSinceDateIsSane() {
        let now = Date()
        let week = InsightsPeriod.week.sinceDate
        let month = InsightsPeriod.month.sinceDate
        let quarter = InsightsPeriod.quarter.sinceDate
        let all = InsightsPeriod.all.sinceDate
        // Ordering: all < quarter < month < week < now.
        #expect(all < quarter)
        #expect(quarter < month)
        #expect(month < week)
        #expect(week < now)
    }

    @Test func chatDisplayModeCases() {
        #expect(ChatDisplayMode.allCases.count == 2)
        #expect(ChatDisplayMode.allCases.contains(.terminal))
        #expect(ChatDisplayMode.allCases.contains(.richChat))
    }

    @Test @MainActor func richChatViewModelInitsEmpty() {
        // Inject a temp home so nothing in the developer's real ~/.hermes
        // can leak into this init (t-aud25). The dir need not exist —
        // `RichChatViewModel.init` loads nothing from disk; this just
        // guarantees machine-independence if an init-time read is ever added.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-richchat-test-\(UUID().uuidString)", isDirectory: true)
        let vm = RichChatViewModel(context: .local(home: home))
        #expect(vm.context.id == ServerContext.local.id)
        #expect(vm.messages.isEmpty)
        #expect(vm.isAgentWorking == false)
        #expect(vm.hasMessages == false)
        // Nothing is loaded from a session or from disk at init: every
        // session/ACP/project/global/quick command source is empty. We
        // assert those *loaded* sources rather than the derived menu size,
        // because `availableCommands` is NOT empty at start — it always
        // surfaces the static `/new` + `/steer` fallbacks (the latter is
        // unconditionally visible pre-session, see `availableCommands`).
        #expect(vm.acpCommands.isEmpty)
        #expect(vm.projectScopedCommands.isEmpty)
        #expect(vm.globalScopedCommands.isEmpty)
        #expect(vm.quickCommands.isEmpty)
        // `/compress` only appears via an active session's ACP advertisement,
        // so a fresh VM never reports it.
        #expect(vm.supportsCompress == false)
        // v0.13: compression count starts at 0 so the SessionInfoBar chip
        // stays hidden on fresh sessions.
        #expect(vm.acpCompressionCount == 0)
    }

    @Test @MainActor func richChatTracksCompressionCountFromPromptResults() {
        let vm = RichChatViewModel(context: .local)
        // The pre-engagement replay guard (TestFlight AFI4q5) only
        // drops streamed CONTENT events (chunks / tool calls) —
        // `.promptComplete` deliberately bypasses it (S2, 2026-07-13,
        // t-60f2f152) because it carries turn accounting and the
        // `isAgentWorking` clear. Attach + engage the session anyway
        // so this test mirrors the realistic send flow (session set →
        // user echo → completion) rather than leaning on the bypass.
        vm.setSessionId("s")
        vm.addUserMessage(text: "kick off")
        let response = ACPPromptResult(
            stopReason: "end_turn",
            inputTokens: 100, outputTokens: 50,
            thoughtTokens: 20, cachedReadTokens: 10,
            compressionCount: 3
        )
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: response))
        #expect(vm.acpCompressionCount == 3)

        // Subsequent prompts overwrite (with a max guard) — the server
        // emits a session-wide running total, not a per-prompt delta.
        let next = ACPPromptResult(
            stopReason: "end_turn",
            inputTokens: 0, outputTokens: 0,
            thoughtTokens: 0, cachedReadTokens: 0,
            compressionCount: 5
        )
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: next))
        #expect(vm.acpCompressionCount == 5)

        // A pre-v0.13 host mid-session emits 0; the max-guard keeps the
        // last real value rather than snapping back.
        let stale = ACPPromptResult(
            stopReason: "end_turn",
            inputTokens: 0, outputTokens: 0,
            thoughtTokens: 0, cachedReadTokens: 0,
            compressionCount: 0
        )
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: stale))
        #expect(vm.acpCompressionCount == 5)

        // reset() clears the counter so a fresh session starts clean.
        vm.reset()
        #expect(vm.acpCompressionCount == 0)
    }

    // MARK: - Cross-session event guard
    //
    // Regression coverage for TestFlight feedback AFI4q5 (2026-05-10):
    // "Initial chat message shows from another chat." Cause: events for
    // a prior session landed in the VM after `setSessionId` flipped to
    // the new session but before the user engaged, then surfaced once
    // the engagement gate opened. Guard added in
    // `RichChatViewModel.handleACPEvent`.

    @Test @MainActor func handleACPEventDropsContentForStaleSession() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("new")
        // Open the engagement gate so the cross-session guard is the
        // ONLY thing that could drop the event — otherwise we'd be
        // testing the pre-engagement gate.
        vm.addUserMessage(text: "hi")
        let baseCount = vm.messages.count

        // A chunk that belongs to a stale session must not produce
        // a streaming assistant bubble in the active session.
        vm.handleACPEvent(.messageChunk(sessionId: "old", text: "stale text"))
        #expect(vm.messages.count == baseCount)
        #expect(!vm.messages.contains { $0.content.contains("stale text") })

        // Same-session chunk still flows through — produces a
        // streaming assistant bubble.
        vm.handleACPEvent(.messageChunk(sessionId: "new", text: "fresh "))
        #expect(vm.messages.contains { $0.content == "fresh " && $0.isAssistant })
    }

    @Test @MainActor func handleACPEventAllowsConnectionLostFromAnyOrigin() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("new")
        vm.addUserMessage(text: "hi")
        let baseCount = vm.messages.count
        // `.connectionLost` carries no session id and must always pass
        // — it's a transport signal, not session-scoped. The VM
        // appends a system message describing the failure.
        vm.handleACPEvent(.connectionLost(reason: "socket gone"))
        #expect(vm.messages.count > baseCount)
        #expect(vm.messages.contains { $0.content.contains("socket gone") })
    }

    @Test @MainActor func handleACPEventAcceptsEventsBeforeSessionAttached() {
        // Before `setSessionId` lands the VM's sessionId is nil. We
        // intentionally let those events through — the engagement gate
        // already prevents content-event spam at that point, and
        // strict-equality dropping would block legitimate
        // `availableCommands` arriving on `session/new`.
        let vm = RichChatViewModel(context: .local)
        let beforeAcp = vm.acpCommands.count
        vm.handleACPEvent(
            .availableCommands(sessionId: "incoming", commands: [
                ["name": "clear", "description": "Clear chat"]
            ])
        )
        #expect(vm.acpCommands.count == beforeAcp + 1)
    }

    @Test @MainActor func messageGroupDerivedProperties() {
        let userMsg = HermesMessage(
            id: 1, sessionId: "s", role: "user", content: "hi",
            toolCallId: nil, toolCalls: [], toolName: nil,
            timestamp: nil, tokenCount: nil, finishReason: nil, reasoning: nil
        )
        let toolCall = HermesToolCall(callId: "c1", functionName: "read_file", arguments: "{}")
        let asstMsg = HermesMessage(
            id: 2, sessionId: "s", role: "assistant", content: "here",
            toolCallId: nil, toolCalls: [toolCall], toolName: nil,
            timestamp: nil, tokenCount: nil, finishReason: nil, reasoning: nil
        )
        let group = MessageGroup(
            id: 1, userMessage: userMsg, assistantMessages: [asstMsg], toolResults: [:]
        )
        #expect(group.allMessages.count == 2)
        #expect(group.toolCallCount == 1)

        let emptyGroup = MessageGroup(id: 0, userMessage: nil, assistantMessages: [], toolResults: [:])
        #expect(emptyGroup.allMessages.isEmpty)
        #expect(emptyGroup.toolCallCount == 0)
    }

    #endif // canImport(SQLite3)
}
