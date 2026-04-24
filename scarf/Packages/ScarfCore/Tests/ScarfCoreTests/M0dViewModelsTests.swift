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

        let c: ConnectionStatusViewModel.Status = .degraded(reason: "x")
        let d: ConnectionStatusViewModel.Status = .degraded(reason: "x")
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
        let vm = RichChatViewModel(context: .local)
        #expect(vm.context.id == ServerContext.local.id)
        #expect(vm.messages.isEmpty)
        #expect(vm.isAgentWorking == false)
        #expect(vm.hasMessages == false)
        // supportsCompress defers to `availableCommands`, which is empty at
        // start → false.
        #expect(vm.supportsCompress == false)
        #expect(vm.hasBroaderCommandMenu == false)
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
