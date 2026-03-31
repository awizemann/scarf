import SwiftUI
import AppKit
import SwiftTerm

struct TerminalRepresentable: NSViewRepresentable {
    let command: String
    let arguments: [String]
    let environment: [String: String]

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)
        terminal.processDelegate = context.coordinator

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"

        let envArray = env.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: command,
            args: arguments,
            environment: envArray,
            execName: nil
        )
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let terminal = source.getTerminal()
            terminal.feed(text: "\r\n[Process exited with code \(exitCode ?? -1)]\r\n")
        }
    }
}
