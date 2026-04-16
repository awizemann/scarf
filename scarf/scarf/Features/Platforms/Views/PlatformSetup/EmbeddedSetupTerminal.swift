import SwiftUI
import AppKit
import SwiftTerm
import os

/// Inline SwiftTerm terminal for platform pairing wizards that genuinely require
/// a TTY (WhatsApp QR, Signal `signal-cli link`). This is a lightweight sibling
/// to `PersistentTerminalView` in the Chat feature — scoped to run a single
/// command, show its output, and notify when the process exits.
///
/// Usage:
///   EmbeddedSetupTerminal(controller: viewModel.terminalController)
///   // Controller exposes start()/terminate() that the view model owns.
struct EmbeddedSetupTerminal: NSViewRepresentable {
    let controller: EmbeddedSetupTerminalController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        controller.attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // If the view model recreated its terminal view (e.g., after re-launching
        // the pairing command), re-attach it to the container.
        controller.reattachIfNeeded(to: nsView)
    }
}

/// Owns the `LocalProcessTerminalView` so it survives SwiftUI body redraws.
/// Lives on the view model (one per platform that uses it).
@MainActor
final class EmbeddedSetupTerminalController {
    private let logger = Logger(subsystem: "com.scarf", category: "EmbeddedSetupTerminal")

    /// The hosting NSView from the `NSViewRepresentable`. Weak because SwiftUI
    /// owns the container's lifetime; we just attach our terminal view inside it.
    private weak var container: NSView?

    /// The actual terminal emulator. Recreated per launch so a terminated
    /// process doesn't leave stale buffer state mixed with new output.
    private var terminalView: LocalProcessTerminalView?
    private var coordinator: Coordinator?

    /// Invoked when the spawned process exits. The `Int32` is the exit code
    /// (`0` success, non-zero failure). Runs on the main actor.
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { terminalView != nil }

    /// Start a process in the embedded terminal. If a process is already running,
    /// it is terminated first to avoid orphans.
    func start(executable: String, arguments: [String], environment: [String: String] = [:]) {
        stop()
        guard let container else {
            logger.warning("start() called before terminal was attached to a container")
            return
        }

        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)

        let coord = Coordinator { [weak self] exitCode in
            self?.onExit?(exitCode ?? -1)
        }
        terminal.processDelegate = coord
        coordinator = coord

        // Merge caller-provided env over the enriched shell env so `npx`, `node`,
        // `signal-cli`, etc. resolve from PATH.
        var env = HermesFileService.enrichedEnvironment()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        for (k, v) in environment { env[k] = v }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: executable,
            args: arguments,
            environment: envArray,
            execName: nil
        )

        // Attach with AutoLayout constraints — matches the pattern used by
        // Features/Chat/Views/TerminalRepresentable.swift. Relying on
        // autoresizingMask is unreliable when SwiftUI hosts the NSView,
        // because SwiftUI drives layout via AutoLayout.
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        terminalView = terminal
    }

    /// Kill the running process (if any). Safe to call when nothing is running.
    func stop() {
        terminalView?.terminate()
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    // MARK: - NSViewRepresentable plumbing

    func attach(to container: NSView) {
        self.container = container
        if let tv = terminalView, tv.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            tv.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                tv.topAnchor.constraint(equalTo: container.topAnchor),
                tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }

    func reattachIfNeeded(to container: NSView) {
        self.container = container
        guard let tv = terminalView, tv.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        tv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onTerminated: (Int32?) -> Void

        init(onTerminated: @escaping (Int32?) -> Void) {
            self.onTerminated = onTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let terminal = source.getTerminal()
            terminal.feed(text: "\r\n[Process exited with code \(exitCode ?? -1)]\r\n")
            let code = exitCode
            DispatchQueue.main.async { self.onTerminated(code) }
        }
    }
}
