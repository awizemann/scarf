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

    public var availableSessions: [(id: String, label: String)] {
        var seen = Set<String>()
        return toolMessages.compactMap { message in
            guard seen.insert(message.sessionId).inserted else { return nil }
            let label = sessionPreviews[message.sessionId] ?? message.sessionId
            return (id: message.sessionId, label: label)
        }
    }

    public var filteredActivity: [ActivityEntry] {
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

    public func load() async {
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

    public func selectEntry(_ entry: ActivityEntry?) async {
        selectedEntry = entry
        if let entry {
            toolResult = await dataService.fetchToolResult(callId: entry.id)
        } else {
            toolResult = nil
        }
    }

    public func cleanup() async {
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

    public init(
        id: String,
        sessionId: String,
        toolName: String,
        kind: ToolKind,
        summary: String,
        arguments: String,
        messageContent: String,
        timestamp: Date?
    ) {
        self.id = id
        self.sessionId = sessionId
        self.toolName = toolName
        self.kind = kind
        self.summary = summary
        self.arguments = arguments
        self.messageContent = messageContent
        self.timestamp = timestamp
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
