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

    init(
        profileName: String,
        context: ServerContext,
        chat: ChatViewModel? = nil,
        locator: (@Sendable (ServerContext) async -> HermesDataService.CanonicalBotChat?)? = nil,
        creator: (@Sendable (ServerContext, String, String) async -> String?)? = nil
    ) {
        self.profileName = profileName
        let pinned = context.pinnedToProfile(profileName)
        self.context = pinned
        let vm: ChatViewModel
        if let chat {
            // Injected by a test, which brings its own factory.
            vm = chat
        } else {
            vm = ChatViewModel(context: pinned)
            // Pin the ACP subprocess to the bot's profile. Without this the
            // context alone would point reads at the bot while the AGENT
            // ran as the user's active profile — the transcript and the
            // entity writing into it would be two different Hermes
            // installs.
            vm.acpClientFactory = { ctx, projectCwd in
                ACPClient.forMacApp(context: ctx, projectCwd: projectCwd, profile: profileName)
            }
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

    private func resolveAndConnect() {
        generation += 1
        let intent = generation
        phase = .resolving
        work?.cancel()
        let ctx = context
        let lookup = locator
        work = Task { [weak self] in
            let found = await lookup(ctx)
            guard let self, !Task.isCancelled, self.generation == intent else { return }
            if let found {
                self.canonical = found
                self.phase = .live
                // `liveId` (the compression tip), never `registryId`: on a
                // long-lived forever-chat the titled row is often a dead
                // compressed ancestor.
                self.chat.resumeSession(found.liveId, origin: .bots)
                await self.verifyCanonicalBinding(expected: found.liveId, intent: intent)
            } else {
                self.canonical = nil
                self.phase = .noConversationYet
            }
        }
    }

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
    private func verifyCanonicalBinding(expected: String, intent: Int) async {
        // `richChatViewModel.sessionId` is assigned exactly once per start,
        // at the moment ACP reaches ready. Poll for it rather than racing
        // it; `ChatViewModel`'s own 90s-per-stage watchdog owns the
        // never-ready case, so this only needs to outlast it.
        for _ in 0..<1_000 {
            if Task.isCancelled || generation != intent { return }
            if let bound = chat.richChatViewModel.sessionId {
                guard bound != expected else { return }
                chat.stopACP()
                canonical = nil
                phase = .failed(
                    "Hermes couldn’t open this bot’s “\(BotChatSession.canonicalTitle)” session, "
                    + "and Scarf won’t send messages into a replacement — they wouldn’t reach the bot. "
                    + "Check that the profile’s state.db is readable and try again."
                )
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
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
        canonical = nil
        phase = .idle
    }

    // MARK: - Sending

    /// Send `text`. On a bot that already has a Bot Chat this is an
    /// ordinary streamed ACP turn. On a bot that does not, the first
    /// message is what creates the conversation — see
    /// `createCanonicalBotChat`.
    func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
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
    /// resolves it), but it also appears in the ordinary Sessions list, and
    /// it is renameable there — which WOULD orphan it, so the UI says so.
    nonisolated static func createCanonicalBotChat(
        context: ServerContext,
        profile: String,
        text: String
    ) async -> String? {
        guard let name = HermesProfileScope.normalize(profile) else {
            return "“\(profile)” isn’t a valid Hermes profile name."
        }
        return await Task.detached {
            let transport = context.makeTransport()
            // A file, not an argument: the body is arbitrary user text and
            // the remote path runs it through `bash -lc`. This is the same
            // reason Hermes' own tool stopped hand-assembling the command
            // (the quoting traps its docstring cites, #91339/#91304).
            let path = "/tmp/scarf-bot-chat-\(UUID().uuidString).txt"
            defer { try? transport.removeFile(path) }
            do {
                try transport.writeFile(path, data: Data(text.utf8))
            } catch {
                return "Couldn’t stage the message for \(name): \(error.localizedDescription)"
            }
            let result = context.runHermes(
                [
                    "-p", name,
                    "chat",
                    "--in", "~",
                    "-c", BotChatSession.canonicalTitle,
                    "--create-if-missing",
                    "-Q",
                    "--query-file", path
                ],
                timeout: 300
            )
            guard result.exitCode == 0 else {
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "Couldn’t start \(name)’s conversation (hermes exited \(result.exitCode))."
                    : detail
            }
            return nil
        }.value
    }
}
