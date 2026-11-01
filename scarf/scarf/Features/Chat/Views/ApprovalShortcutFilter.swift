import AppKit
import SwiftUI

/// When a bare digit may answer the approval card on screen. A digit that was
/// being typed as the card came up, a second press landing on the next queued
/// card, or a key held down must not approve a command nobody read. Clicks
/// never come through here.
struct ApprovalShortcutGate {
    /// How long a new card ignores digits.
    static let settleSeconds: TimeInterval = 0.5

    private var cardID: String?
    private var shownAt: TimeInterval = 0

    /// A card is on screen. Only a new id restarts the wait: SwiftUI also
    /// calls this when it re-renders the same card.
    mutating func cardShown(id: String, at now: TimeInterval) {
        guard id != cardID else { return }
        cardID = id
        shownAt = now
    }

    func allowsDigit(isRepeat: Bool, at now: TimeInterval) -> Bool {
        !isRepeat && now - shownAt >= Self.settleSeconds
    }
}

/// Puts `ApprovalShortcutGate` in front of the card's `.keyboardShortcut`
/// digits, which can't see key repeat or time. A key-down monitor drops the
/// digits the gate refuses before they reach the shortcut; everything else
/// passes, and only events for the card's own window are looked at.
struct ApprovalShortcutFilter: NSViewRepresentable {
    let cardID: String

    func makeCoordinator() -> Monitor { Monitor() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        context.coordinator.gate.cardShown(id: cardID, at: ProcessInfo.processInfo.systemUptime)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.gate.cardShown(id: cardID, at: ProcessInfo.processInfo.systemUptime)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Monitor) {
        coordinator.uninstall()
    }

    @MainActor
    final class Monitor {
        var gate = ApprovalShortcutGate()
        private weak var view: NSView?
        private var token: Any?
        private(set) var handledCount = 0

        func install(on view: NSView) {
            self.view = view
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        /// The installed monitor's body: nil drops the event. Counted so a
        /// test can see AppKit calling it, and stop calling it.
        func handle(_ event: NSEvent) -> NSEvent? {
            handledCount += 1
            guard let window = view?.window,
                  shouldDrop(event, windowNumber: window.windowNumber) else { return event }
            return nil
        }

        func uninstall() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }

        /// A 1-9 key-down for this window that the gate refuses. Shift doesn't
        /// exempt it: AZERTY types digits with Shift. It reaches here as the
        /// digit only there; QWERTY's Shift-1 reads "!" and passes.
        /// `NSEvent.timestamp` runs on the same clock as `systemUptime`.
        func shouldDrop(_ event: NSEvent, windowNumber: Int) -> Bool {
            guard event.type == .keyDown,
                  event.windowNumber == windowNumber,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers,
                  key.count == 1, let digit = key.first?.wholeNumberValue, (1...9).contains(digit)
            else { return false }
            return !gate.allowsDigit(isRepeat: event.isARepeat, at: event.timestamp)
        }
    }
}
