import AppKit

/// Asks before Scarf quits with chats working or first messages waiting in
/// any window, then gives
/// those chats their bounded cancel (parallel chats P2, design §6).
@MainActor
final class AppQuitGuard {
    static let shared = AppQuitGuard()

    /// The longest a quit waits for the chats' teardowns. A chat's own
    /// `session/cancel` is bounded at 2s (`ChatSession.boundedSessionCancel`);
    /// this covers `client.stop()` after it, and a wedged host can't hold the
    /// quit past it.
    nonisolated static let teardownBudget: Duration = .seconds(3)

    /// The user agreed to quit (or the quit was asked for elsewhere): no
    /// window asks about closing from here on.
    private(set) var isApproved = false
    /// The next quit was already confirmed by whoever asks for it (Switch &
    /// Relaunch: the new instance is launching by then, so Cancel would leave
    /// two running).
    private var nextQuitConfirmed = false

    // Seams for tests; production reads every open window and asks with an
    // alert.
    var workingChatNames: () -> [[String]] = { ChatWindowDirectory.shared.workingChatNamesByWindow() }
    var parkedKickoffNames: () -> [String] = { ChatWindowDirectory.shared.parkedKickoffNames() }
    var stopAll: () -> [Task<Void, Never>] = { ChatWindowDirectory.shared.stopAllWindows() }
    var confirm: (ChatClosePolicy.Prompt) -> Bool = AppQuitGuard.runAlert
    var finish: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    init() {}

    func skipConfirmOnNextQuit() { nextQuitConfirmed = true }

    /// The answer to `applicationShouldTerminate`.
    func shouldTerminate() -> NSApplication.TerminateReply {
        // A quit already under way, asked again.
        if isApproved { return .terminateLater }
        let prompt = ChatClosePolicy.quitPrompt(
            workingChatNames: workingChatNames(), parkedKickoffs: parkedKickoffNames())
        let confirmed = nextQuitConfirmed
        nextQuitConfirmed = false
        guard let prompt else { return .terminateNow }
        guard confirmed || confirm(prompt) else { return .terminateCancel }
        isApproved = true
        let teardowns = stopAll()
        Task { @MainActor in
            await Self.waitForAll(teardowns, upTo: Self.teardownBudget)
            finish(true)
        }
        return .terminateLater
    }

    /// Wait until every teardown has finished, or `budget` has passed. Not a
    /// task group: leaving one waits for its children, and a child awaiting
    /// a teardown stuck on a wedged host never ends.
    nonisolated static func waitForAll(_ tasks: [Task<Void, Never>], upTo budget: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = ResumeOnce(continuation)
            Task {
                for task in tasks { await task.value }
                resume()
            }
            Task {
                try? await Task.sleep(for: budget)
                resume()
            }
        }
    }

    private static func runAlert(_ prompt: ChatClosePolicy.Prompt) -> Bool {
        // The menu bar item can quit Scarf while another app is in front.
        NSApp.activate()
        let alert = ChatClosePolicy.alert(for: prompt, confirmTitle: String(localized: "Quit Anyway"))
        return alert.runModal() == ChatClosePolicy.confirmResponse
    }
}

/// Resumes a continuation once, whichever caller gets there first.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func callAsFunction() {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

/// Scarf's app delegate. SwiftUI's own stays in place and passes on what it
/// doesn't handle. Only the quit question lives here.
final class ScarfAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppQuitGuard.shared.shouldTerminate() }
    }
}
