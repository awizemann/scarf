import Foundation

@Observable
final class ActivityViewModel {
    private let dataService = HermesDataService()

    var toolMessages: [HermesMessage] = []
    var filterKind: ToolKind?
    var selectedEntry: ActivityEntry?
    var isLoading = true

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
        if let filterKind {
            return entries.filter { $0.kind == filterKind }
        }
        return entries
    }

    func load() async {
        isLoading = true
        let opened = await dataService.open()
        guard opened else {
            isLoading = false
            return
        }
        toolMessages = await dataService.fetchRecentToolCalls(limit: 200)
        isLoading = false
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
