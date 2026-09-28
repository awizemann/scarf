import Foundation
import ScarfCore

/// Drives one bot's canonical "Bot Chat" conversation (B3).
///
/// Composition, not reimplementation: this owns a `ChatViewModel` built
/// against a **profile-pinned** `ServerContext`, so the entire main-Chat
/// stack — streaming tokens, thinking, tool cards, permission prompts,
/// slash commands, history hydration — comes along unchanged, but every
/// path it touches (the ACP subprocess, `state.db`, session attribution)
/// resolves inside the bot's own profile directory.
///
/// Two things make it "the bot's" conversation rather than a chat that
/// happens to be pointed elsewhere:
/// 1. the ACP process is launched as `hermes -p <bot> acp`, so the agent
///    on the other end has the bot's SOUL, skills, memory and credentials;
/// 2. the session opened is the one titled exactly `"Bot Chat"` in that
///    profile's `state.db` — the only title for which Hermes injects the
///    bot-mode teammate protocol (`agent/system_prompt.py:737-747`).
///
/// **Two transports, decided by the session's birth** (see ``Delivery``):
/// Hermes' ACP adapter only restores sessions with `source == "acp"`
/// (`acp_adapter/session.py:527`), so the streaming stack above applies
/// only to an ACP-born Bot Chat. The canonical Bot Chat is almost never
/// that — Scarf creates it over the CLI, Hermes Desktop over the gateway —
/// so the common case converses over the CLI transport with `state.db`
/// hydration instead: honest, un-streamed, and in the real Bot Chat.
@Observable
@MainActor
final class BotConversationViewModel {

    /// Where the conversation is in its lifecycle. `noConversationYet` is a
    /// normal resting state, not an error — a bot that nobody has messaged
    /// has no Bot Chat, and Scarf does not speculatively create one.
    enum Phase: Equatable {
        case idle
        case resolving
        case noConversationYet
        case creating
        case live
        case failed(String)
    }

    /// How prompts travel to the bot and how replies come back. Decided per
    /// resolve from the live session's `sessions.source`, because Hermes'
    /// ACP adapter can only `session/load` a session that was CREATED over
    /// ACP (`acp_adapter/session.py:527`, v2026.8.31 — `_restore` returns
    /// `nil` for any other `source`, and `fork_session` funnels through the
    /// same gate).
    ///
    /// - `acpStreaming`: the session is ACP-born; resume it over ACP and
    ///   stream tokens live. Guarded by `verifyCanonicalBinding`.
    /// - `cliTransport`: the session is CLI- or gateway-born — which is
    ///   every Bot Chat Scarf itself creates (`createCanonicalBotChat`) and
    ///   every one Hermes Desktop creates (gateway `session.create`,
    ///   canonical-chat.ts:334-338). Each prompt is delivered exactly the
    ///   way Hermes' own Bot Mode DM tool documents (`tools/bot_mode_dm.py`:
    ///   `hermes -p <bot> chat -c "Bot Chat" …`), and the transcript is
    ///   hydrated + polled from the profile's `state.db`. No token
    ///   streaming — replies appear when the turn completes — but the turn
    ///   runs in the real Bot Chat with the bot-mode protocol active,
    ///   which streaming over a stray `session/new` never would.
    enum Delivery: Equatable {
        case acpStreaming
        case cliTransport
    }

    let profileName: String

    /// The bot's handle (`default` → `hermes`), used for attribution.
    var handle: String { BotChatSession.handle(forProfile: profileName) }

    /// The profile-pinned context. Everything downstream derives from it.
    let context: ServerContext

    /// The reused main-Chat engine. `private(set)` and exposed because the
    /// transcript views read it out of the environment.
    private(set) var chat: ChatViewModel

    private(set) var phase: Phase = .idle

    /// The resolved canonical chat, once found.
    private(set) var canonical: HermesDataService.CanonicalBotChat?

    /// The transport of the current `.live` conversation, nil otherwise.
    /// Views read it for the honest no-streaming caption.
    private(set) var delivery: Delivery?

    /// Monotonic token so a slow resolve for a bot the user has already
    /// navigated away from can never land on a newer open. Same shape as
    /// `BotsViewModel`'s load generation and `ChatViewModel`'s start intent
    /// — overlapping opens are the normal case when clicking down a roster.
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private var work: Task<Void, Never>?

    /// Seam for the canonical-chat lookup. Production reads the bot
    /// profile's `state.db` through `HermesDataService`; tests inject a
    /// closure so the resolve/create/teardown logic runs with no database
    /// and no `hermes` binary.
    @ObservationIgnored
    var locator: @Sendable (ServerContext) async -> HermesDataService.CanonicalBotChat?

    /// Seam for the session-creation CLI. Returns nil on success, or a
    /// user-presentable failure message.
    @ObservationIgnored
    var creator: @Sendable (ServerContext, String, String) async -> String?

    /// Seam for one CLI-transport delivery: context, profile, text and the
    /// staging directory the message file goes in. The directory is what
    /// names the running process for Stop (`interruptCLITurn`). Built from
    /// an injected `creator` in tests, so they keep working unchanged.
    @ObservationIgnored
    var cliDeliverer: @Sendable (ServerContext, String, String, String) async -> String?

    /// Seam for Stop on a CLI-transport turn: context and the turn's
    /// staging directory. Production interrupts the process on the host
    /// that runs it (`interruptCLITurn`); tests record the call.
    @ObservationIgnored
    var cliTurnStopper: @Sendable (ServerContext, String) async -> Void = { ctx, dir in
        await BotConversationViewModel.interruptCLITurn(context: ctx, stagingDirectory: dir)
    }

    /// Staging directories of the CLI-transport turns still running. Each
    /// names its `hermes chat -Q` process through `--query-file`. Observed:
    /// the composer's Stop button follows it.
    private(set) var cliTurnDirectories: Set<String> = []

    /// Turns the user stopped, so their non-zero exit reads as a stop, not
    /// a failure.
    @ObservationIgnored
    private var stoppedCLITurns: Set<String> = []

    /// How the bot's ACP client is built. **Always** goes through this — the
    /// production default and every test alike — so the profile wiring below
    /// is exercised rather than bypassed. (The audit's "test theater"
    /// finding: injecting a whole pre-wired `ChatViewModel` skipped the
    /// factory assignment entirely, so nothing verified that the ACP process
    /// is pinned to the bot.)
    typealias ACPClientMaker = @Sendable (ServerContext, String?, String) -> ACPClient

    /// Nonisolated, thread-safe handle on the last ACP client this
    /// conversation spawned, so ``deinit`` can reap the `hermes acp`
    /// subprocess. `deinit` cannot hop to `@MainActor` to call
    /// `chat.stopACP()`, and `AppCoordinator` has no teardown hook, so
    /// without this a hard dealloc (window closed, coordinator rebuilt on a
    /// server switch) orphans a live subprocess for the life of the app.
    /// `ACPClient` is an actor, hence `Sendable`, hence safe to hand to the
    /// detached task `deinit` starts; `stop()` closes the channel, which
    /// terminates the process.
    private nonisolated final class ACPHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var client: ACPClient?
        func set(_ newClient: ACPClient) {
            lock.lock(); defer { lock.unlock() }
            client = newClient
        }
        func take() -> ACPClient? {
            lock.lock(); defer { lock.unlock() }
            let current = client
            client = nil
            return current
        }
    }

    @ObservationIgnored private nonisolated let acpHandle = ACPHandle()

    init(
        profileName: String,
        context: ServerContext,
        chat: ChatViewModel? = nil,
        locator: (@Sendable (ServerContext) async -> HermesDataService.CanonicalBotChat?)? = nil,
        creator: (@Sendable (ServerContext, String, String) async -> String?)? = nil,
        acpClientMaker: ACPClientMaker? = nil
    ) {
        self.profileName = profileName
        let pinned = context.pinnedToProfile(profileName)
        self.context = pinned
        let vm = chat ?? ChatViewModel(context: pinned)
        // Pin the ACP subprocess to the bot's profile. Without this the
        // context alone would point reads at the bot while the AGENT ran as
        // the user's active profile — the transcript and the entity writing
        // into it would be two different Hermes installs. Assigned
        // unconditionally, including over an injected `ChatViewModel`: this
        // wiring is the whole point of the type, so nothing gets to opt out
        // of it.
        let make: ACPClientMaker = acpClientMaker ?? { ctx, projectCwd, profile in
            ACPClient.forMacApp(context: ctx, projectCwd: projectCwd, profile: profile)
        }
        let handle = acpHandle
        vm.acpClientFactory = { ctx, projectCwd in
            let client = make(ctx, projectCwd, profileName)
            handle.set(client)
            return client
        }
        self.chat = vm
        self.locator = locator ?? { ctx in
            let service = HermesDataService(context: ctx)
            defer { Task { await service.close() } }
            guard await service.open() else { return nil }
            return await service.locateCanonicalBotChat()
        }
        self.creator = creator ?? { ctx, profile, text in
            await Self.createCanonicalBotChat(context: ctx, profile: profile, text: text)
        }
        if let creator {
            self.cliDeliverer = { ctx, profile, text, _ in await creator(ctx, profile, text) }
        } else {
            self.cliDeliverer = { ctx, profile, text, dir in
                await Self.createCanonicalBotChat(context: ctx, profile: profile, text: text, stagingDirectory: dir)
            }
        }
    }

    // MARK: - Lifecycle

    /// Resolve and connect. Safe to call repeatedly for the same bot — an
    /// already-live conversation is left alone rather than respawning a
    /// second `hermes acp` behind the first.
    func open() {
        guard BotsService.isAddressableProfile(profileName) else {
            phase = .failed("“\(profileName)” isn’t a valid Hermes profile name, so Scarf won’t open a conversation for it.")
            return
        }
        if phase == .live || phase == .resolving || phase == .creating { return }
        resolveAndConnect()
    }

    /// - Parameter pendingText: a message to send once the conversation is
    ///   connected AND its binding verified — the send that found the ACP
    ///   connection gone (see `ChatViewModel.autoStartInterceptor`).
    private func resolveAndConnect(thenSend pendingText: String? = nil) {
        generation += 1
        let intent = generation
        if pendingText != nil { unsentMessage = nil }
        phase = .resolving
        work?.cancel()
        let ctx = context
        let lookup = locator
        work = Task { [weak self] in
            let found = await lookup(ctx)
            guard let self, !Task.isCancelled, self.generation == intent else { return }
            if let found {
                self.canonical = found
                if found.isACPBorn {
                    // ACP-born session: Hermes CAN `session/load` it, so the
                    // full streaming stack applies.
                    self.delivery = .acpStreaming
                    self.chat.sendRouter = nil
                    // ACP turns stop through the chat's own `session/cancel`.
                    self.chat.stopRouter = nil
                    // A send with no ACP client (the reconnect ladder gave
                    // up) must not auto-start blind: that path falls back to
                    // `session/new` when the load fails and never checks
                    // the result is still the Bot Chat. Re-resolve and
                    // re-verify instead, then send.
                    self.chat.autoStartInterceptor = { [weak self] text, _ in
                        guard let self, self.delivery == .acpStreaming, case .live = self.phase else { return false }
                        self.resolveAndConnect(thenSend: text)
                        return true
                    }
                    self.phase = .live
                    // `liveId` (the compression tip), never `registryId`: on a
                    // long-lived forever-chat the titled row is often a dead
                    // compressed ancestor.
                    self.chat.resumeSession(found.liveId, origin: .bots)
                    let bound = await self.verifyCanonicalBinding(expected: found.liveId, intent: intent)
                    if bound, let pendingText, self.generation == intent {
                        // Already counted as sent when it was intercepted.
                        self.chat.sendText(pendingText, images: [], recordAnalytics: false)
                    } else if self.generation == intent {
                        self.keepUnsent(pendingText)
                    }
                } else {
                    // CLI/gateway-born session — the normal case for every
                    // Bot Chat Scarf or Hermes Desktop creates. ACP's
                    // `_restore` refuses these (`acp_adapter/session.py:527`),
                    // so a `resumeSession` here would fall back to
                    // `session/new` and `verifyCanonicalBinding` would
                    // (rightly) kill the conversation — the release-blocking
                    // "Couldn't open this conversation" loop. Converse over
                    // the CLI transport instead.
                    self.chat.autoStartInterceptor = nil
                    await self.connectViaCLITransport(found, intent: intent)
                    if let pendingText, self.generation == intent, case .live = self.phase {
                        self.deliverViaCLI(pendingText)
                    } else if self.generation == intent {
                        self.keepUnsent(pendingText)
                    }
                }
            } else {
                self.canonical = nil
                self.delivery = nil
                self.chat.sendRouter = nil
                self.chat.stopRouter = nil
                self.chat.autoStartInterceptor = nil
                self.phase = .noConversationYet
                self.keepUnsent(pendingText)
            }
        }
    }

    /// A message typed after the connection dropped, which the reopen did
    /// not deliver (the Bot Chat is gone, or could not be verified). The
    /// composer already cleared it and no bubble was added, so without this
    /// it simply vanished. Shown with the failure until the next send.
    private(set) var unsentMessage: String?

    private func keepUnsent(_ text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        unsentMessage = text
    }

    // MARK: - CLI transport (non-ACP-born Bot Chats)

    /// Attach to a Bot Chat that ACP cannot load: hydrate the transcript
    /// from the profile's `state.db` and route every send through the CLI.
    ///
    /// No ACP process is spawned at all for this delivery mode — there is
    /// nothing for one to do (it could not load the session, and prompting
    /// it would write into the wrong session). `verifyCanonicalBinding`
    /// never runs here for the same reason: there is no ACP binding to
    /// verify, and the identity guarantee comes from the CLI's own
    /// `-c "Bot Chat"` targeting instead.
    private func connectViaCLITransport(
        _ found: HermesDataService.CanonicalBotChat,
        intent: Int
    ) async {
        delivery = .cliTransport
        // Route EVERY ChatViewModel send path (composer, goal pill, quick
        // commands) through the CLI so nothing can trigger the ACP
        // auto-start fallback and mint a stray untitled session.
        chat.sendRouter = { [weak self] text, _ in
            guard let self, self.delivery == .cliTransport else { return false }
            self.deliverViaCLI(text)
            return true
        }
        // The composer's Stop ends the running `hermes chat -Q` process
        // instead of sending an ACP cancel (there is no ACP session here).
        chat.stopRouter = (
            canStop: { [weak self] in
                guard let self else { return false }
                return self.delivery == .cliTransport && !self.cliTurnDirectories.subtracting(self.stoppedCLITurns).isEmpty
            },
            stop: { [weak self] in self?.stopCLITurns() ?? false }
        )
        let rich = chat.richChatViewModel
        rich.setSessionId(found.liveId)
        phase = .live
        await rich.loadSessionHistory(sessionId: found.liveId)
        // The resolve may have been superseded mid-hydration (bot switch,
        // close). The generation check is what keeps a slow hydration from
        // resurrecting a closed conversation's UI state.
        guard !Task.isCancelled, generation == intent else { return }
    }

    /// Deliver one prompt over the transport Hermes' own Bot Mode uses
    /// (`tools/bot_mode_dm.py`): the same `hermes -p <bot> chat -c "Bot
    /// Chat" --create-if-missing -Q --query-file` invocation that created
    /// the session — `--create-if-missing` makes it a pure append when the
    /// session already exists. The transcript catches up by polling
    /// `state.db` (the terminal-mode machinery `RichChatViewModel` already
    /// has), so the reply appears when the turn completes rather than
    /// streaming token by token.
    private func deliverViaCLI(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard case .live = phase, delivery == .cliTransport else { return }
        let intent = generation
        let rich = chat.richChatViewModel
        // No `notePromptWire` here, on purpose: its keys assume the ACP
        // adapter's slash dispatch (`/help`, `/model`, … store no user row).
        // The quiet CLI turn has none — `_run_quiet_single_query` hands the
        // text straight to `run_conversation`
        // (`hermes_cli/cli_single_query.py:180-204` @ v2026.9.24), so the
        // row is the text as sent, which is exactly the key
        // `addUserMessage` already records.
        rich.addUserMessage(text: text)
        rich.markPromptSent()
        rich.markAgentWorking()
        let ctx = context
        let profile = profileName
        let deliver = cliDeliverer
        let dir = Self.newStagingDirectory()
        cliTurnDirectories.insert(dir)
        // NOT `work`: a delivery must not be cancelled by a concurrent
        // resolve bookkeeping path the way lifecycle tasks are — the CLI
        // process is already running and the turn is already Hermes' —
        // but it must still notice `close()` via the generation check.
        Task { [weak self] in
            let failure = await deliver(ctx, profile, text, dir)
            guard let self else { return }
            self.cliTurnDirectories.remove(dir)
            // A turn that finished cleanly before the stop reached it is
            // an ordinary reply, not a stopped turn.
            let stopped = self.stoppedCLITurns.remove(dir) != nil && failure != nil
            guard self.generation == intent else { return }
            let rich = self.chat.richChatViewModel
            if stopped {
                // The user stopped it. Show what Hermes saved before the
                // interrupt (it persists the turn on the way out), then
                // end the working state and say the turn was stopped.
                // Not an error: no banner.
                await rich.refreshMessages()
                guard self.generation == intent, self.cliTurnDirectories.isEmpty else { return }
                rich.cancelPendingSend()
                rich.appendTurnStoppedNote()
                return
            }
            if let failure {
                // The conversation itself is fine — the transcript is
                // real and retrying is safe — so surface the failure in
                // the chat's error banner rather than tearing the whole
                // phase down to `.failed`. Read the transcript once more
                // first: a turn that failed part-way can still have saved
                // the prompt and part of a reply, and with the poll
                // stopped nothing else would show it until the chat was
                // reopened.
                await rich.refreshMessages()
                guard self.generation == intent else { return }
                rich.cancelPendingSend()
                rich.acpError = failure
            } else {
                rich.scheduleRefresh()
            }
        }
    }

    /// Stop every CLI-transport turn still running (the composer's Stop).
    /// Returns false when there is nothing to stop.
    @discardableResult
    func stopCLITurns() -> Bool {
        guard delivery == .cliTransport else { return false }
        let running = cliTurnDirectories.subtracting(stoppedCLITurns)
        guard !running.isEmpty else { return false }
        stoppedCLITurns.formUnion(running)
        let ctx = context
        let stopper = cliTurnStopper
        for dir in running {
            Task { await stopper(ctx, dir) }
        }
        return true
    }

    /// A fresh per-send staging directory. Its UUID is what makes the
    /// process findable for Stop, so it is minted here, never taken from
    /// input.
    nonisolated static func newStagingDirectory() -> String {
        "/tmp/scarf-bot-chat-\(UUID().uuidString)"
    }

    /// The `pkill -f` pattern for the turn staged in `stagingDirectory`.
    /// The first `/` sits in a bracket class so the pattern never matches
    /// the command line of the shell that runs `pkill` — on a remote host
    /// that shell's arguments contain the pattern text itself.
    nonisolated static func cliTurnProcessPattern(stagingDirectory: String) -> String? {
        guard stagingDirectory.hasPrefix("/tmp/scarf-bot-chat-"),
              stagingDirectory.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" }) else { return nil }
        return "[/]" + stagingDirectory.dropFirst()
    }

    /// The shell line that interrupts one turn's process with `signal`.
    nonisolated static func interruptCommand(stagingDirectory: String, signal: String) -> String? {
        guard let pattern = cliTurnProcessPattern(stagingDirectory: stagingDirectory),
              ["INT", "TERM", "KILL"].contains(signal) else { return nil }
        return "pkill -\(signal) -f '\(pattern)'"
    }

    /// End the `hermes chat -Q` turn staged in `stagingDirectory`, on the
    /// host it runs on (over SSH for a remote bot, where ending the local
    /// `ssh` would leave the remote turn running). The process is found by
    /// its unique `--query-file` path.
    ///
    /// SIGINT first: `hermes chat -Q` routes it through `agent.interrupt()`
    /// with a grace period for tool subprocesses, then saves the session
    /// and exits 130 (`_install_single_query_signal_handlers`,
    /// hermes_cli/cli_single_query.py:365-416; the `KeyboardInterrupt` arm
    /// at :205-211 @ v2026.9.24) — and on any Hermes, Python turns SIGINT
    /// into that same `KeyboardInterrupt`. If the process is still there
    /// after `stopEscalationDelay`, SIGTERM, then SIGKILL.
    ///
    /// A Stop pressed while the message is still being staged finds no
    /// process yet, so SIGINT is retried for a few seconds before giving up.
    nonisolated static func interruptCLITurn(context: ServerContext, stagingDirectory: String) async {
        func send(_ signal: String) async -> Int32 {
            guard let command = interruptCommand(stagingDirectory: stagingDirectory, signal: signal) else { return 1 }
            return await OffPool.run { () -> Int32 in
                let result = try? context.makeTransport().runProcess(
                    executable: "/bin/sh", args: ["-c", command], stdin: nil, timeout: 15
                )
                return result?.exitCode ?? -1
            }
        }
        // `pkill` exits 0 when it signalled something, 1 when nothing matched.
        var interrupted = false
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            if await send("INT") == 0 { interrupted = true; break }
        }
        guard interrupted else { return }
        for signal in ["TERM", "KILL"] {
            try? await Task.sleep(nanoseconds: UInt64(stopEscalationDelay * 1_000_000_000))
            if await send(signal) == 1 { return }
        }
    }

    /// How long a stopped turn gets to exit before the next, harder signal.
    nonisolated static let stopEscalationDelay: TimeInterval = 10

    /// Confirm the ACP session Scarf actually ended up bound to is the
    /// canonical Bot Chat, and refuse the conversation if it is not.
    ///
    /// **The failure this exists for.** `ChatViewModel.startACPSession`
    /// falls back to `session/new` when `session/load` fails — a good
    /// default for ordinary chat (a CLI-only or cron session can't be
    /// ACP-loaded, so it opens a fresh runtime and replays the transcript
    /// from `state.db`). For a bot it is silently wrong in two ways at
    /// once: prompts would be persisted into a **new, untitled** session
    /// rather than the Bot Chat, and because Hermes gates the entire
    /// bot-mode teammate protocol on the session title
    /// (`agent/system_prompt.py:737-747`), the agent answering would not be
    /// in bot mode at all. The user would see a working chat that is not
    /// the bot's conversation and is quietly accumulating a stray session
    /// in the bot's profile.
    ///
    /// Rather than change main Chat's fallback — it is right for main Chat
    /// — the binding is verified here and the conversation is stopped if it
    /// drifted. Failing loudly is the only safe outcome: a bot chat that
    /// silently is not the bot chat is worse than no bot chat.
    /// True when the chat bound to `expected`; false when superseded or
    /// when it failed (and the conversation was torn down).
    @discardableResult
    private func verifyCanonicalBinding(expected: String, intent: Int) async -> Bool {
        // Poll `richChatViewModel.sessionId` rather than racing the start;
        // `ChatViewModel`'s own 90s-per-stage watchdog owns the never-ready
        // case, so this only needs to outlast it. A matching id is only
        // accepted once the start has FINISHED: `loadSessionHistory` names
        // the requested id before a `session/load` fallback re-points the
        // transcript at the new session, so a mid-start match can be the
        // very drift this guards against (R16b review).
        for _ in 0..<1_000 {
            if Task.isCancelled || generation != intent { return false }
            if let bound = chat.richChatViewModel.sessionId {
                if bound == expected {
                    if !chat.isStartingSession && chat.isACPConnected { return true }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                chat.stopACP()
                canonical = nil
                delivery = nil
                phase = .failed(
                    "Hermes couldn’t reopen this bot’s “\(BotChatSession.canonicalTitle)” session for "
                    + "live streaming, and Scarf won’t send messages into a replacement — they wouldn’t "
                    + "reach the bot. Try again; Scarf will re-check which transport the conversation needs."
                )
                return false
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Fell out of the poll loop (~200s) without ACP ever reporting a
        // session id. Previously this returned silently, leaving the UI in
        // `.live` with a composer that would send prompts into a session
        // that was never confirmed to be the Bot Chat — the exact outcome
        // the verifier exists to prevent, reached by timeout instead of by
        // drift. Fail the same way, loudly.
        guard !Task.isCancelled, generation == intent else { return false }
        chat.stopACP()
        canonical = nil
        delivery = nil
        phase = .failed(
            "Hermes never finished opening this bot’s “\(BotChatSession.canonicalTitle)” session, "
            + "so Scarf can’t confirm messages would reach the bot. Check that `hermes acp` starts "
            + "for this profile, then try again."
        )
        return false
    }

    /// Tear the conversation down: cancel any in-flight resolve and stop
    /// the ACP subprocess. MUST be called when the user leaves this bot,
    /// leaves the Bots section, or closes the window — nothing else will do
    /// it, because `AppCoordinator` caches feature view models for the life
    /// of the window and never calls a teardown hook.
    func close() {
        generation += 1
        work?.cancel()
        work = nil
        chat.stopACP()
        // CLI-transport leftovers: the DB poll timer `markAgentWorking`
        // started (stopACP knows nothing about it) and the send router —
        // a `ChatViewModel` outliving this conversation must go back to
        // ordinary behavior.
        chat.richChatViewModel.cancelPendingSend()
        chat.sendRouter = nil
        chat.stopRouter = nil
        chat.autoStartInterceptor = nil
        delivery = nil
        _ = acpHandle.take()
        canonical = nil
        phase = .idle
    }

    /// Last-resort reaper. `close()` is the intended teardown and does this
    /// properly (bounded `session/cancel`, transcript finalization); this
    /// only covers the paths where nothing calls it — the window closing, or
    /// `AppCoordinator` being rebuilt on a server switch. Kills the process
    /// and nothing else: no `self` is captured (it is already deallocating),
    /// and the detached task holds the actor alone.
    deinit {
        guard let client = acpHandle.take() else { return }
        Task.detached { await client.stop() }
    }

    // MARK: - Sending

    /// Send `text`. On a bot that already has a Bot Chat this is an
    /// ordinary streamed ACP turn. On a bot that does not, the first
    /// message is what creates the conversation — see
    /// `createCanonicalBotChat`.
    func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        unsentMessage = nil
        switch phase {
        case .live:
            chat.sendText(text)
        case .noConversationYet, .failed:
            createThenConnect(text)
        case .idle, .resolving, .creating:
            break
        }
    }

    private func createThenConnect(_ text: String) {
        // Re-checked here, not just in `open()`: `send` is reachable from
        // the `.failed` state, and creation is the one path that runs a
        // `hermes` subprocess with the profile name in its argv.
        guard BotsService.isAddressableProfile(profileName) else {
            phase = .failed("“\(profileName)” isn’t a valid Hermes profile name.")
            return
        }
        generation += 1
        let intent = generation
        phase = .creating
        work?.cancel()
        let ctx = context
        let profile = profileName
        let make = creator
        work = Task { [weak self] in
            let failure = await make(ctx, profile, text)
            guard let self, !Task.isCancelled, self.generation == intent else { return }
            if let failure {
                self.phase = .failed(failure)
                return
            }
            self.resolveAndConnect()
        }
    }

    /// The argv that creates (or continues) `profile`'s canonical Bot Chat,
    /// or `nil` when `profile` isn't a valid Hermes profile id. Pure, so the
    /// composition is testable without spawning anything.
    ///
    /// `isValidName`, not `normalize`: `normalize` maps `default` to nil (it
    /// means "the root home"), which left the default profile's bot unable
    /// to start a conversation at all (S13-F2). `default` is a valid bot and
    /// gets `-p default`: ``HermesProfileScope/profileFlag(_:)`` always
    /// emits the flag, because without it the default bot would follow the
    /// host's sticky `active_profile`. Hermes' own Bot Mode passes it the
    /// same way (`tools/bot_mode_dm.py:282` @ v2026.9.24).
    nonisolated static func canonicalBotChatArguments(profile: String, queryFile: String) -> [String]? {
        guard HermesProfileScope.isValidName(profile) else { return nil }
        return HermesProfileScope.profileFlag(profile) + [
            "chat",
            "--in", "~",
            "-c", BotChatSession.canonicalTitle,
            "--create-if-missing",
            "-Q",
            "--query-file", queryFile
        ]
    }

    /// Create the profile's canonical Bot Chat by running the transport
    /// Hermes itself documents for Bot Mode delivery
    /// (`tools/bot_mode_dm.py:32-33`, argv verified against the v2026.8.31
    /// argparse):
    ///
    ///     hermes -p <bot> chat --in ~ -c "Bot Chat" --create-if-missing \
    ///            -Q --query-file <tmp>
    ///
    /// **Why not ACP.** ACP has no way to create this session. Its
    /// `session/new` takes a `cwd` and nothing else — no title, no hidden
    /// flag (`acp_adapter/`, and `ACPClient.newSession(cwd:)` mirrors it) —
    /// so an ACP-minted session is untitled, and an untitled session is not
    /// a Bot Chat at all: `agent/system_prompt.py:737-747` gates the entire
    /// bot-mode teammate protocol on the title matching exactly. Scarf
    /// cannot title it afterwards either — `hermes sessions rename` is
    /// refused for this title, deliberately, because the name is the
    /// identity. So ACP would silently produce a stray untitled session and
    /// a bot that is not in bot mode.
    ///
    /// **Known deviation from Hermes Desktop, on purpose.** The desktop
    /// creates this session through the *gateway* (`session.create` with
    /// `hidden: true`, canonical-chat.ts:334-338), so its Bot Chat is born
    /// hidden. Neither mechanism available to Scarf can do that: the CLI's
    /// `--create-if-missing` path (`hermes_cli/main._create_titled_session`,
    /// :1854-1877) calls `create_session` + `set_session_title` and never
    /// touches `hidden`, and `set_session_hidden` has no CLI verb at all —
    /// it is reachable only from the gateway/REST layer. Scarf will not
    /// write to `state.db` to close the gap; it is read-only, and this is a
    /// row Hermes owns. The consequence is cosmetic and bounded: the chat
    /// is correctly titled (so the protocol injects and every other surface
    /// resolves it), but it also appears in the Sessions list *of this bot's
    /// own profile* (that is where its `state.db` lives — it does NOT appear
    /// under whatever profile the window is otherwise scoped to), and it is
    /// renameable there.
    ///
    /// A rename WOULD orphan it: `SessionDB._set_session_title` (:10210)
    /// refuses the rename only for a session that is both titled "Bot Chat"
    /// AND hidden, so the server-side guard never fires for a Scarf-created
    /// one. Both of Scarf's rename paths — `SessionsViewModel.confirmRename`
    /// and `ChatSessionListPane.commitRename` — therefore raise a
    /// confirmation first, gated on
    /// ``BotChatSession/renameNeedsConfirmation(currentTitle:newTitle:)``.
    /// (This docstring previously claimed a warning that did not yet exist;
    /// go/no-go blocking condition 3c.)
    /// How long one CLI-transport Bot Chat turn may run before Scarf ends
    /// it. A bound only because every subprocess needs one (charter C10):
    /// it must never cut short a turn a user is waiting on.
    ///
    /// It was 300 s, which killed any bot turn that ran tools for more
    /// than five minutes (a build, several web extracts, a delegate) and
    /// lost the reply. Hermes' own Bot Mode runs this same command with no
    /// limit at all: `_run_local_turn` is a plain `subprocess.run` with no
    /// timeout (tools/bot_mode_dm.py:411-421 @ v2026.9.24), inside a
    /// background runner nothing kills (`_start_delivery`/`_spawn_delivery`,
    /// :595-695). `hermes chat -Q` has no turn cap of its own either
    /// (hermes_cli/cli_single_query.py:180-260). The composer shows the
    /// turn as working, with its elapsed time, for as long as it runs.
    nonisolated static let cliTurnCeiling: TimeInterval = 24 * 60 * 60

    nonisolated static func createCanonicalBotChat(
        context: ServerContext,
        profile: String,
        text: String,
        stagingDirectory: String = newStagingDirectory()
    ) async -> String? {
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = "“\(profile)” isn’t a valid Hermes profile name."
        // Checked before anything is staged; the argv builder re-checks.
        guard HermesProfileScope.isValidName(name) else { return invalid }
        return await OffPool.run {
            let transport = context.makeTransport()
            // A file, not an argument: the body is arbitrary user text and
            // the remote path runs it through `bash -lc`. This is the same
            // reason Hermes' own tool stopped hand-assembling the command
            // (the quoting traps its docstring cites, #91339/#91304).
            //
            // `/tmp` is world-readable and world-writable, and the message
            // is the user's private prompt to their agent. Stage it inside a
            // 0700 directory of our own so it is unreadable to other users
            // for its whole lifetime — the directory mode is set BEFORE the
            // file exists, which the file's own 0600 (applied right after,
            // belt-and-braces) cannot be. Both `chmod`s are best-effort:
            // failing to tighten permissions must not break the send, but it
            // must also not be silent about which layer is load-bearing.
            let dir = stagingDirectory
            let path = "\(dir)/message.txt"
            defer {
                try? transport.removeFile(path)
                _ = try? transport.runProcess(executable: "/bin/rm", args: ["-rf", dir], stdin: nil, timeout: 15)
            }
            do {
                try transport.createDirectory(dir)
            } catch {
                return "Couldn’t stage the message for \(name): \(error.localizedDescription)"
            }
            _ = try? transport.runProcess(executable: "/bin/chmod", args: ["700", dir], stdin: nil, timeout: 15)
            do {
                // UNGUARDED-WRITE(C): staging file in a freshly minted per-send 0700 temp dir.
                try transport.unguardedWriteFile(path, data: Data(text.utf8))
            } catch {
                return "Couldn’t stage the message for \(name): \(error.localizedDescription)"
            }
            _ = try? transport.runProcess(executable: "/bin/chmod", args: ["600", path], stdin: nil, timeout: 15)
            guard let argv = canonicalBotChatArguments(profile: name, queryFile: path) else {
                return invalid
            }
            let started = Date()
            let result = context.runHermes(argv, timeout: cliTurnCeiling)
            guard result.exitCode == 0 else {
                if Date().timeIntervalSince(started) >= cliTurnCeiling - 1 {
                    return "Scarf stopped waiting for \(name)’s reply after \(Int(cliTurnCeiling / 3600)) hours and ended the turn. Anything Hermes saved before then is in the conversation."
                }
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "Couldn’t start \(name)’s conversation (hermes exited \(result.exitCode))."
                    : detail
            }
            return nil
        }
    }
}
