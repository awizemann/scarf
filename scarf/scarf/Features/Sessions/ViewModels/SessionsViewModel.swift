import Foundation

@Observable
final class SessionsViewModel {
    private let dataService = HermesDataService()

    var sessions: [HermesSession] = []
    var selectedSession: HermesSession?
    var messages: [HermesMessage] = []
    var searchText = ""
    var searchResults: [HermesMessage] = []
    var isSearching = false

    func load() async {
        let opened = await dataService.open()
        guard opened else { return }
        sessions = await dataService.fetchSessions(limit: 500)
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
}
