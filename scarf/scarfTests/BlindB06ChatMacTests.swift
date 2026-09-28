import Testing
import Foundation
import ScarfCore
@testable import scarf

/// B06 (blind re-audit, t-4111cb69) — the Mac half of the chat fixes.
///  - S01-F2 + t-14157321: one Stop for main chat and Bot Chat. ACP turns
///    get `session/cancel` and keep the session; Bot Chat CLI turns end
///    the `hermes chat -Q` process on the host that runs it.
///  - S03-F2: the model badge follows what the session runs.
///  - S03-F4: quick command names are saved the way Hermes looks them up.
@Suite struct ChatStopB06Tests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests
    typealias CancellableChannel = ChatViewModelP7bTests.CancellableChannel

    /// Stop on a running typed turn: one `session/cancel`, the process
    /// stays up, the turn ends on Hermes's `cancelled` answer with the
    /// "stopped" note and no failure, and the session is still usable.
    @Test @MainActor func stopCancelsTheTurnAndKeepsTheSession() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let channel = CancellableChannel()
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.startNewSession()
        #expect(await Lifecycle.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.ready })
        #expect(vm.canStopCurrentTurn == false, "Stop offered with nothing running")

        vm.sendText("long job")
        #expect(await Lifecycle.waitUntil { await channel.sentMethods.contains("session/prompt") })
        #expect(vm.canStopCurrentTurn)

        vm.stopCurrentTurn()
        let settled = await Lifecycle.waitUntil { vm.richChatViewModel.isAgentWorking == false }
        #expect(settled, "the stopped turn never ended")
        try? await Task.sleep(nanoseconds: 200_000_000) // let a stray banner task land

        let methods = await channel.sentMethods
        #expect(methods.filter { $0 == "session/cancel" }.count == 1)
        #expect(await channel.timeline.contains("closed") == false, "Stop killed the hermes acp process")
        #expect(vm.richChatViewModel.messages.contains {
            $0.role == "system" && $0.content.contains("You stopped this turn")
        })
        #expect(vm.richChatViewModel.acpError == nil)
        #expect(vm.acpError == nil)
        #expect(vm.acpStatus == ChatViewModel.ACPPhase.ready)
        #expect(vm.canStopCurrentTurn == false)
        vm.leaveChat()
    }

    /// With nothing running Stop sends nothing.
    @Test @MainActor func stopWithNoTurnSendsNothing() async throws {
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let channel = CancellableChannel()
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.startNewSession()
        #expect(await Lifecycle.waitUntil { vm.acpStatus == ChatViewModel.ACPPhase.ready })
        vm.stopCurrentTurn()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await channel.sentMethods.contains("session/cancel") == false)
        vm.leaveChat()
    }

    /// A `stopRouter` (Bot Chat's CLI transport) takes Stop over entirely.
    @Test @MainActor func stopRouterTakesPrecedence() {
        let vm = ChatViewModel(context: .local)
        var stopped = 0
        vm.stopRouter = (canStop: { true }, stop: { stopped += 1; return true })
        #expect(vm.canStopCurrentTurn)
        vm.stopCurrentTurn()
        #expect(stopped == 1)
    }
}

@Suite struct BotChatStopB06Tests {

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        private var stagingDirs: [String] = []
        func wait() async -> String? {
            await withCheckedContinuation { c in
                lock.lock(); continuation = c; lock.unlock()
            }
        }
        func release(_ value: String?) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: value)
        }
        func noteStop(_ dir: String) {
            lock.lock(); stagingDirs.append(dir); lock.unlock()
        }
        var stops: [String] {
            lock.lock(); defer { lock.unlock() }
            return stagingDirs
        }
    }

    @MainActor
    private func makeVM(gate: Gate) -> BotConversationViewModel {
        let vm = BotConversationViewModel(
            profileName: "scout",
            context: .local(home: URL(fileURLWithPath: "/tmp/scarf-b06-bot-\(UUID().uuidString)")),
            locator: { _ in HermesDataService.CanonicalBotChat(registryId: "bc", liveId: "bc", liveSource: "cli") },
            creator: { _, _, _ in await gate.wait() }
        )
        // The stopper ends the "process": the delivery returns the way an
        // interrupted `hermes chat -Q` does (non-zero, exit 130).
        vm.cliTurnStopper = { _, dir in
            gate.noteStop(dir)
            gate.release("hermes exited 130")
        }
        return vm
    }

    @MainActor
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// Stop on a CLI-transport turn ends it through the stopper with the
    /// turn's staging directory, then shows the stopped note — not the
    /// non-zero exit as an error — and the composer leaves "working".
    @Test @MainActor func stopEndsTheCLITurnHonestly() async {
        let gate = Gate()
        let vm = makeVM(gate: gate)
        vm.open()
        await settle()
        #expect(vm.delivery == .cliTransport)
        #expect(vm.chat.stopRouter != nil, "CLI transport must route Stop")
        #expect(vm.chat.canStopCurrentTurn == false)

        vm.send("hello bot")
        await settle()
        #expect(vm.chat.richChatViewModel.isAgentWorking)
        #expect(vm.chat.canStopCurrentTurn)

        vm.chat.stopCurrentTurn()
        let ended = await ChatViewModelStartLifecycleTests.waitUntil {
            !vm.chat.richChatViewModel.isAgentWorking
        }
        #expect(ended, "the stopped CLI turn kept the chat working")
        #expect(gate.stops.count == 1)
        #expect(gate.stops.first?.hasPrefix("/tmp/scarf-bot-chat-") == true)
        let rich = vm.chat.richChatViewModel
        #expect(rich.acpError == nil, "a stopped turn surfaced as a failure: \(rich.acpError ?? "")")
        #expect(rich.messages.contains { $0.role == "system" && $0.content.contains("You stopped this turn") })
        #expect(vm.chat.canStopCurrentTurn == false)
        #expect(vm.phase == .live)
        vm.close()
        #expect(vm.chat.stopRouter == nil, "close() must hand the chat back its own Stop")
    }

    /// An ACP-born Bot Chat stops over ACP: no router.
    @Test @MainActor func acpBornBotChatUsesTheACPStop() async {
        let vm = BotConversationViewModel(
            profileName: "scout",
            context: .local(home: URL(fileURLWithPath: "/tmp/scarf-b06-bot-acp")),
            locator: { _ in HermesDataService.CanonicalBotChat(registryId: "bc", liveId: "bc", liveSource: "acp") },
            creator: { _, _, _ in nil },
            acpClientMaker: { ctx, _, _ in ACPClient(context: ctx) { _ in BotConversationTests.InertACPChannel() } }
        )
        vm.open()
        await settle()
        #expect(vm.delivery == .acpStreaming)
        #expect(vm.chat.stopRouter == nil)
        vm.close()
    }

    /// The `pkill -f` pattern names only this turn and can't match the
    /// shell that runs `pkill` (whose own arguments hold the pattern).
    @Test func processPatternIsSelfExcludingAndStrict() {
        let dir = "/tmp/scarf-bot-chat-0A1B2C3D-0000-4000-8000-00000000ABCD"
        let pattern = BotConversationViewModel.cliTurnProcessPattern(stagingDirectory: dir)
        #expect(pattern == "[/]tmp/scarf-bot-chat-0A1B2C3D-0000-4000-8000-00000000ABCD")
        let command = BotConversationViewModel.interruptCommand(stagingDirectory: dir, signal: "INT")
        #expect(command == "pkill -INT -f '[/]tmp/scarf-bot-chat-0A1B2C3D-0000-4000-8000-00000000ABCD'")
        #expect(command?.contains(dir) == false, "the command line would match itself")
        // Anything not minted by Scarf is refused.
        #expect(BotConversationViewModel.cliTurnProcessPattern(stagingDirectory: "/tmp/x'; rm -rf ~") == nil)
        #expect(BotConversationViewModel.cliTurnProcessPattern(stagingDirectory: "/home/u") == nil)
        #expect(BotConversationViewModel.interruptCommand(stagingDirectory: dir, signal: "HUP") == nil)
    }

    /// The real stopper against a real local process whose argv carries the
    /// staging path, the way `hermes chat -Q --query-file <dir>/message.txt`
    /// does: SIGINT ends it, and a process for another turn is untouched.
    @Test func interruptEndsOnlyTheMatchingLocalProcess() async throws {
        let dir = BotConversationViewModel.newStagingDirectory()
        let other = BotConversationViewModel.newStagingDirectory()
        func spawn(_ d: String) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            // Default SIGINT handling, whatever the runner passed down —
            // Python (Hermes) and Perl both end on it by default.
            p.arguments = ["-e", "$SIG{INT}='DEFAULT'; sleep 30", "--", "--query-file", "\(d)/message.txt"]
            try p.run()
            return p
        }
        let target = try spawn(dir)
        let bystander = try spawn(other)
        defer { bystander.terminate() }

        await BotConversationViewModel.interruptCLITurn(context: .local, stagingDirectory: dir)
        for _ in 0..<50 where target.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!target.isRunning, "the turn's process survived Stop")
        #expect(target.terminationReason == .uncaughtSignal)
        #expect(target.terminationStatus == SIGINT)
        #expect(bystander.isRunning, "Stop hit another turn's process")
    }
}

@Suite struct ChatModelBadgeB06Tests {

    private let opus = ModelPreset(name: "Opus", modelID: "claude-opus-4", providerID: "anthropic")
    private let viaRouter = ModelPreset(name: "Opus (router)", modelID: "claude-opus-4", providerID: "openrouter")

    /// A resumed chat running a preset's model shows that preset.
    @Test func sessionModelMatchingAPresetShowsThePreset() {
        let badge = ChatViewModel.badgePreset(pickerId: "openrouter:claude-opus-4", presets: [opus, viaRouter], configModel: "gpt-5")
        #expect(badge?.id == viaRouter.id)
    }

    /// A new chat on the config.yaml default shows "Default" (nil).
    @Test func configDefaultShowsDefault() {
        #expect(ChatViewModel.badgePreset(pickerId: "openai:gpt-5", presets: [opus], configModel: "gpt-5") == nil)
    }

    /// Anything else — a `/model` typed in the chat, a switch made in
    /// another client — shows the running model itself, never a stale
    /// preset or "Default".
    @Test func otherModelShowsTheRunningModel() {
        let badge = ChatViewModel.badgePreset(pickerId: "openai:o3", presets: [opus], configModel: "gpt-5")
        #expect(badge?.name == "o3")
        #expect(badge?.modelID == "o3")
        #expect(badge?.providerID == "openai")
        #expect(badge?.id != opus.id)
    }

    @Test func modelSwitchReplyParsesOnlyHermesSuccessText() {
        #expect(ChatViewModel.modelSwitchPickerId(fromReply: "Model switched to: gpt-5\nProvider: OpenAI") == "openai:gpt-5")
        #expect(ChatViewModel.modelSwitchPickerId(fromReply: "Model switched to: gpt-5") == "gpt-5")
        #expect(ChatViewModel.modelSwitchPickerId(fromReply: "Error executing /model: Cannot switch to gpt-9") == nil)
        #expect(ChatViewModel.modelSwitchPickerId(fromReply: "Current model: gpt-5\nProvider: openai") == nil)
    }

    @Test func modelSwitchCommandNeedsAnArgument() {
        #expect(ChatViewModel.isModelSwitchCommand("/model gpt-5"))
        #expect(ChatViewModel.isModelSwitchCommand("  /model  openai:o3 "))
        #expect(!ChatViewModel.isModelSwitchCommand("/model"))
        #expect(!ChatViewModel.isModelSwitchCommand("/models list"))
        #expect(!ChatViewModel.isModelSwitchCommand("switch /model gpt-5"))
    }

    /// Reconnect: the chip follows the mode the reloaded session is in (a
    /// fresh `hermes acp` restores it at `default`, the load response says
    /// so), not the one picked by hand before the drop (S01-F1). Pre-fix
    /// the ladder never touched the chip and it kept "Don't Ask".
    @Test @MainActor func reconnectTakesTheModeFromTheLoadResponse() async throws {
        typealias Lifecycle = ChatViewModelStartLifecycleTests
        let home = try Lifecycle.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let first = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let second = Lifecycle.ScriptedACPChannel(behavior: .happy(sessionId: "sess-A"))
        let calls = Lifecycle.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            let n = calls.next()
            return ACPClient(context: ctx) { _ in n == 1 ? first : second }
        }
        vm.startNewSession()
        #expect(await Lifecycle.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready && vm.richChatViewModel.sessionId == "sess-A"
        })
        vm.switchApprovalMode(.dontAsk)
        #expect(await Lifecycle.waitUntil { await first.sentMethods.contains("session/set_mode") })
        #expect(vm.richChatViewModel.activeApprovalMode == .dontAsk)

        await first.close() // transport dies → reconnect ladder → session/load
        let reloaded = await Lifecycle.waitUntil(timeoutSeconds: 20) {
            await second.sentMethods.contains("session/load") && vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(reloaded, "the ladder never reloaded the session")
        #expect(vm.richChatViewModel.activeApprovalMode == .default,
                "the chip kept a mode the reloaded session is not in")
        vm.leaveChat()
    }
}

@Suite struct QuickCommandNameB06Tests {

    /// New names are saved lowercased: Hermes lowercases the typed
    /// command before looking it up, so "Deploy" could never run.
    @Test func newNamesAreLowercased() {
        #expect(QuickCommandsViewModel.storedName(for: "Deploy", existing: []) == "deploy")
        #expect(QuickCommandsViewModel.storedName(for: "v1.2 Build", existing: ["other"]) == "v1.2 build")
    }

    /// Editing an existing command keeps its key, so no second entry.
    @Test func editingKeepsTheExistingKey() {
        #expect(QuickCommandsViewModel.storedName(for: "Deploy", existing: ["Deploy"]) == "Deploy")
    }
}
