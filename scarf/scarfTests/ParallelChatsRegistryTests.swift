import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Parallel chats P1, step 1: the window's chat registry (`chats`,
/// `focusedChat`), focus vs open, and the leave rules for the chat the user
/// moves off (`ChatSession.keepsRunningWhenLeft`).
///
/// ACP plumbing is scripted through the `acpClientFactory` seam (one
/// scripted channel per spawn, in factory-call order), so "spawned nothing"
/// is the factory's call count and "kept its process" is the channel staying
/// open.
@Suite struct ParallelChatsRegistryTests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias ScriptedACPChannel = Lifecycle.ScriptedACPChannel

    /// A factory handing out `channels` in call order, counting calls.
    /// Past the end each spawn gets a fresh channel of its own (two clients
    /// on one scripted channel would trap), so an unexpected spawn shows up
    /// as a count, not a crash.
    @MainActor
    static func install(_ channels: [ScriptedACPChannel], on vm: ChatViewModel) -> Lifecycle.CallCounter {
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let n = calls.next()
            let channel = n <= channels.count
                ? channels[n - 1]
                : ScriptedACPChannel(behavior: .happy(sessionId: "sess-extra-\(n)"))
            return ACPClient(context: ctx) { _ in channel }
        }
        return calls
    }

    @MainActor
    static func readyOn(_ vm: ChatViewModel, _ sessionId: String) async -> Bool {
        await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.richChatViewModel.sessionId == sessionId
        }
    }

    /// Start a new chat on `channel` (an `answeringPrompts` one) and run one
    /// completed turn in it: Hermes stores a session only after its first
    /// turn, so this is a chat the user can come back to.
    @MainActor
    static func startWithATurn(_ vm: ChatViewModel, _ channel: ScriptedACPChannel, _ sessionId: String) async -> Bool {
        vm.startNewSession()
        guard await readyOn(vm, sessionId) else { return false }
        vm.sendText("hello")
        guard await Lifecycle.waitUntil({ await channel.sentMethods.contains("session/prompt") }) else { return false }
        return await Lifecycle.waitUntil { !vm.canStopCurrentTurn && !vm.richChatViewModel.isAgentWorking }
    }

    // MARK: - Focus vs open

    /// Leaving a live, idle chat the user can come back to keeps its
    /// `hermes acp` process (step 2's budget is what will release it), and
    /// clicking its row again is a focus: no spawn, no `session/load`, the
    /// same chat object.
    @Test @MainActor func idleLiveChatIsKeptAndRefocusedWithoutASpawn() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-B"))
        let calls = Self.install([chA, chB], on: vm)

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat

        #expect(await Self.startWithATurn(vm, chB, "sess-B"))
        let chatB = vm.focusedChat
        #expect(chatB !== chatA)
        #expect(vm.chats.count == 2)
        #expect(await chA.closed == false, "leaving an idle live chat stopped its process")
        #expect(chatA.isACPConnected)

        let spawned = calls.count
        vm.resumeSession("sess-A")
        #expect(vm.focusedChat === chatA)
        #expect(vm.richChatViewModel.sessionId == "sess-A")
        #expect(vm.isPreparingSession == false, "a focus showed the start overlay")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(calls.count == spawned, "focusing a live chat spawned a process")
        #expect(await chA.sentMethods.contains("session/load") == false)
        // B had a turn too: kept, process open.
        #expect(vm.chats.count == 2)
        #expect(await chB.closed == false)
    }

    /// New → New: a new chat that came up but never had a turn has no row
    /// anywhere (Hermes stores a session after its first turn), so nothing
    /// could ever bring the user back to it. It is restarted in place, as
    /// before P1, and its process is stopped — not kept as a leak.
    @Test @MainActor func newThenNewSupersedesTheEmptyChat() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-B"))
        _ = Self.install([chA, chB], on: vm)

        vm.startNewSession()
        #expect(await Self.readyOn(vm, "sess-A"))
        let chatA = vm.focusedChat

        vm.startNewSession()
        #expect(await Self.readyOn(vm, "sess-B"))
        #expect(vm.focusedChat === chatA, "the empty chat wasn't reused in place")
        #expect(vm.chats.count == 1, "an unreachable empty chat was kept")
        #expect(await Lifecycle.waitUntil { await chA.closed }, "the empty chat's process leaked")
    }

    /// `/new` typed into a blank chat: the autostart brings a session up only
    /// to run `/new`, which must replace it, not keep it as a second chat
    /// nobody can reach.
    @Test @MainActor func slashNewInABlankChatReplacesIt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-B"))
        _ = Self.install([chA, chB], on: vm)

        vm.sendText("/new") // no client: autostart, then /new
        #expect(await Self.readyOn(vm, "sess-B"), "/new never started its session")
        #expect(vm.chats.count == 1, "/new in a blank chat left an unreachable chat behind")
        #expect(await Lifecycle.waitUntil { await chA.closed }, "the autostarted process leaked")
        #expect(await chA.sentMethods.contains("session/prompt") == false)
    }

    /// Leaving a chat that is only starting, with nothing typed, supersedes
    /// it as a switch always did: its pipeline abandons (no `session/new`
    /// on its channel), its client is stopped, and the window drops it.
    /// Browsing rows must not leak processes.
    @Test @MainActor func leavingAStartingChatWithNothingTypedSupersedesIt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chW = ScriptedACPChannel(behavior: .happy(sessionId: "sess-W"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 { return ACPClient(context: ctx) { _ in chA } }
            return ACPClient(context: ctx) { _ in
                for await _ in gate { break } // wedged spawn
                return chW
            }
        }

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat

        vm.startNewSession() // W: a second chat, wedged while starting
        let chatW = vm.focusedChat
        #expect(chatW !== chatA)
        #expect(await Lifecycle.waitUntil { calls.count == 2 })
        #expect(chatW.isStartingSession)

        vm.resumeSession("sess-A") // back to A before W ever came up
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.count == 1, "the abandoned start was kept")
        #expect(!vm.chats.contains { $0 === chatW })

        gateCont.yield(())
        gateCont.finish()
        let wStopped = await Lifecycle.waitUntil { await chW.closed }
        #expect(wStopped, "the superseded start's client was not stopped (leak)")
        #expect(await chW.sentMethods.contains("session/new") == false,
                "the superseded start carried on and created a session")
        #expect(await chA.closed == false)
        #expect(vm.richChatViewModel.sessionId == "sess-A")
    }

    /// A start that carries a kickoff prompt is not "nothing typed": leaving
    /// it keeps it running in the background, where it comes up and sends
    /// its prompt. Dropping it would lose the user's message.
    @Test @MainActor func leavingAStartingChatWithAKickoffPromptKeepsIt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chK = ScriptedACPChannel(behavior: .happy(sessionId: "sess-K"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 { return ACPClient(context: ctx) { _ in chA } }
            return ACPClient(context: ctx) { _ in
                for await _ in gate { break }
                return chK
            }
        }

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat

        vm.startNewSession(projectPath: nil, initialPrompt: "kick it off")
        let chatK = vm.focusedChat
        #expect(await Lifecycle.waitUntil { calls.count == 2 })

        vm.resumeSession("sess-A")
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.count == 2, "a start carrying a prompt was dropped")

        gateCont.yield(())
        gateCont.finish()
        let sent = await Lifecycle.waitUntil { await chK.sentMethods.contains("session/prompt") }
        #expect(sent, "the background chat never sent its kickoff prompt")
        #expect(chatK.richChatViewModel.sessionId == "sess-K")
        #expect(vm.focusedChat === chatA, "the background start stole focus")
    }

    /// A gate the sidebar reload waits on: both start paths reload the
    /// sidebar after "ready" and before they send what the user typed, so
    /// holding it parks a chat in exactly that window.
    @MainActor
    static func holdSidebarReloads(_ vm: ChatViewModel) -> ReloadGate {
        let gate = ReloadGate()
        vm.sessionListLoadHook = { await gate.wait() }
        return gate
    }

    /// Any number of waiters, all released at once and for good.
    @MainActor final class ReloadGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    /// Ready, but the kickoff prompt not yet sent (the start is still
    /// reloading the sidebar): leaving the chat then must keep it, and the
    /// prompt still goes out in the background.
    @Test @MainActor func aKickoffStartLeftAfterReadyStillSendsItsPrompt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chK = ScriptedACPChannel(behavior: .happy(sessionId: "sess-K"))
        _ = Self.install([chA, chK], on: vm)

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        let gate = Self.holdSidebarReloads(vm)
        defer { gate.open() }

        vm.startNewSession(projectPath: nil, initialPrompt: "kick it off")
        let chatK = vm.focusedChat
        #expect(await Self.readyOn(vm, "sess-K"))
        #expect(await chK.sentMethods.contains("session/prompt") == false, "precondition: prompt not sent yet")

        vm.resumeSession("sess-A")
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.contains { $0 === chatK }, "a chat whose kickoff prompt hadn't gone out was dropped")

        gate.open()
        #expect(await Lifecycle.waitUntil { await chK.sentMethods.contains("session/prompt") },
                "the kickoff prompt was lost")
        #expect(await chK.closed == false)
    }

    /// Same window for a typed message (autostart): ready, the sidebar
    /// reload still running, the message not sent yet.
    @Test @MainActor func aTypedAutostartLeftAfterReadyStillSendsTheMessage() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chFail = ScriptedACPChannel(behavior: .failInitialize)
        let chT = ScriptedACPChannel(behavior: .happy(sessionId: "sess-T"))
        _ = Self.install([chA, chFail, chT], on: vm)

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        vm.startNewSession() // T: its start fails, leaving a chat with no client
        let chatT = vm.focusedChat
        #expect(await Lifecycle.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.failed })

        let gate = Self.holdSidebarReloads(vm)
        defer { gate.open() }
        vm.sendText("typed message") // autostart
        #expect(await Self.readyOn(vm, "sess-T"))
        #expect(await chT.sentMethods.contains("session/prompt") == false, "precondition: message not sent yet")

        vm.resumeSession("sess-A")
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.contains { $0 === chatT }, "a chat whose typed message hadn't gone out was dropped")

        gate.open()
        #expect(await Lifecycle.waitUntil { await chT.sentMethods.contains("session/prompt") },
                "the typed message was lost")
        #expect(await chT.closed == false)
    }

    // MARK: - Background chats that settle dead

    /// A message typed into a chat starts it (autostart); the user moves on
    /// while it starts, so it is kept. When that start then fails there is
    /// nothing left: no process, no row. The window drops it.
    @Test @MainActor func aKeptBackgroundStartThatFailsIsDropped() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chBFail = ScriptedACPChannel(behavior: .failInitialize)
        let chTyped = ScriptedACPChannel(behavior: .failInitialize)
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            switch calls.next() {
            case 1: return ACPClient(context: ctx) { _ in chA }
            case 2: return ACPClient(context: ctx) { _ in chBFail }
            default:
                return ACPClient(context: ctx) { _ in
                    for await _ in gate { break }
                    return chTyped
                }
            }
        }

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        vm.startNewSession() // B: its start fails, B stays focused, errored
        let chatB = vm.focusedChat
        #expect(await Lifecycle.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.failed })
        #expect(vm.chats.count == 2, "the focused chat's failure must stay on screen")

        vm.sendText("typed while broken") // autostart, wedged
        #expect(await Lifecycle.waitUntil { calls.count == 3 })
        vm.resumeSession("sess-A")
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.contains { $0 === chatB }, "a start carrying typed text was dropped while starting")

        gateCont.yield(())
        gateCont.finish()
        let dropped = await Lifecycle.waitUntil { !vm.chats.contains { $0 === chatB } }
        #expect(dropped, "a background chat whose start failed stayed in the window")
        #expect(await Lifecycle.waitUntil { await chTyped.closed })
        #expect(vm.chats.count == 1)
        #expect(vm.focusedChat === chatA)
    }

    /// Same for the start watchdog: a kept background start that wedges is
    /// torn down when the watchdog fires, and then dropped.
    @Test @MainActor func aKeptBackgroundStartThatTimesOutIsDropped() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chK = ScriptedACPChannel(behavior: .happy(sessionId: "sess-K"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        defer { gateCont.finish() }
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 { return ACPClient(context: ctx) { _ in chA } }
            return ACPClient(context: ctx) { _ in
                // Wedged until the test ends.
                for await _ in gate { break }
                return chK
            }
        }

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        vm.sessionStartWatchdogNanos = 400_000_000
        vm.startNewSession(projectPath: nil, initialPrompt: "kick it off")
        let chatK = vm.focusedChat
        vm.resumeSession("sess-A")
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.contains { $0 === chatK })

        let dropped = await Lifecycle.waitUntil { !vm.chats.contains { $0 === chatK } }
        #expect(dropped, "a background start the watchdog tore down stayed in the window")
        #expect(vm.focusedChat === chatA)
        #expect(vm.acpError == nil, "the background failure painted over the focused chat")
    }

    // MARK: - Preflight replay

    /// The model preflight replays on the chat that bailed into it, not on
    /// whatever chat is focused when the user picks a model.
    @Test @MainActor func preflightReplayTargetsTheChatThatBailed() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        let calls = Self.install([chA, chB], on: vm)
        let configPath = home.path + "/config.yaml"

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat

        // No model configured any more: B's start (a kickoff prompt, so
        // there is something to open) bails into the sheet.
        try "model:\n  default: ''\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        vm.startNewSession(projectPath: nil, initialPrompt: "kick it off")
        let chatB = vm.focusedChat
        #expect(chatB !== chatA)
        #expect(await Lifecycle.waitUntil { vm.modelPreflightReason != nil })
        #expect(calls.count == 1)

        vm.resumeSession("sess-A") // focus moves before the pick
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.contains { $0 === chatB }, "the chat waiting on the sheet was dropped")

        // The pick writes a coherent config, as the real plan would.
        vm.modelConfigPlanApplier = { _ in
            (try? "model:\n  default: test-model\n  provider: anthropic\n"
                .write(toFile: configPath, atomically: true, encoding: .utf8)) != nil
        }
        vm.confirmModelPreflight(model: "test-model", provider: "anthropic")
        vm.cancelModelPreflight() // the sheet's dismiss() after the pick

        let bReady = await Lifecycle.waitUntil {
            chatB.richChatViewModel.sessionId == "sess-B" && !chatB.isStartingSession
        }
        #expect(bReady, "the replay didn't start the chat that bailed")
        #expect(await Lifecycle.waitUntil { await chB.sentMethods.contains("session/prompt") },
                "the replayed start lost its kickoff prompt")
        #expect(vm.focusedChat === chatA)
        #expect(vm.richChatViewModel.sessionId == "sess-A")
        #expect(await chA.closed == false, "the replay restarted the focused chat")
        #expect(await chA.sentMethods.filter { $0 == "session/new" }.count == 1)
    }

    /// A pick replays a blank new chat only if the user is still on it:
    /// left in the background with nothing to open (no prompt, no session
    /// to resume), it would come up as a ready, turnless process nobody can
    /// reach. It is dropped instead.
    @Test @MainActor func aBlankBackgroundChatIsDroppedNotReplayed() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let calls = Self.install([chA], on: vm)
        let configPath = home.path + "/config.yaml"

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        try "model:\n  default: ''\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        vm.startNewSession()
        let chatB = vm.focusedChat
        #expect(await Lifecycle.waitUntil { vm.modelPreflightReason != nil })
        vm.resumeSession("sess-A")
        #expect(vm.chats.contains { $0 === chatB })

        vm.modelConfigPlanApplier = { _ in
            (try? "model:\n  default: test-model\n  provider: anthropic\n"
                .write(toFile: configPath, atomically: true, encoding: .utf8)) != nil
        }
        vm.confirmModelPreflight(model: "test-model", provider: "anthropic")
        let dropped = await Lifecycle.waitUntil { !vm.chats.contains { $0 === chatB } }
        #expect(dropped, "a blank background chat was kept after the pick")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(calls.count == 1, "a blank background chat was started after the pick")
    }

    /// The sheet dismisses itself after a pick (`ChatModelPreflightSheet`:
    /// `onSelect`, then `dismiss()`), which writes `false` into its binding
    /// — `ChatView` turns that into `cancelModelPreflight()`. Arriving after
    /// the confirm, it is not a cancel: the start must still replay.
    @Test @MainActor func theSheetsDismissAfterAPickDoesNotCancelTheReplay() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let configPath = home.path + "/config.yaml"
        try "model:\n  default: ''\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        let vm = ChatViewModel(context: home.context)
        let ch = ScriptedACPChannel(behavior: .happy(sessionId: "sess-P"))
        _ = Self.install([ch], on: vm)

        vm.startNewSession()
        #expect(await Lifecycle.waitUntil { vm.modelPreflightReason != nil })
        vm.modelConfigPlanApplier = { _ in
            (try? "model:\n  default: test-model\n  provider: anthropic\n"
                .write(toFile: configPath, atomically: true, encoding: .utf8)) != nil
        }
        vm.confirmModelPreflight(model: "test-model", provider: "anthropic")
        vm.cancelModelPreflight() // the binding's set(false) from dismiss()

        #expect(await Self.readyOn(vm, "sess-P"), "the pick left the chat blank")
    }

    /// One sheet per window, and the chat on screen keeps it: a background
    /// chat bailing while the focused one waits must not take the sheet
    /// over, or the pick would replay a chat the user didn't ask for.
    @Test @MainActor func aBackgroundBailDoesNotTakeTheFocusedChatsSheet() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chF = ScriptedACPChannel(behavior: .happy(sessionId: "sess-F"))
        let calls = Self.install([chA, chF], on: vm)
        let configPath = home.path + "/config.yaml"

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        try "model:\n  default: ''\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        vm.startNewSession() // F, focused, bails
        let chatF = vm.focusedChat
        #expect(await Lifecycle.waitUntil { vm.modelPreflightReason != nil })

        // A background chat's start bails too (as a kept background start
        // or a replay would): the chat's own bail, then the host call.
        chatA.pendingStartArgs = (nil, nil, "background kick")
        vm.presentModelPreflight(for: chatA, reason: "no model", customProviders: .none)
        #expect(chatA.pendingStartArgs == nil, "the background bail kept a wait nothing will replay")
        #expect(chatF.pendingStartArgs != nil, "the focused chat lost its sheet")

        vm.modelConfigPlanApplier = { _ in
            (try? "model:\n  default: test-model\n  provider: anthropic\n"
                .write(toFile: configPath, atomically: true, encoding: .utf8)) != nil
        }
        vm.confirmModelPreflight(model: "test-model", provider: "anthropic")
        #expect(await Self.readyOn(vm, "sess-F"), "the pick didn't replay the focused chat")
        #expect(vm.focusedChat === chatF)
        #expect(calls.count == 2)
        #expect(await chA.closed == false)
    }

    /// One sheet per window: a second chat bailing into the preflight
    /// replaces the first one's wait. The first chat, now blank in the
    /// background, has nothing to replay it and is dropped.
    @Test @MainActor func aSecondPreflightBailDropsTheFirstWaitingChat() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        _ = Self.install([chA], on: vm)
        let configPath = home.path + "/config.yaml"

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        try "model:\n  default: ''\n".write(toFile: configPath, atomically: true, encoding: .utf8)

        vm.startNewSession() // B bails
        let chatB = vm.focusedChat
        #expect(await Lifecycle.waitUntil { vm.modelPreflightReason != nil })
        vm.resumeSession("sess-A")
        #expect(vm.chats.contains { $0 === chatB })
        vm.modelPreflightReason = nil

        vm.startNewSession() // C bails too, replacing B's wait
        let chatC = vm.focusedChat
        #expect(chatC !== chatB)
        #expect(await Lifecycle.waitUntil { vm.modelPreflightReason != nil })
        #expect(!vm.chats.contains { $0 === chatB }, "the replaced preflight's chat stayed behind")
        #expect(chatB.pendingStartArgs == nil)
        #expect(chatC.pendingStartArgs != nil)
    }

    /// A transport whose `config.yaml` reads block while armed, until
    /// released — to hold one chat's start in its preflight read while
    /// another chat goes ahead. Everything else passes straight through.
    final class ConfigReadGate: ServerTransport, @unchecked Sendable {
        private let inner: any ServerTransport
        private let condition = NSCondition()
        private var armed = false
        private var released = false
        private var blocked = 0

        init(_ inner: any ServerTransport) { self.inner = inner }

        /// Block every config read from now until `release()`.
        func arm() { condition.lock(); armed = true; condition.unlock() }
        /// New reads pass again; reads already blocked keep waiting.
        func disarm() { condition.lock(); armed = false; condition.unlock() }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        var blockedReads: Int { condition.lock(); defer { condition.unlock() }; return blocked }

        var contextID: ServerID { inner.contextID }
        var isRemote: Bool { inner.isRemote }
        func readFile(_ path: String) throws -> Data {
            if path.hasSuffix("config.yaml") {
                condition.lock()
                if armed {
                    blocked += 1
                    while !released { condition.wait() }
                }
                condition.unlock()
            }
            return try inner.readFile(path)
        }
        func unguardedWriteFile(_ path: String, data: Data) throws { try inner.unguardedWriteFile(path, data: data) }
        func fileExists(_ path: String) -> Bool { inner.fileExists(path) }
        func stat(_ path: String) -> FileStat? { inner.stat(path) }
        func statAll(_ paths: [String]) -> [String: FileStat]? { inner.statAll(paths) }
        func listDirectory(_ path: String) throws -> [String] { try inner.listDirectory(path) }
        func createDirectory(_ path: String) throws { try inner.createDirectory(path) }
        func removeFile(_ path: String) throws { try inner.removeFile(path) }
        func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
            try inner.runProcess(executable: executable, args: args, stdin: stdin, timeout: timeout)
        }
        func makeProcess(executable: String, args: [String]) -> Process {
            inner.makeProcess(executable: executable, args: args)
        }
        func makeProcess(executable: String, args: [String], cwd: String?) -> Process {
            inner.makeProcess(executable: executable, args: args, cwd: cwd)
        }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { inner.watchPaths(paths) }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            try await inner.streamScript(script, timeout: timeout)
        }
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            inner.streamLines(executable: executable, args: args)
        }
    }

    /// The real order: a kickoff chat K, left while its start is still in
    /// its preflight config read, bails into the model sheet AFTER the
    /// focused chat F already waits on it. F keeps the sheet; K, which
    /// nothing will replay, is dropped. (K reaches the host still marked as
    /// starting with input unless it settles first — then it was kept.)
    @Test @MainActor func aBackgroundKickoffBailingAfterTheFocusedChatIsDropped() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let gate = ConfigReadGate(home.context.makeTransport())
        defer { gate.release() }
        vm.fileService = HermesFileService(context: home.context, transport: gate)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chF = ScriptedACPChannel(behavior: .happy(sessionId: "sess-F"))
        let calls = Self.install([chA, chF], on: vm)
        let configPath = home.path + "/config.yaml"

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        try "model:\n  default: ''\n".write(toFile: configPath, atomically: true, encoding: .utf8)

        gate.arm()
        vm.startNewSession(projectPath: nil, initialPrompt: "kick it off") // K, held in its read
        let chatK = vm.focusedChat
        #expect(await Lifecycle.waitUntil { gate.blockedReads == 1 })
        gate.disarm()
        vm.resumeSession("sess-A")
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.contains { $0 === chatK }, "precondition: K kept while starting with a prompt")

        vm.startNewSession() // F, focused, bails first
        let chatF = vm.focusedChat
        #expect(await Lifecycle.waitUntil { vm.modelPreflightReason != nil })
        #expect(chatF.pendingStartArgs != nil)

        gate.release() // K's read lands: K bails, in the background
        let dropped = await Lifecycle.waitUntil { !vm.chats.contains { $0 === chatK } }
        #expect(dropped, "the background chat that bailed second was kept")
        #expect(chatF.pendingStartArgs != nil, "the focused chat lost its sheet")
        #expect(vm.focusedChat === chatF)

        vm.modelConfigPlanApplier = { _ in
            (try? "model:\n  default: test-model\n  provider: anthropic\n"
                .write(toFile: configPath, atomically: true, encoding: .utf8)) != nil
        }
        vm.confirmModelPreflight(model: "test-model", provider: "anthropic")
        #expect(await Self.readyOn(vm, "sess-F"), "the pick didn't replay the focused chat")
        #expect(calls.count == 2)
    }

    /// The real order for `/new` in a blank chat F that the user leaves
    /// before it comes up: kept while starting (it carries the typed
    /// `/new`), then F comes up and runs `/new` in the background, which
    /// the window refuses — and F, empty and unreachable, is dropped with
    /// its process, not left behind.
    @Test @MainActor func aBlankChatLeftWhileItsSlashNewStartsIsDroppedOnceItRuns() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chFail = ScriptedACPChannel(behavior: .failInitialize)
        let chF = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-F"))
        let (spawn, spawnCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            switch calls.next() {
            case 1: return ACPClient(context: ctx) { _ in chA }
            case 2: return ACPClient(context: ctx) { _ in chFail }
            case 3:
                return ACPClient(context: ctx) { _ in
                    for await _ in spawn { break }
                    return chF
                }
            default:
                let extra = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-extra"))
                return ACPClient(context: ctx) { _ in extra }
            }
        }

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        vm.startNewSession() // F: its start fails, leaving a blank chat with no client
        let chatF = vm.focusedChat
        #expect(await Lifecycle.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.failed })

        vm.sendText("/new") // autostart, held in its spawn
        #expect(await Lifecycle.waitUntil { calls.count == 3 })
        vm.resumeSession("sess-A")
        #expect(vm.focusedChat === chatA)
        #expect(vm.chats.contains { $0 === chatF }, "precondition: F kept while starting with typed input")

        spawnCont.yield(())
        spawnCont.finish()
        let dropped = await Lifecycle.waitUntil { !vm.chats.contains { $0 === chatF } }
        #expect(dropped, "a chat that came up only to run a refused /new was kept")
        #expect(await Lifecycle.waitUntil { await chF.closed }, "its process leaked")
        #expect(vm.focusedChat === chatA)
        #expect(calls.count == 3, "the refused /new started something")
    }

    // MARK: - Fan-out

    /// A rename from any surface reaches a background chat's header.
    @Test @MainActor func renameReachesABackgroundChat() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        _ = Self.install([chA, chB], on: vm)
        vm.sessionRenameRunner = { _, _, _ in ("", 0) }

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        chatA.richChatViewModel.currentSession = Self.stubSession(id: "sess-A")

        vm.startNewSession()
        #expect(await Self.readyOn(vm, "sess-B"))
        #expect(vm.focusedChat !== chatA)

        let renamed = await vm.renameSession("sess-A", to: "Quarterly plan")
        #expect(renamed)
        #expect(chatA.richChatViewModel.currentSession?.title == "Quarterly plan",
                "the background chat's header kept its old title")
    }

    /// A new chat starts with the window's last known ACP commands: Hermes
    /// advertises them once per process and not on `session/load`, so a
    /// fresh transcript view model would otherwise fall back.
    @Test @MainActor func aNewChatIsSeededWithTheKnownACPCommands() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        _ = Self.install([chA, chB], on: vm)

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        vm.richChatViewModel.handleACPEvent(.availableCommands(sessionId: "sess-A", commands: [
            ["name": "compress", "description": "Compress the context"],
            ["name": "usage", "description": "Show usage"],
        ]))
        #expect(vm.richChatViewModel.acpCommands.map(\.name) == ["compress", "usage"])
        let chatA = vm.focusedChat

        vm.startNewSession()
        #expect(vm.focusedChat !== chatA)
        #expect(vm.richChatViewModel.acpCommands.map(\.name) == ["compress", "usage"],
                "the new chat lost the agent's commands")
    }

    // MARK: - Finding a live chat

    /// The sidebar lists a rotated compression chain under its tip; a chat
    /// that didn't follow the rotation is still on the root. Clicking the
    /// tip's row finds that chat through the lineage (R14-2) instead of
    /// opening the conversation a second time.
    @Test @MainActor func aClickOnTheChainTipFocusesTheChatOnItsRoot() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let root = "p1-lineage-root-\(UUID().uuidString)"
        let tip = "p1-lineage-tip-\(UUID().uuidString)"
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: root))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        let calls = Self.install([chA, chB], on: vm)

        #expect(await Self.startWithATurn(vm, chA, root))
        let chatA = vm.focusedChat
        vm.startNewSession()
        #expect(await Self.readyOn(vm, "sess-B"))
        SessionLineageIndex.shared.record(server: vm.context.id, lineage: [root, tip])
        #expect(chatA.covers(tip) == false, "precondition: the chat didn't follow the rotation")

        let spawned = calls.count
        vm.resumeSession(tip)
        #expect(vm.focusedChat === chatA, "the chain's tip row didn't find the chat on its root")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(calls.count == spawned, "the rotated conversation was opened a second time")
    }

    /// The error banner's Reconnect restarts the chat it sits on, in place,
    /// even when that chat still reads as live — never a focus (a no-op)
    /// and never a second chat on the same session.
    @Test @MainActor func reconnectRestartsTheFocusedChatInPlace() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chA2 = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let calls = Self.install([chA, chA2], on: vm)

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat

        vm.resumeSession("sess-A", origin: .errorRetry)
        #expect(vm.focusedChat === chatA)
        #expect(await Lifecycle.waitUntil { await chA2.sentMethods.contains("session/load") },
                "Reconnect didn't reopen the session")
        #expect(await Lifecycle.waitUntil { await chA.closed }, "the retried chat's old process leaked")
        #expect(calls.count == 2)
        #expect(vm.chats.count == 1)
    }

    // MARK: - Continue last

    /// "Continue Last Session" resolves the session first and routes it like
    /// a click: when a live chat already is that session it is focused, not
    /// opened a second time.
    @Test @MainActor func continueLastFocusesTheLiveChatInsteadOfDuplicatingIt() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        try HermesV0215R18bMacTests.exec("""
        \(HermesV0215R18bMacTests.schemaSQL)
        INSERT INTO sessions (id, source, title, started_at, message_count) VALUES ('sess-A', 'acp', 'A', 3.0, 1);
        INSERT INTO messages (id, session_id, role, content, timestamp) VALUES (3, 'sess-A', 'user', 'latest', 9.0);
        """, dbAt: home.url)
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-B"))
        let calls = Self.install([chA, chB], on: vm)

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Self.startWithATurn(vm, chB, "sess-B"))
        let spawned = calls.count

        vm.continueLastSession()
        let focused = await Lifecycle.waitUntil { vm.focusedChat === chatA }
        #expect(focused, "continue-last didn't land on the live chat")
        #expect(vm.isPreparingSession == false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(calls.count == spawned, "continue-last opened the live session a second time")
        #expect(vm.chats.count == 2)
        #expect(await chA.sentMethods.contains("session/load") == false)
    }

    // MARK: - Terminal mode

    /// Terminal mode is about to run `hermes chat --resume X` while a
    /// background chat is working on X: that chat is stopped first (its
    /// turn cancelled, process closed) and dropped. A background chat on
    /// another session is left alone.
    @Test @MainActor func terminalResumeStopsTheBackgroundChatOnThatSessionOnly() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chC = ScriptedACPChannel(behavior: .happy(sessionId: "sess-C"))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        _ = Self.install([chA, chC, chB], on: vm)
        var launched: [[String]] = []
        vm.terminalLaunchOverride = { launched.append($0) }

        // A idle and C working in the background, B focused. (A working chat
        // on the session is never stopped:
        // `aTerminalResumeOfAWorkingConversationShowsTheChatInstead`.)
        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        vm.startNewSession()
        #expect(await Self.readyOn(vm, "sess-C"))
        vm.sendText("long job")
        #expect(await Lifecycle.waitUntil { await chC.sentMethods.contains("session/prompt") })
        let chatC = vm.focusedChat
        vm.startNewSession()
        #expect(await Self.readyOn(vm, "sess-B"))
        #expect(vm.chats.count == 3)

        vm.displayMode = .terminal
        vm.resumeSession("sess-A")
        #expect(launched == [["chat", "--resume", "sess-A"]])
        #expect(await Lifecycle.waitUntil { await chA.closed }, "the background chat on the resumed session kept running")
        #expect(!vm.chats.contains { $0 === chatA }, "the stopped chat stayed in the window")
        #expect(vm.chats.contains { $0 === chatC })
        #expect(await chC.closed == false, "an unrelated background chat was stopped")
        #expect(chatC.richChatViewModel.isAgentWorking)
    }

    /// Terminal Continue Last with a background chat on the latest session:
    /// the terminal opens exactly the session found (`--resume <id>`, as a
    /// row click does), after that chat was stopped — not `--continue`,
    /// whose choice of session Scarf can't confirm matches.
    @Test @MainActor func terminalContinueLastResumesTheSessionItStopped() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        try HermesV0215R18bMacTests.exec("""
        \(HermesV0215R18bMacTests.schemaSQL)
        INSERT INTO sessions (id, source, title, started_at, message_count) VALUES ('sess-A', 'acp', 'A', 3.0, 1);
        INSERT INTO messages (id, session_id, role, content, timestamp) VALUES (3, 'sess-A', 'user', 'latest', 9.0);
        """, dbAt: home.url)
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-B"))
        _ = Self.install([chA, chB], on: vm)
        var launched: [[String]] = []
        vm.terminalLaunchOverride = { launched.append($0) }

        #expect(await Self.startWithATurn(vm, chA, "sess-A")) // A idle in the background
        let chatA = vm.focusedChat
        #expect(await Lifecycle.waitUntil { !chatA.hasTurnInFlight })
        #expect(await Self.startWithATurn(vm, chB, "sess-B"))

        vm.displayMode = .terminal
        vm.continueLastSession()
        let ran = await Lifecycle.waitUntil { !launched.isEmpty }
        #expect(ran)
        #expect(launched == [["chat", "--resume", "sess-A"]])
        #expect(await Lifecycle.waitUntil { await chA.closed }, "the background chat on that session kept running")
        #expect(!vm.chats.contains { $0 === chatA })
    }

    // MARK: - Teardown

    /// Closing the window (`leaveChat`) with a chat working in the
    /// background stops it too: bounded `session/cancel`, process closed,
    /// and the window's list collapses to the one chat.
    @Test @MainActor func leavingTheWindowStopsBackgroundChats() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-B"))
        _ = Self.install([chA, chB], on: vm)

        vm.startNewSession()
        #expect(await Self.readyOn(vm, "sess-A"))
        vm.sendText("long job")
        #expect(await Lifecycle.waitUntil { await chA.sentMethods.contains("session/prompt") })
        vm.startNewSession()
        #expect(await Self.readyOn(vm, "sess-B"))
        #expect(vm.chats.count == 2)

        vm.leaveChat()
        #expect(await Lifecycle.waitUntil { await chA.sentMethods.contains("session/cancel") },
                "the background chat's turn wasn't cancelled on window close")
        #expect(await Lifecycle.waitUntil { await chA.closed })
        #expect(await Lifecycle.waitUntil { await chB.closed })
        #expect(vm.chats.count == 1)
    }

    /// A `/new` held while the chat's reconnect ladder ran, released after
    /// the user moved to another chat: running it then would replace the
    /// chat they are in. It is not run; the background chat says so.
    @Test @MainActor func aHeldSlashNewReleasedInTheBackgroundDoesNotTouchTheFocusedChat() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chReconnect = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-B"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            switch calls.next() {
            case 1: return ACPClient(context: ctx) { _ in chA }
            case 2:
                return ACPClient(context: ctx) { _ in
                    for await _ in gate { break }
                    return chReconnect
                }
            case 3: return ACPClient(context: ctx) { _ in chB }
            default:
                // Only a regression spawns again: give it its own channel.
                let extra = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-extra"))
                return ACPClient(context: ctx) { _ in extra }
            }
        }

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let chatA = vm.focusedChat
        await chA.close() // dies → reconnect ladder, wedged in its spawn
        #expect(await Lifecycle.waitUntil { calls.count == 2 })
        vm.sendText("/new") // held for the ladder's client

        #expect(await Self.startWithATurn(vm, chB, "sess-B"))
        let chatB = vm.focusedChat
        #expect(chatB !== chatA)
        let spawned = calls.count

        gateCont.yield(())
        gateCont.finish()
        let hinted = await Lifecycle.waitUntil { chatA.richChatViewModel.transientHint?.contains("/new") == true }
        #expect(hinted, "the background chat didn't say its /new wasn't run")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.focusedChat === chatB, "a background /new moved the focus")
        #expect(await chB.closed == false, "a background /new restarted the focused chat")
        #expect(calls.count == spawned)
        #expect(vm.richChatViewModel.sessionId == "sess-B")
    }

    /// An errored chat is restarted in place by the next open (the window
    /// mode counterpart of the `.single` supersede tests): the stale
    /// pipeline of its timed-out start, resuming late, must stop its own
    /// client and leave the new session attached.
    @Test @MainActor func aStaleStartInAnErroredChatReusedInPlaceBowsOut() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let chStale = ScriptedACPChannel(behavior: .happy(sessionId: "sess-stale"))
        let chX = ScriptedACPChannel(behavior: .happy(sessionId: "sess-X"))
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            if calls.next() == 1 {
                return ACPClient(context: ctx) { _ in
                    for await _ in gate { break }
                    return chStale
                }
            }
            return ACPClient(context: ctx) { _ in chX }
        }
        vm.sessionStartWatchdogNanos = 150_000_000
        let chat = vm.focusedChat

        vm.startNewSession()
        #expect(await Lifecycle.waitUntil { vm.acpError != nil }, "watchdog never fired")
        #expect(vm.chats.count == 1, "the focused chat's failure was dropped")
        vm.sessionStartWatchdogNanos = 90_000_000_000

        vm.resumeSession("sess-X")
        #expect(vm.focusedChat === chat, "an errored chat wasn't reused in place")
        #expect(await Self.readyOn(vm, "sess-X"))

        gateCont.yield(())
        gateCont.finish()
        #expect(await Lifecycle.waitUntil { await chStale.closed }, "the stale start's client leaked")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await chStale.sentMethods.contains("session/new") == false)
        #expect(vm.richChatViewModel.sessionId == "sess-X", "the stale start re-attached its session")
        #expect(vm.acpStatus == ChatViewModel.ACPPhase.ready)
        #expect(await chX.closed == false)
        #expect(vm.chats.count == 1)
    }

    // MARK: - Single mode

    /// `.single` (Bot Chat) keeps P0: one chat, reused by every resume; the
    /// old connection is torn down, never kept.
    @Test @MainActor func singleModeKeepsOneChatAcrossResumes() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context, mode: .single)
        let chA = ScriptedACPChannel(behavior: .answeringPrompts(sessionId: "sess-A"))
        let chB = ScriptedACPChannel(behavior: .happy(sessionId: "sess-B"))
        _ = Self.install([chA, chB], on: vm)

        #expect(await Self.startWithATurn(vm, chA, "sess-A"))
        let only = vm.focusedChat

        vm.resumeSession("sess-B")
        #expect(await Self.readyOn(vm, "sess-B"))
        #expect(vm.focusedChat === only)
        #expect(vm.chats.count == 1)
        #expect(await Lifecycle.waitUntil { await chA.closed }, "single mode kept the old process")

        // Resuming the attached session again restarts it (no focus path).
        vm.resumeSession("sess-B")
        #expect(vm.isStartingSession)
        #expect(await Lifecycle.waitUntil { await chB.closed })
        #expect(vm.chats.count == 1)
    }

    static func stubSession(id: String) -> HermesSession {
        HermesSession(
            id: id, source: "acp", userId: nil, model: nil, title: nil,
            parentSessionId: nil, startedAt: Date(), endedAt: nil, endReason: nil,
            messageCount: 1, toolCallCount: 0, inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, estimatedCostUSD: nil,
            reasoningTokens: 0, actualCostUSD: nil, costStatus: nil, billingProvider: nil
        )
    }
}
