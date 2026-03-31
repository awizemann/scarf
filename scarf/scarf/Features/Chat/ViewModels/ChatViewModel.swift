import Foundation
import AppKit
import SwiftTerm

@Observable
final class ChatViewModel {
    private let dataService = HermesDataService()
    private let fileService = HermesFileService()

    var recentSessions: [HermesSession] = []
    var sessionPreviews: [String: String] = [:]
    var terminalView: LocalProcessTerminalView?
    var hasActiveProcess = false
    var voiceEnabled = false
    var ttsEnabled = false
    var isRecording = false
    private var coordinator: Coordinator?

    var hermesBinaryExists: Bool {
        FileManager.default.fileExists(atPath: HermesPaths.hermesBinary)
    }

    func startNewSession() {
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        launchTerminal(arguments: ["chat"])
    }

    func resumeSession(_ sessionId: String) {
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        launchTerminal(arguments: ["chat", "--resume", sessionId])
    }

    func continueLastSession() {
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        launchTerminal(arguments: ["chat", "--continue"])
    }

    func loadRecentSessions() async {
        let opened = await dataService.open()
        guard opened else { return }
        recentSessions = await dataService.fetchSessions(limit: 10)
        sessionPreviews = await dataService.fetchSessionPreviews(limit: 10)
        await dataService.close()
    }

    func previewFor(_ session: HermesSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if let preview = sessionPreviews[session.id], !preview.isEmpty { return preview }
        return session.id
    }

    func toggleVoice() {
        guard let tv = terminalView else { return }
        if voiceEnabled {
            sendToTerminal(tv, text: "/voice off\r")
            voiceEnabled = false
            isRecording = false
        } else {
            sendToTerminal(tv, text: "/voice on\r")
            voiceEnabled = true
            ttsEnabled = fileService.loadConfig().autoTTS
        }
    }

    func toggleTTS() {
        guard let tv = terminalView, voiceEnabled else { return }
        sendToTerminal(tv, text: "/voice tts\r")
        ttsEnabled.toggle()
    }

    func pushToTalk() {
        guard let tv = terminalView, voiceEnabled else { return }
        // Ctrl+B = ASCII 0x02
        let ctrlB: [UInt8] = [0x02]
        tv.send(source: tv, data: ctrlB[0..<1])
        isRecording.toggle()
    }

    private func sendToTerminal(_ tv: LocalProcessTerminalView, text: String) {
        let bytes = Array(text.utf8)
        tv.send(source: tv, data: bytes[0..<bytes.count])
    }

    private func launchTerminal(arguments: [String]) {
        if let existing = terminalView {
            existing.terminate()
            existing.removeFromSuperview()
        }

        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)

        let coord = Coordinator(onTerminated: { [weak self] in
            self?.hasActiveProcess = false
            self?.voiceEnabled = false
            self?.isRecording = false
        })
        terminal.processDelegate = coord
        self.coordinator = coord

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: HermesPaths.hermesBinary,
            args: arguments,
            environment: envArray,
            execName: nil
        )

        self.terminalView = terminal
        self.hasActiveProcess = true
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onTerminated: () -> Void

        init(onTerminated: @escaping () -> Void) {
            self.onTerminated = onTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let terminal = source.getTerminal()
            terminal.feed(text: "\r\n[Process exited with code \(exitCode ?? -1). Use the toolbar to start or resume a session.]\r\n")
            DispatchQueue.main.async { self.onTerminated() }
        }
    }
}
