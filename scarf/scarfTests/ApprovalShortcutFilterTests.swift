import Testing
import AppKit
@testable import scarf

/// Approval digit shortcuts: ignored for 500 ms after a card appears (a new
/// id, so a queued next card too) and on key repeat. Key events are synthesized
/// and handed straight to the filter; nothing is typed at the screen.
@Suite struct ApprovalShortcutFilterTests {

    private static let window = 4242

    private static func key(
        _ characters: String,
        at time: TimeInterval,
        isRepeat: Bool = false,
        modifiers: NSEvent.ModifierFlags = [],
        window: Int = Self.window
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: time,
            windowNumber: window, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: 18
        ))
    }

    @MainActor
    private static func monitor(card: String = "card-1", shownAt: TimeInterval = 100) -> ApprovalShortcutFilter.Monitor {
        let monitor = ApprovalShortcutFilter.Monitor()
        monitor.gate.cardShown(id: card, at: shownAt)
        return monitor
    }

    @Test @MainActor func aDigitIsDroppedUntilTheCardHasSettled() throws {
        let monitor = Self.monitor()
        #expect(monitor.shouldDrop(try Self.key("1", at: 100), windowNumber: Self.window))
        #expect(monitor.shouldDrop(try Self.key("1", at: 100.49), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("1", at: 100.5), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("9", at: 200), windowNumber: Self.window))
    }

    @Test @MainActor func keyRepeatIsAlwaysDropped() throws {
        let monitor = Self.monitor()
        #expect(monitor.shouldDrop(try Self.key("1", at: 200, isRepeat: true), windowNumber: Self.window))
    }

    /// A second press landing on the next queued card: new id, new wait.
    @Test @MainActor func aQueuedNextCardWaitsAgain() throws {
        let monitor = Self.monitor()
        #expect(!monitor.shouldDrop(try Self.key("1", at: 101), windowNumber: Self.window))
        monitor.gate.cardShown(id: "card-2", at: 101.01)
        #expect(monitor.shouldDrop(try Self.key("1", at: 101.1), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("1", at: 101.6), windowNumber: Self.window))
    }

    /// SwiftUI re-rendering the same card doesn't restart the wait.
    @Test @MainActor func theSameCardDoesNotRestartTheWait() throws {
        let monitor = Self.monitor()
        monitor.gate.cardShown(id: "card-1", at: 100.4)
        #expect(!monitor.shouldDrop(try Self.key("1", at: 100.6), windowNumber: Self.window))
    }

    /// AZERTY types digits with Shift: they reach the gate as the digit. A
    /// shifted symbol is typing, and passes.
    @Test @MainActor func shiftedDigitsAreGatedAndShiftedSymbolsAreNot() throws {
        let monitor = Self.monitor()
        #expect(monitor.shouldDrop(try Self.key("1", at: 100, modifiers: .shift), windowNumber: Self.window))
        #expect(monitor.shouldDrop(try Self.key("1", at: 200, isRepeat: true, modifiers: .shift), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("1", at: 200, modifiers: .shift), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("!", at: 100, modifiers: .shift), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("&", at: 100), windowNumber: Self.window))
    }

    /// The installed monitor itself, through AppKit's event dispatch. The
    /// window is never ordered in, so nothing appears or takes focus.
    @Test @MainActor func theInstalledMonitorReallyDropsAndUninstallStopsIt() throws {
        let app = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView()
        window.contentView = view
        let filter = ApprovalShortcutFilter.Monitor()
        filter.gate.cardShown(id: "card", at: 100)

        defer { filter.uninstall() }
        func key(at time: TimeInterval) throws -> NSEvent {
            try Self.key("1", at: time, window: window.windowNumber)
        }

        // The body drops during the wait and passes after it.
        filter.install(on: view)
        try #expect(filter.handle(key(at: 100.1)) == nil, "a digit got through during the wait")
        try #expect(filter.handle(key(at: 100.6)) != nil, "a digit was dropped after the wait")

        // AppKit really calls it while installed, and not after. (An observing
        // monitor can't show the drop itself: monitors run in no fixed order.)
        let before = filter.handledCount
        app.sendEvent(try key(at: 100.1))
        #expect(filter.handledCount == before + 1, "the installed monitor never saw the event")
        filter.uninstall()
        app.sendEvent(try key(at: 100.1))
        #expect(filter.handledCount == before + 1, "uninstall left the monitor running")
        window.close()
    }

    /// Only the card's digits: Esc, ⌘C, a 0, or another window's typing pass.
    @Test @MainActor func everythingElsePassesThrough() throws {
        let monitor = Self.monitor()
        #expect(!monitor.shouldDrop(try Self.key("\u{1b}", at: 100), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("a", at: 100), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("0", at: 100), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("1", at: 100, modifiers: .command), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("1", at: 100, window: 7), windowNumber: Self.window))
        #expect(!monitor.shouldDrop(try Self.key("1", at: 100, isRepeat: true, window: 7), windowNumber: Self.window))
    }
}
