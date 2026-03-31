import Foundation

@Observable
final class ChatViewModel {
    var sessionId = UUID()

    var hermesBinaryExists: Bool {
        FileManager.default.fileExists(atPath: HermesPaths.hermesBinary)
    }
}
