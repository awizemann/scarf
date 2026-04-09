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

    private var lastKnownCount = 0
    private var pollingTask: Task<Void, Never>?
    private var sessionId: String?

    func startPolling(sessionId: String) {
        self.sessionId = sessionId
        lastKnownCount = 0
        messages = []
        messageGroups = []
        isAgentWorking = false

        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMessages()
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isAgentWorking = false
    }

    func markAgentWorking() {
        isAgentWorking = true
    }

    func refreshMessages() async {
        guard let sessionId else { return }

        let opened = await dataService.open()
        guard opened else { return }

        let count = await dataService.fetchMessageCount(sessionId: sessionId)

        if count != lastKnownCount {
            let fetched = await dataService.fetchMessages(sessionId: sessionId)
            let session = await dataService.fetchSession(id: sessionId)
            lastKnownCount = count

            messages = fetched
            currentSession = session
            buildMessageGroups()

            if let last = fetched.last {
                if last.isAssistant && last.toolCalls.isEmpty {
                    isAgentWorking = false
                } else if last.isUser {
                    isAgentWorking = false
                }
            }
        } else {
            let session = await dataService.fetchSession(id: sessionId)
            currentSession = session
        }

        await dataService.close()
    }

    private func buildMessageGroups() {
        var groups: [MessageGroup] = []
        var currentUser: HermesMessage?
        var currentAssistant: [HermesMessage] = []
        var currentToolResults: [String: HermesMessage] = [:]

        func flushGroup() {
            if currentUser != nil || !currentAssistant.isEmpty {
                groups.append(MessageGroup(
                    id: currentUser?.id ?? currentAssistant.first?.id ?? groups.count,
                    userMessage: currentUser,
                    assistantMessages: currentAssistant,
                    toolResults: currentToolResults
                ))
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
