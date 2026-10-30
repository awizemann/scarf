import Testing
import AppKit
import Foundation
import ScarfCore
@testable import scarf

/// Parallel chats P2a: closing a window, switching its profile or quitting
/// Scarf with chats still working asks first, and the banners wait for every
/// chat in the window.
///
/// ACP is scripted through the `acpClientFactory` seam. The close proxy runs
/// against plain `NSWindow`s with a recording delegate standing in for
/// SwiftUI's; `AppQuitGuard` runs with its seams, never a real quit.
@Suite struct ParallelChatsCloseConfirmTests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias Registry = ParallelChatsRegistryTests
    typealias Rows = ParallelChatsRowsNotificationsTests
    typealias Controlled = Rows.ControlledChannel
    typealias Scripted = Lifecycle.ScriptedACPChannel
    typealias Gated = ChatSessionsR16bMacTests.GatedReplayChannel

    @MainActor
    static func makeVM(_ home: TempHermesHome, budget: LiveChatBudget? = nil) -> ChatViewModel {
        Rows.makeVM(home, Rows.RecordingNotifier(), budget: budget)
    }

    // MARK: - Which chats are working

    /// A turn in flight is working, in the shown chat or the background; once
    /// it answers, the chat is live and idle, and that is not.
    @Test @MainActor func aTurnInFlightIsWorkingAndAnIdleLiveChatIsNot() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        Rows.install([chA, chB], on: vm)

        #expect(await Rows.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(vm.workingChats.map(\.id) == [chatA.id])

        #expect(await Rows.startWorking(vm, chB, "work in B"))
        let chatB = vm.focusedChat
        #expect(vm.workingChats.map(\.id) == [chatA.id, chatB.id], "the background chat stopped counting")

        await chA.completePrompts()
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        #expect(chatA.isLive, "the finished chat should still hold its process")
        #expect(vm.workingChats.map(\.id) == [chatB.id], "an idle live chat counted as working")
        vm.leaveChat()
    }

    /// An approval raised with no prompt of Scarf's running counts on its own.
    @Test @MainActor func aWaitingApprovalIsWorkingWithNoTurnInFlight() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let ch = Controlled(sessionId: "sess-A")
        Rows.install([ch], on: vm)

        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        #expect(vm.workingChats.isEmpty, "a ready chat with nothing sent counted as working")

        await ch.emitPermissionRequest(requestId: 0, title: "rm -rf build", toolCallId: "perm-1")
        #expect(await Lifecycle.waitUntil { vm.focusedChat.rowState == .needsAnswer })
        #expect(!vm.focusedChat.hasTurnInFlight)
        #expect(vm.workingChats.count == 1)
        vm.leaveChat()
    }

    /// A message typed during the reconnect ladder is held, with no turn yet:
    /// closing now would lose it.
    @Test @MainActor func aSendHeldForAReconnectIsWorking() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let first = Scripted(behavior: .happy(sessionId: "sess-A"))
        let reconnect = Gated()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            calls.next() == 1
                ? ACPClient(context: ctx) { _ in first }
                : ACPClient(context: ctx) { _ in reconnect }
        }

        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-A"))
        await first.close()
        #expect(await Lifecycle.waitUntil(timeoutSeconds: 10) { await reconnect.hasPendingLoad })
        #expect(vm.workingChats.isEmpty, "a reconnect with nothing typed counted as working")

        vm.sendText("typed while reconnecting")
        #expect(vm.focusedChat.hasHeldSends)
        #expect(!vm.focusedChat.hasTurnInFlight)
        #expect(vm.workingChats.count == 1)
        vm.leaveChat()
    }

    /// A blank chat and one the budget released have nothing to lose.
    @Test @MainActor func blankAndReleasedChatsAreNotWorking() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home, budget: LiveChatBudget(localLimit: 2))
        #expect(vm.workingChats.isEmpty, "a blank chat counted as working")

        let chA = Scripted(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = Scripted(behavior: .happy(sessionId: "sess-B"))
        let chC = Scripted(behavior: .answeringPrompts(sessionId: "sess-C"))
        _ = Registry.install([chA, chB, chC], on: vm)
        #expect(await Registry.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await ParallelChatsBudgetTests.startWorking(vm, chB, "sess-B"))
        let chatB = vm.focusedChat
        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-C"))
        #expect(await Lifecycle.waitUntil { chatA.isReleased })

        #expect(vm.workingChats.map(\.id) == [chatB.id])
        vm.leaveChat()
    }

    /// A window's working chats include the bot conversation open in it.
    @Test @MainActor func aBotConversationCountsForItsWindow() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let coordinator = AppCoordinator(usageTracker: NoopUsageTracker())
        #expect(ChatWindowDirectory.workingChats(chat: vm, coordinator: coordinator).isEmpty)

        let botChat = ChatViewModel(context: home.context, mode: .single, liveChatBudget: LiveChatBudget(),
                                    notifier: Rows.RecordingNotifier())
        let ch = Controlled(sessionId: "sess-bot")
        let bots = coordinator.featureViewModel(for: .bots) {
            BotsViewModel(context: home.context, capabilities: HermesCapabilities(
                versionLine: "hermes 0.20.3", semver: .init(major: 0, minor: 20, patch: 3), dateVersion: nil))
        }
        bots.makeConversation = { ctx, name in
            BotConversationViewModel(
                profileName: name, context: ctx, chat: botChat,
                locator: { _ in nil }, creator: { _, _, _ in nil },
                acpClientMaker: { ctx, _, _ in ACPClient(context: ctx) { _ in ch } })
        }
        bots.openConversation(for: "research")
        #expect(ChatWindowDirectory.workingChats(chat: vm, coordinator: coordinator).isEmpty)

        botChat.startNewSession()
        #expect(await Registry.readyOn(botChat, "sess-bot"))
        botChat.sendText("hello bot")
        #expect(await Lifecycle.waitUntil { await ch.hasHeldPrompt })
        #expect(ChatWindowDirectory.workingChats(chat: vm, coordinator: coordinator).map(\.id) == [botChat.focusedChat.id])

        bots.closeConversation()
        #expect(ChatWindowDirectory.workingChats(chat: vm, coordinator: coordinator).isEmpty)
    }

    // MARK: - The confirm's copy

    @Test func theWindowConfirmsCopy() {
        #expect(ChatClosePolicy.prompt(.closeWindow, workingChatNames: []) == nil)

        let one = ChatClosePolicy.prompt(.closeWindow, workingChatNames: ["Fix the build"])
        #expect(one == .init(title: "1 chat is still replying",
                             message: "Closing this window stops “Fix the build”."))

        let two = ChatClosePolicy.prompt(.switchProfile, workingChatNames: ["A", "B"])
        #expect(two?.title == "2 chats are still replying")
        #expect(two?.message.hasPrefix("Switching profile stops “A”") == true)
        #expect(two?.message.contains("“B”") == true)
    }

    /// Past three names the rest are a count, and a long name is cut short.
    @Test func manyAndLongNamesStayReadable() throws {
        let long = String(repeating: "x", count: 100)
        let prompt = try #require(ChatClosePolicy.prompt(
            .closeWindow, workingChatNames: [long, "B", "C", "D", "E"]))
        #expect(prompt.title == "5 chats are still replying")
        #expect(prompt.message.contains("“" + String(repeating: "x", count: 40) + "…”"))
        #expect(!prompt.message.contains(String(repeating: "x", count: 41)))
        #expect(prompt.message.contains("“C”"))
        #expect(!prompt.message.contains("“D”"))
        #expect(prompt.message.contains("2 more"))
    }

    @Test func theQuitConfirmsCopy() {
        #expect(ChatClosePolicy.quitPrompt(workingChatNames: []) == nil)
        #expect(ChatClosePolicy.quitPrompt(workingChatNames: [[], []]) == nil)

        // Windows with nothing working don't count as windows here.
        let oneWindow = ChatClosePolicy.quitPrompt(workingChatNames: [[], ["A"]])
        #expect(oneWindow == .init(title: "1 chat is still replying", message: "Quitting Scarf stops “A”."))

        let twoWindows = ChatClosePolicy.quitPrompt(workingChatNames: [["A", "B"], [], ["C"]])
        #expect(twoWindows?.title == "3 chats are still replying in 2 windows")
    }

    // MARK: - The close proxy

    /// Stands in for SwiftUI's delegate.
    @MainActor
    final class RecordingDelegate: NSObject, NSWindowDelegate {
        var answer = true
        var shouldCloseCalls = 0
        var willCloseCalls = 0
        var didResizeCalls = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldCloseCalls += 1
            return answer
        }
        func windowWillClose(_ notification: Notification) { willCloseCalls += 1 }
        func windowDidResize(_ notification: Notification) { didResizeCalls += 1 }
    }

    @MainActor
    static func makeWindow(_ delegate: RecordingDelegate) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.orderFront(nil)
        return window
    }

    static let prompt = ChatClosePolicy.Prompt(title: "t", message: "m")

    /// The proxy wraps the delegate it found: whatever it doesn't handle
    /// reaches that delegate, and installing twice doesn't wrap itself.
    @Test @MainActor func theProxyPassesEverythingElseToTheDelegateItWrapped() {
        let inner = RecordingDelegate()
        let window = Self.makeWindow(inner)
        defer { window.close() }
        let proxy = WindowCloseDelegateProxy.install(on: window)
        #expect(window.delegate === proxy)
        #expect(WindowCloseDelegateProxy.install(on: window) === proxy)

        #expect(proxy.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        #expect(!proxy.responds(to: #selector(NSWindowDelegate.windowDidMove(_:))))
        window.setContentSize(NSSize(width: 260, height: 180))
        #expect(inner.didResizeCalls > 0)
    }

    /// SwiftUI setting its delegate again doesn't lose the guard.
    @Test @MainActor func aDelegateSetAgainIsWrappedAgain() {
        let inner = RecordingDelegate()
        let window = Self.makeWindow(inner)
        defer { window.close() }
        let proxy = WindowCloseDelegateProxy.install(on: window)
        let replacement = RecordingDelegate()
        window.delegate = replacement

        #expect(WindowCloseDelegateProxy.install(on: window) === proxy)
        #expect(window.delegate === proxy)
        window.performClose(nil)
        #expect(replacement.shouldCloseCalls == 1)
        #expect(inner.shouldCloseCalls == 0)
    }

    /// Nothing to ask: closes as if the proxy weren't there, with no confirm.
    @Test @MainActor func aCloseWithNothingWorkingDoesNotAsk() {
        let inner = RecordingDelegate()
        let window = Self.makeWindow(inner)
        let proxy = WindowCloseDelegateProxy.install(on: window)
        var asked = 0
        proxy.present = { _, _, _ in asked += 1 }
        proxy.setPrompt(owner: proxy) { ChatClosePolicy.prompt(.closeWindow, workingChatNames: []) }

        window.performClose(nil)
        #expect(asked == 0)
        #expect(!window.isVisible)
        #expect(inner.shouldCloseCalls == 1)
        #expect(inner.willCloseCalls == 1)
    }

    /// Cancel keeps the window open, and SwiftUI's delegate never hears of a
    /// close that didn't happen; Close Anyway goes through it, once.
    @Test @MainActor func cancelKeepsTheWindowAndCloseAnywayClosesIt() throws {
        let inner = RecordingDelegate()
        let window = Self.makeWindow(inner)
        let proxy = WindowCloseDelegateProxy.install(on: window)
        var decisions: [(Bool) -> Void] = []
        proxy.present = { _, _, decide in decisions.append(decide) }
        proxy.setPrompt(owner: proxy) { Self.prompt }

        window.performClose(nil)
        #expect(decisions.count == 1)
        // A second ⌘W while the confirm is up doesn't stack another.
        window.performClose(nil)
        try #require(decisions.count == 1)
        decisions[0](false)
        #expect(window.isVisible)
        #expect(inner.shouldCloseCalls == 0)

        // Asks again next time: Cancel isn't remembered.
        window.performClose(nil)
        try #require(decisions.count == 2)
        decisions[1](true)
        #expect(!window.isVisible)
        #expect(inner.shouldCloseCalls == 1)
        #expect(inner.willCloseCalls == 1)
    }

    /// Close Anyway refused by SwiftUI's delegate doesn't wave through a later
    /// close the user never agreed to.
    @Test @MainActor func aRefusedCloseAnywayIsNotRememberedAsConsent() {
        let inner = RecordingDelegate()
        inner.answer = false
        let window = Self.makeWindow(inner)
        defer { window.close() }
        let proxy = WindowCloseDelegateProxy.install(on: window)
        var asked = 0
        proxy.present = { _, _, decide in
            asked += 1
            if asked == 1 { decide(true) }
        }
        proxy.setPrompt(owner: proxy) { Self.prompt }

        window.performClose(nil)
        #expect(window.isVisible)
        #expect(inner.shouldCloseCalls == 1)
        inner.answer = true
        window.performClose(nil)
        #expect(asked == 2)
        #expect(window.isVisible)
    }

    /// The real alert: its buttons decide, and the close after Close Anyway
    /// isn't stopped by the sheet still being attached.
    @Test @MainActor func theRealAlertsButtonsDecide() async throws {
        let inner = RecordingDelegate()
        let window = Self.makeWindow(inner)
        let proxy = WindowCloseDelegateProxy.install(on: window)
        proxy.setPrompt(owner: proxy) { Self.prompt }

        window.performClose(nil)
        #expect(await Lifecycle.waitUntil { window.attachedSheet != nil })
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        #expect(await Lifecycle.waitUntil { window.attachedSheet == nil })
        // The answer arrives a tick after the sheet goes.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(window.isVisible, "Cancel closed the window")

        window.performClose(nil)
        #expect(await Lifecycle.waitUntil { window.attachedSheet != nil })
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        #expect(await Lifecycle.waitUntil { !window.isVisible }, "Close Anyway didn't close the window")
        #expect(inner.willCloseCalls == 1)
    }

    /// The quit confirm has spoken for every window.
    @Test @MainActor func aWindowClosingDuringAnApprovedQuitDoesNotAsk() {
        let inner = RecordingDelegate()
        let window = Self.makeWindow(inner)
        let proxy = WindowCloseDelegateProxy.install(on: window)
        var asked = 0
        proxy.present = { _, _, _ in asked += 1 }
        proxy.setPrompt(owner: proxy) { Self.prompt }
        proxy.isQuitApproved = { true }

        window.performClose(nil)
        #expect(asked == 0)
        #expect(!window.isVisible)
    }

    /// A profile switch builds a new root in the same window, whose guard may
    /// arrive before the old one goes: the old one mustn't clear the new one.
    @Test @MainActor func theOldRootGoingDoesNotClearTheNewRootsPrompt() {
        let inner = RecordingDelegate()
        let window = Self.makeWindow(inner)
        defer { window.close() }
        let proxy = WindowCloseDelegateProxy.install(on: window)
        let oldRoot = NSObject()
        let newRoot = NSObject()
        proxy.setPrompt(owner: oldRoot) { Self.prompt }
        proxy.setPrompt(owner: newRoot) { ChatClosePolicy.Prompt(title: "new", message: "m") }

        proxy.clearPrompt(owner: oldRoot)
        #expect(proxy.prompt?()?.title == "new")
        proxy.clearPrompt(owner: newRoot)
        #expect(proxy.prompt == nil)
    }

    // MARK: - Close Anyway and Cancel on real chats

    /// Cancel leaves a working chat running; Close Anyway's teardown (the
    /// window root's `leaveChat`) cancels and stops it.
    @Test @MainActor func cancelKeepsChatsRunningAndCloseAnywayStopsThem() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        Rows.install([chA, chB], on: vm)
        #expect(await Rows.startWorking(vm, chA, "work in A"))
        #expect(await Rows.startWorking(vm, chB, "work in B"))

        let inner = RecordingDelegate()
        let window = Self.makeWindow(inner)
        let proxy = WindowCloseDelegateProxy.install(on: window)
        var decisions: [(Bool) -> Void] = []
        var shown: ChatClosePolicy.Prompt?
        proxy.present = { _, prompt, decide in
            shown = prompt
            decisions.append(decide)
        }
        proxy.setPrompt(owner: proxy) {
            ChatClosePolicy.prompt(.closeWindow, workingChatNames: vm.workingChats.map(\.displayTitle))
        }
        let closed = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in _ = MainActor.assumeIsolated { vm.leaveChat() } }
        defer { NotificationCenter.default.removeObserver(closed) }

        window.performClose(nil)
        #expect(shown?.title == "2 chats are still replying")
        try #require(decisions.count == 1)
        decisions[0](false)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(vm.workingChats.count == 2, "Cancel touched the chats")
        #expect(!(await chA.sentMethods.contains("session/cancel")))
        #expect(!(await chA.closed))
        #expect(!(await chB.closed))

        window.performClose(nil)
        try #require(decisions.count == 2)
        decisions[1](true)
        #expect(!window.isVisible)
        #expect(await Lifecycle.waitUntil { await chA.sentMethods.contains("session/cancel") })
        #expect(await Lifecycle.waitUntil { await chB.sentMethods.contains("session/cancel") })
        #expect(await Lifecycle.waitUntil { await chA.closed })
        #expect(await Lifecycle.waitUntil { await chB.closed })
    }

    // MARK: - Quit

    /// Two windows, each with a working chat, in a directory of their own.
    @MainActor
    final class TwoWindows {
        let directory = ChatWindowDirectory()
        let first: ChatViewModel
        let second: ChatViewModel
        let chA = Controlled(sessionId: "sess-A")
        let chB = Controlled(sessionId: "sess-B")
        private let coordinators = [AppCoordinator(usageTracker: NoopUsageTracker()), AppCoordinator(usageTracker: NoopUsageTracker())]

        init(home: TempHermesHome) {
            first = ParallelChatsCloseConfirmTests.makeVM(home)
            second = ParallelChatsCloseConfirmTests.makeVM(home)
            Rows.install([chA], on: first)
            Rows.install([chB], on: second)
            for (vm, coordinator) in zip([first, second], coordinators) {
                directory.register(chat: vm, coordinator: coordinator, serverID: home.context.id,
                                   hermesHome: home.context.paths.home, openWindow: { _ in })
            }
        }

        func startWorking() async -> Bool {
            let a = await Rows.startWorking(first, chA, "work in A")
            let b = await Rows.startWorking(second, chB, "work in B")
            return a && b
        }

        func guardWith(confirm: @escaping (ChatClosePolicy.Prompt) -> Bool, finish: @escaping (Bool) -> Void) -> AppQuitGuard {
            let quit = AppQuitGuard()
            quit.workingChatNames = { [directory] in directory.workingChatNamesByWindow() }
            quit.stopAll = { [directory] in directory.stopAllWindows() }
            quit.confirm = confirm
            quit.finish = finish
            return quit
        }
    }

    /// Idle windows quit at once, unasked.
    @Test @MainActor func quittingWithNothingWorkingDoesNotAsk() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let windows = TwoWindows(home: home)
        var asked = 0
        let quit = windows.guardWith(confirm: { _ in asked += 1; return true }, finish: { _ in })

        #expect(quit.shouldTerminate() == .terminateNow)
        #expect(asked == 0)
        #expect(!quit.isApproved)
    }

    /// One confirm across the windows; Cancel leaves everything running and
    /// a later quit asks again.
    @Test @MainActor func quitCancelKeepsChatsRunning() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let windows = TwoWindows(home: home)
        #expect(await windows.startWorking())
        var prompts: [ChatClosePolicy.Prompt] = []
        var finished = false
        let quit = windows.guardWith(confirm: { prompts.append($0); return false }, finish: { _ in finished = true })

        #expect(quit.shouldTerminate() == .terminateCancel)
        #expect(prompts.map(\.title) == ["2 chats are still replying in 2 windows"])
        #expect(!quit.isApproved)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(!finished)
        #expect(windows.first.workingChats.count == 1)
        #expect(windows.second.workingChats.count == 1)
        #expect(!(await windows.chA.closed))
        #expect(!(await windows.chB.closed))

        #expect(quit.shouldTerminate() == .terminateCancel)
        #expect(prompts.count == 2)
        windows.first.leaveChat()
        windows.second.leaveChat()
    }

    /// Quit Anyway cancels every window's turn, and only then lets the quit
    /// finish; from there no window asks about closing.
    @Test @MainActor func quitAnywayStopsEveryWindowsChatsBeforeFinishing() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let windows = TwoWindows(home: home)
        #expect(await windows.startWorking())
        var finishedWith: Bool?
        let quit = windows.guardWith(confirm: { _ in true }, finish: { finishedWith = $0 })

        #expect(quit.shouldTerminate() == .terminateLater)
        #expect(quit.isApproved)
        #expect(finishedWith == nil, "the quit finished before the teardowns ran")
        #expect(await Lifecycle.waitUntil { finishedWith == true })
        #expect(await windows.chA.sentMethods.contains("session/cancel"))
        #expect(await windows.chB.sentMethods.contains("session/cancel"))
        #expect(await windows.chA.closed)
        #expect(await windows.chB.closed)
    }

    /// Switch & Relaunch was confirmed in its own dialog: no second confirm,
    /// but the chats still get their bounded cancel. Only that one quit.
    @Test @MainActor func aQuitConfirmedElsewhereSkipsOnlyTheConfirm() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let windows = TwoWindows(home: home)
        #expect(await windows.startWorking())
        var asked = 0
        var finished = false
        let quit = windows.guardWith(confirm: { _ in asked += 1; return false }, finish: { _ in finished = true })

        // A flag from a relaunch that found nothing working isn't left armed.
        quit.skipConfirmOnNextQuit()
        quit.workingChatNames = { [] }
        #expect(quit.shouldTerminate() == .terminateNow)
        quit.workingChatNames = { [directory = windows.directory] in directory.workingChatNamesByWindow() }
        #expect(quit.shouldTerminate() == .terminateCancel)
        #expect(asked == 1)

        quit.skipConfirmOnNextQuit()
        #expect(quit.shouldTerminate() == .terminateLater)
        #expect(asked == 1)
        #expect(await Lifecycle.waitUntil { finished })
        #expect(await windows.chA.closed)
        #expect(await windows.chB.closed)
    }

    /// A teardown stuck on a wedged host can't hold the quit past the budget.
    @Test func aWedgedTeardownCannotHoldTheQuit() async {
        let wedged = Task<Void, Never> {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        let started = ContinuousClock.now
        await AppQuitGuard.waitForAll([wedged], upTo: .milliseconds(200))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// With every teardown done, the wait ends at once rather than at the budget.
    @Test func finishedTeardownsEndTheWaitEarly() async {
        let done = Task<Void, Never> {}
        let started = ContinuousClock.now
        await AppQuitGuard.waitForAll([done], upTo: .seconds(30))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // MARK: - Banner gate

    /// A background chat's process holds the diagnostics banners back after
    /// the shown chat has stopped; with one chat the gate is `hasActiveProcess`.
    @Test @MainActor func aBackgroundLiveChatHoldsTheBannersBack() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = Self.makeVM(home)
        let chA = Controlled(sessionId: "sess-A")
        let chB = Scripted(behavior: .happy(sessionId: "sess-B"))
        Rows.install([chA, chB], on: vm)

        #expect(!vm.hasActiveProcessInWindow, "a blank window held the banners back")
        #expect(await Rows.startWorking(vm, chA, "work in A"))
        let chatA = vm.focusedChat
        #expect(vm.hasActiveProcess)
        #expect(vm.hasActiveProcessInWindow)

        vm.startNewSession()
        #expect(await Registry.readyOn(vm, "sess-B"))
        vm.stopACP()
        #expect(await Lifecycle.waitUntil { !vm.hasActiveProcess })
        #expect(chatA.hasActiveProcess)
        #expect(vm.hasActiveProcessInWindow, "the background chat's process didn't hold the banners back")

        vm.leaveChat()
        #expect(await Lifecycle.waitUntil { !vm.hasActiveProcessInWindow })
    }
}
