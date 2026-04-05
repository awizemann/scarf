import Foundation
import AppKit
import UniformTypeIdentifiers

struct SessionStoreStats {
    let totalSessions: Int
    let totalMessages: Int
    let databaseSize: String
    let platformCounts: [(platform: String, count: Int)]
}

@Observable
final class SessionsViewModel {
    private let dataService = HermesDataService()

    var sessions: [HermesSession] = []
    var sessionPreviews: [String: String] = [:]
    var selectedSession: HermesSession?
    var messages: [HermesMessage] = []
    var searchText = ""
    var searchResults: [HermesMessage] = []
    var isSearching = false
    var storeStats: SessionStoreStats?

    var renameSessionId: String?
    var renameText = ""
    var showRenameSheet = false
    var showDeleteConfirmation = false
    var deleteSessionId: String?

    func load() async {
        let opened = await dataService.open()
        guard opened else { return }
        sessions = await dataService.fetchSessions(limit: 500)
        sessionPreviews = await dataService.fetchSessionPreviews(limit: 500)
        computeStats()
    }

    func previewFor(_ session: HermesSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if let preview = sessionPreviews[session.id], !preview.isEmpty { return preview }
        return session.id
    }

    func selectSession(_ session: HermesSession) async {
        selectedSession = session
        messages = await dataService.fetchMessages(sessionId: session.id)
    }

    func selectSessionById(_ id: String) async {
        if let session = sessions.first(where: { $0.id == id }) {
            await selectSession(session)
        }
    }

    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchResults = await dataService.searchMessages(query: query)
    }

    func cleanup() async {
        await dataService.close()
    }

    // MARK: - Session Actions

    func beginRename(_ session: HermesSession) {
        renameSessionId = session.id
        renameText = previewFor(session)
        showRenameSheet = true
    }

    func confirmRename() {
        guard let sessionId = renameSessionId else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let result = runHermes(["sessions", "rename", sessionId, title])
        if result.exitCode == 0 {
            if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                let updated = sessions[idx].withTitle(title)
                sessions[idx] = updated
                if selectedSession?.id == sessionId {
                    selectedSession = updated
                }
            }
            sessionPreviews[sessionId] = title
        }
        showRenameSheet = false
        renameSessionId = nil
    }

    func beginDelete(_ session: HermesSession) {
        deleteSessionId = session.id
        showDeleteConfirmation = true
    }

    func confirmDelete() {
        guard let sessionId = deleteSessionId else { return }
        let result = runHermes(["sessions", "delete", "--yes", sessionId])
        if result.exitCode == 0 {
            sessions.removeAll { $0.id == sessionId }
            if selectedSession?.id == sessionId {
                selectedSession = nil
                messages = []
            }
            computeStats()
        }
        showDeleteConfirmation = false
        deleteSessionId = nil
    }

    func exportSession(_ session: HermesSession) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.id).jsonl"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runHermes(["sessions", "export", url.path, "--session-id", session.id])
    }

    func exportAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hermes-sessions.jsonl"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runHermes(["sessions", "export", url.path])
    }

    // MARK: - Stats

    private func computeStats() {
        let totalMessages = sessions.reduce(0) { $0 + $1.messageCount }

        var platformCounts: [String: Int] = [:]
        for s in sessions {
            platformCounts[s.source, default: 0] += 1
        }
        let sorted = platformCounts.sorted { $0.value > $1.value }.map { (platform: $0.key, count: $0.value) }

        let dbPath = HermesPaths.stateDB
        let fileSize: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int {
            if Double(size) >= FileSizeUnit.megabyte {
                fileSize = String(format: "%.1f MB", Double(size) / FileSizeUnit.megabyte)
            } else {
                fileSize = String(format: "%.0f KB", Double(size) / FileSizeUnit.kilobyte)
            }
        } else {
            fileSize = "unknown"
        }

        storeStats = SessionStoreStats(
            totalSessions: sessions.count,
            totalMessages: totalMessages,
            databaseSize: fileSize,
            platformCounts: sorted
        )
    }

    // MARK: - Hermes CLI

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HermesPaths.hermesBinary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output, process.terminationStatus)
        } catch {
            return ("", -1)
        }
    }
}
