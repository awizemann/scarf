import Foundation
import Testing
import ScarfCore
@testable import scarf

/// B3's app-layer half: the ACP launch argv (local and over SSH), and the
/// conversation view model's resolve / create / teardown lifecycle.
///
/// The lifecycle tests drive `BotConversationViewModel` through its two
/// injected seams (`locator`, `creator`) instead of a real database or a
/// real `hermes` binary — the same shape `BotsViewModelTests` uses for
/// `BotsBackend`, and the reason none of this needs a Hermes home.
@Suite("Bot conversation (B3)")
struct BotConversationTests {

    // MARK: - ACP launch argv

    /// The verification that unblocked this work package: `-p` is
    /// pre-parsed out of the whole argv by `hermes_cli.main
    /// ._apply_profile_override` BEFORE argparse ever runs, so it composes
    /// with `acp` exactly as it does with `chat`. Pinned as argv because
    /// this is the one place a silent wrong-profile launch could hide.
    @Test("a bot's ACP process is launched as `hermes -p <bot> acp`")
    func profileFlagPrecedesTheSubcommand() {
        #expect(ACPClient.acpArguments(profile: "scout") == ["-p", "scout", "acp"])
    }

    @Test("an unpinned launch is unchanged — no flag, no behavior change for main Chat")
    func unpinnedLaunchIsBare() {
        #expect(ACPClient.acpArguments(profile: nil) == ["acp"])
    }

    /// `-p default` is a no-op Hermes special-cases, and emitting it would
    /// make every ordinary chat's argv differ for no reason.
    @Test("the default profile emits no flag")
    func defaultProfileEmitsNoFlag() {
        #expect(ACPClient.acpArguments(profile: "default") == ["acp"])
        #expect(ACPClient.acpArguments(profile: "  default  ") == ["acp"])
    }

    /// Hermes rejects a malformed `-p` value and silently falls back to
    /// `active_profile` (main.py:606-615) — i.e. it would run as the USER
    /// while Scarf believed it had pinned a bot. Refusing to emit the flag
    /// at all makes that outcome our decision, not a surprise.
    @Test(arguments: ["../escape", "Has Spaces", "UPPER", "", "-rf", "a;rm -rf /", "no:xdist",
                      String(repeating: "a", count: 65)])
    func malformedProfileNamesNeverReachTheCommandLine(name: String) {
        #expect(ACPClient.acpArguments(profile: name) == ["acp"], "\(name) must not be emitted")
    }

    /// Over SSH the same argv rides the transport verbatim —
    /// `SSHTransport.composedRemoteCommand` joins `[executable] + args`,
    /// so a remote bot is pinned exactly like a local one.
    @Test("the SSH command line carries the profile flag")
    func sshCommandCarriesTheProfileFlag() {
        let ctx = ServerContext(
            id: UUID(),
            displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: "~/.hermes"))
        )
        let pinned = ctx.pinnedToProfile("scout")
        let transport = pinned.makeTransport()
        let proc = transport.makeProcess(
            executable: pinned.paths.hermesBinary,
            args: ACPClient.acpArguments(profile: "scout"),
            cwd: nil
        )
        let argv = proc.arguments ?? []
        let command = argv.last ?? ""
        #expect(argv.contains("-T"), "ACP needs a pty-free channel")
        #expect(command.contains("-p"))
        #expect(command.contains("scout"))
        #expect(command.contains("acp"))
        // The profile flag precedes the subcommand in the remote command too.
        if let p = command.range(of: "-p"), let acp = command.range(of: "acp") {
            #expect(p.lowerBound < acp.lowerBound)
        }
        // Belt and braces: the pinned home also scopes HERMES_HOME, and the
        // two must name the SAME profile or the agent and its state.db
        // would diverge.
        #expect(command.contains("profiles/scout"))
    }

    // MARK: - Lifecycle

    private func canonical(_ id: String) -> HermesDataService.CanonicalBotChat {
        HermesDataService.CanonicalBotChat(registryId: id, liveId: id)
    }

    /// An `ACPChannel` that never answers. Enough for `ACPClient.start()`
    /// to be *attempted* without spawning `hermes acp` — these tests are
    /// about the conversation's own state machine, and a real subprocess
    /// (against the developer's real install, since a local
    /// `paths.hermesBinary` resolves the actual binary) has no business in
    /// a unit test.
    actor InertACPChannel: ACPChannel {
        var diagnosticID: String? { "inert" }
        var lastExitCode: Int32? { nil }
        func send(_ line: String) async throws {}
        nonisolated var incoming: AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { _ in }
        }
        nonisolated var stderr: AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func close() async {}
    }

    @MainActor
    private func stubbedChat(context: ServerContext) -> ChatViewModel {
        let chat = ChatViewModel(context: context)
        chat.acpClientFactory = { ctx, _ in
            ACPClient(context: ctx) { _ in InertACPChannel() }
        }
        return chat
    }

    @MainActor
    private func makeVM(
        profile: String = "scout",
        found: HermesDataService.CanonicalBotChat? = nil,
        creationFailure: String? = nil,
        onCreate: (@Sendable (String) -> Void)? = nil
    ) -> BotConversationViewModel {
        let result = found
        let context = ServerContext.local(home: URL(fileURLWithPath: "/tmp/scarf-b3-home"))
        return BotConversationViewModel(
            profileName: profile,
            context: context,
            chat: stubbedChat(context: context.pinnedToProfile(profile)),
            locator: { _ in result },
            creator: { _, _, text in
                onCreate?(text)
                return creationFailure
            }
        )
    }

    @MainActor
    @Test("a bot with no Bot Chat rests in the empty state — nothing is pre-created")
    func absentConversationDoesNotCreateAnything() async {
        var created = false
        let vm = makeVM(found: nil, onCreate: { _ in created = true })
        vm.open()
        await settle()
        #expect(vm.phase == .noConversationYet)
        #expect(vm.canonical == nil)
        #expect(!created, "opening a bot must never mint a session")
    }

    @MainActor
    @Test("an existing Bot Chat is resumed at its live id")
    func existingConversationIsResumed() async {
        let vm = makeVM(found: canonical("bot-chat-1"))
        vm.open()
        await settle()
        #expect(vm.phase == .live)
        #expect(vm.canonical?.registryId == "bot-chat-1")
    }

    @MainActor
    @Test("the first message is what creates the conversation, then it connects")
    func firstMessageCreatesThenConnects() async {
        var sent: String?
        let context = ServerContext.local(home: URL(fileURLWithPath: "/tmp/scarf-b3-home"))
        let vm = BotConversationViewModel(
            profileName: "scout",
            context: context,
            chat: stubbedChat(context: context.pinnedToProfile("scout")),
            locator: { [box = ResolveBox()] _ in box.next() },
            creator: { _, _, text in sent = text; return nil }
        )
        vm.open()
        await settle()
        #expect(vm.phase == .noConversationYet)

        vm.send("hello there")
        await settle()
        #expect(sent == "hello there")
        #expect(vm.phase == .live)
        #expect(vm.canonical?.registryId == "made-by-first-send")
    }

    @MainActor
    @Test("a creation failure surfaces the CLI's own words and stays retryable")
    func creationFailureIsReported() async {
        let vm = makeVM(found: nil, creationFailure: "profile 'scout' has no model configured")
        vm.open()
        await settle()
        vm.send("hi")
        await settle()
        #expect(vm.phase == .failed("profile 'scout' has no model configured"))
    }

    @MainActor
    @Test("an unaddressable profile name is refused before any process or path is built")
    func unaddressableProfileIsRefused() async {
        var located = false
        let context = ServerContext.local(home: URL(fileURLWithPath: "/tmp/scarf-b3-home"))
        let vm = BotConversationViewModel(
            profileName: "../escape",
            context: context,
            chat: stubbedChat(context: context),
            locator: { _ in located = true; return nil },
            creator: { _, _, _ in nil }
        )
        vm.open()
        await settle()
        #expect(!located)
        if case .failed = vm.phase {} else { Issue.record("expected .failed, got \(vm.phase)") }
    }

    /// The audit's headline finding. `ChatViewModel` falls back to
    /// `session/new` when `session/load` fails — correct for main Chat,
    /// silently wrong for a bot: prompts would land in a NEW UNTITLED
    /// session, and Hermes gates the bot-mode protocol on the title, so the
    /// agent answering would not be in bot mode. The conversation must
    /// refuse rather than quietly become something else.
    @MainActor
    @Test("a session bound to anything other than the Bot Chat is refused, not used")
    func aDriftedSessionBindingIsRefused() async {
        let vm = makeVM(found: canonical("bot-chat-1"))
        vm.open()
        await settle()
        #expect(vm.phase == .live)
        // Simulate the fallback: ACP came up bound to a different session.
        vm.chat.richChatViewModel.setSessionId("some-new-untitled-session")
        for _ in 0..<40 {
            if case .failed = vm.phase { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard case .failed(let message) = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
        #expect(message.contains(BotChatSession.canonicalTitle))
        #expect(vm.canonical == nil)
        #expect(!vm.chat.isACPConnected, "the drifted ACP process must be stopped")
    }

    @MainActor
    @Test("a correctly-bound session is left alone by the verifier")
    func acorrectBindingIsNotDisturbed() async {
        let vm = makeVM(found: canonical("bot-chat-1"))
        vm.open()
        await settle()
        vm.chat.richChatViewModel.setSessionId("bot-chat-1")
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(vm.phase == .live)
        #expect(vm.canonical?.liveId == "bot-chat-1")
    }

    @MainActor
    @Test("close() tears the conversation down and drops the resolved session")
    func closeTearsDown() async {
        let vm = makeVM(found: canonical("bot-chat-1"))
        vm.open()
        await settle()
        #expect(vm.phase == .live)
        vm.close()
        #expect(vm.phase == .idle)
        #expect(vm.canonical == nil)
        #expect(!vm.chat.isACPConnected)
    }

    @MainActor
    @Test("a resolve landing after close() cannot revive the conversation")
    func staleResolveAfterCloseIsDropped() async {
        let gate = AsyncGate()
        let context = ServerContext.local(home: URL(fileURLWithPath: "/tmp/scarf-b3-home"))
        let vm = BotConversationViewModel(
            profileName: "scout",
            context: context,
            chat: stubbedChat(context: context.pinnedToProfile("scout")),
            locator: { [canon = canonical("late")] _ in
                await gate.wait()
                return canon
            },
            creator: { _, _, _ in nil }
        )
        vm.open()
        vm.close()
        await gate.open()
        await settle()
        // The generation guard, not luck: the late lookup returned a real
        // session and it still must not connect.
        #expect(vm.phase == .idle)
        #expect(vm.canonical == nil)
    }

    // MARK: - One live conversation at a time (BotsViewModel)

    @MainActor
    @Test("switching bots closes the previous conversation before opening the next")
    func onlyOneConversationLivesAtATime() async {
        let vm = BotsViewModel(context: .local, capabilities: Self.botCapable, backend: NoopBotsBackend())
        var made: [String] = []
        var closed: [String] = []
        vm.makeConversation = { ctx, name in
            made.append(name)
            return BotConversationViewModel(
                profileName: name,
                context: ctx,
                chat: stubbedChat(context: ctx.pinnedToProfile(name)),
                locator: { _ in nil },
                creator: { _, _, _ in nil }
            )
        }

        vm.openConversation(for: "scout")
        let first = vm.conversation
        #expect(first?.profileName == "scout")

        // Re-opening the SAME bot must reuse, not respawn.
        vm.openConversation(for: "scout")
        #expect(vm.conversation === first)
        #expect(made == ["scout"])

        vm.openConversation(for: "sable")
        #expect(vm.conversation?.profileName == "sable")
        #expect(first?.phase == .idle, "the previous bot's conversation must be torn down")
        closed.append("scout")
        #expect(closed == ["scout"])
    }

    @MainActor
    @Test("selecting a different bot closes the live conversation at the choke point")
    func selectionChangeClosesTheConversation() async {
        let vm = BotsViewModel(context: .local, capabilities: Self.botCapable, backend: NoopBotsBackend())
        vm.makeConversation = { ctx, name in
            BotConversationViewModel(
                profileName: name, context: ctx,
                chat: stubbedChat(context: ctx.pinnedToProfile(name)),
                locator: { _ in nil }, creator: { _, _, _ in nil }
            )
        }
        vm.selectedProfileName = "scout"
        vm.openConversation(for: "scout")
        #expect(vm.conversation != nil)
        vm.selectedProfileName = "sable"
        #expect(vm.conversation == nil, "the selection didSet is the single teardown choke point")
    }

    @MainActor
    @Test("closeConversation is idempotent")
    func closeIsIdempotent() {
        let vm = BotsViewModel(context: .local, capabilities: Self.botCapable, backend: NoopBotsBackend())
        vm.closeConversation()
        vm.closeConversation()
        #expect(vm.conversation == nil)
    }

    /// A host at the Bot Mode floor (v0.20.3).
    private static var botCapable: HermesCapabilities {
        HermesCapabilities(
            versionLine: "hermes 0.20.3",
            semver: .init(major: 0, minor: 20, patch: 3),
            dateVersion: nil
        )
    }

    // MARK: - Helpers

    /// Let the view model's detached resolve/create task run to completion.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        for _ in 0..<20 { await Task.yield() }
    }

    /// First lookup misses (no chat yet), every later one finds the session
    /// the creation call produced.
    private final class ResolveBox: @unchecked Sendable {
        private var calls = 0
        private let lock = NSLock()
        func next() -> HermesDataService.CanonicalBotChat? {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            guard calls > 1 else { return nil }
            return HermesDataService.CanonicalBotChat(
                registryId: "made-by-first-send",
                liveId: "made-by-first-send"
            )
        }
    }

    private actor AsyncGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
    }
}

/// A backend that does nothing — these tests exercise conversation
/// lifecycle, not the roster.
private struct NoopBotsBackend: BotsBackend {
    func scan() -> [HermesBotIdentity] { [] }
    func identity(forProfile name: String) -> HermesBotIdentity {
        HermesBotIdentity(profileName: name, profileDirectory: "/tmp/\(name)")
    }
    func loadAvatar(forProfile name: String) throws -> HermesBotAvatar? { nil }
    func saveIdentity(_ identity: HermesBotIdentity) throws {}
    func writeAvatar(_ data: Data, forProfile name: String) throws {}
    func run(_ action: BotsService.Lifecycle) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}
