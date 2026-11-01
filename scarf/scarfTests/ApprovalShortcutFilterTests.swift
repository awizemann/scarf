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
