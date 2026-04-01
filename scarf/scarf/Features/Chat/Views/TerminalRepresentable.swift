import SwiftUI
import AppKit
import SwiftTerm

struct PersistentTerminalView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if terminalView.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(terminalView)
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor, constant: 4),
                terminalView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: nsView.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
            ])
        }
    }
}
