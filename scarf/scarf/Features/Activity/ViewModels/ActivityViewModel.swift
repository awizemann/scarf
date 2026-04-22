import Foundation
import ScarfCore

@Observable
final class ActivityViewModel {
    let context: ServerContext
    private let dataService: HermesDataService

    init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
    }


    var toolMessages: [HermesMessage] = []
    var filterKind: ToolKind?
    var filterSessionId: String?
    var selectedEntry: ActivityEntry?
    var toolResult: String?
    var sessionPreviews: [String: String] = [:]
    var isLoading = true

    var availableSessions: [(id: String, label: String)] {
        var seen = Set<String>()
        return toolMessages.compactMap { message in
            guard seen.insert(message.sessionId).inserted else { return nil }
            let label = sessionPreviews[message.sessionId] ?? message.sessionId
            return (id: message.sessionId, label: label)
        }
    }

    var filteredActivity: [ActivityEntry] {
        let entries = toolMessages.flatMap { message in
            message.toolCalls.map { call in
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
            let kindOk = filterKind == nil || entry.kind == filterKind
            let sessionOk = filterSessionId == nil || entry.sessionId == filterSessionId
            return kindOk && sessionOk
        }
    }

    func load() async {
        isLoading = true
        // refresh() = close + reopen, which forces a fresh snapshot pull on
        // remote contexts. Using open() here would short-circuit after the
        // first load and show stale data for the view's lifetime. The DB
        // stays open after load() returns so selectEntry() can read tool
        // results without re-opening — cleanup() closes on disappear.
        let opened = await dataService.refresh()
        guard opened else {
            isLoading = false
            return
        }
        toolMessages = await dataService.fetchRecentToolCalls(limit: 200)
        sessionPreviews = await dataService.fetchSessionPreviews(limit: 200)
        isLoading = false
    }

    func selectEntry(_ entry: ActivityEntry?) async {
        selectedEntry = entry
        if let entry {
            toolResult = await dataService.fetchToolResult(callId: entry.id)
        } else {
            toolResult = nil
        }
    }

    func cleanup() async {
        await dataService.close()
    }
}

struct ActivityEntry: Identifiable, Sendable {
    let id: String
    let sessionId: String
    let toolName: String
    let kind: ToolKind
    let summary: String
    let arguments: String
    let messageContent: String
    let timestamp: Date?

    var prettyArguments: String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return arguments
        }
        return str
    }
}
