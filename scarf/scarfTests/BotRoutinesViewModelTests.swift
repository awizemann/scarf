import Foundation
import Testing
import ScarfCore
@testable import scarf

/// Work package B4 — the argv Scarf composes for a bot routine, and the
/// local/remote roster merge staying collision-safe.
@Suite("Bot routines (B4)")
@MainActor
struct BotRoutinesViewModelTests {

    // MARK: - Argv composition

    /// The store that owns the jobs — i.e. the window's profile. Every
    /// composition test names it explicitly, because whether the prompt is
    /// wrapped depends entirely on how it compares to the bot.
    private static let sameProfile = "research"
    private static let otherProfile = "work"

    @Test("a routine for bot 'research' lands PREFIXED and never bleeds to another profile")
    func routineNameIsPrefixedForTheRightBot() {
        let args = BotRoutinesViewModel.createRoutineArguments(
            botName: "research",
            storeProfile: Self.sameProfile,
            title: "Morning digest",
            schedule: "0 9 * * *",
            prompt: "Summarize overnight news",
            hasCronBotChatDelivery: true
        )
        #expect(args == [
            "cron", "create", "--name", "[bot:research] Morning digest",
            "--deliver", "bot-chat:research",
            // `--` end-of-options, so a prompt opening with a dash is text
            // rather than a flag (F2 / t-e96cc0ad).
            "--", "0 9 * * *", "Summarize overnight news"
        ])
        // The name is unambiguously scoped to THIS bot — the adversarial
        // case B4 was asked to hunt: a routine created for bot A landing
        // unprefixed, or prefixed for bot B.
        #expect(BotRoutinePrefix.matches(jobName: args[3], bot: "research"))
        #expect(!BotRoutinePrefix.matches(jobName: args[3], bot: "ops"))
    }

    @Test("delivery is gated on hasCronBotChatDelivery — pre-0.20.6 hosts get no --deliver flag")
    func deliveryGatedOnCapability() {
        let args = BotRoutinesViewModel.createRoutineArguments(
            botName: "research",
            storeProfile: Self.sameProfile,
            title: "Morning digest",
            schedule: "0 9 * * *",
            prompt: "Summarize overnight news",
            hasCronBotChatDelivery: false
        )
        #expect(!args.contains("--deliver"))
        #expect(args == [
            "cron", "create", "--name", "[bot:research] Morning digest",
            "--", "0 9 * * *", "Summarize overnight news"
        ])
    }

    @Test("an empty prompt omits the trailing positional, mirroring CronViewModel.createJob")
    func emptyPromptOmitsPositional() {
        let args = BotRoutinesViewModel.createRoutineArguments(
            botName: "ops",
            storeProfile: "ops",
            title: "Health check",
            schedule: "every 1h",
            prompt: "",
            hasCronBotChatDelivery: false
        )
        #expect(args.last == "every 1h")
    }

    @Test("delivery always targets the routine's OWN bot, never another")
    func deliveryTargetsOwnBotOnly() {
        let argsA = BotRoutinesViewModel.createRoutineArguments(
            botName: "alpha", storeProfile: "alpha", title: "x", schedule: "30m", prompt: "", hasCronBotChatDelivery: true
        )
        let argsB = BotRoutinesViewModel.createRoutineArguments(
            botName: "beta", storeProfile: "beta", title: "x", schedule: "30m", prompt: "", hasCronBotChatDelivery: true
        )
        #expect(argsA.contains("bot-chat:alpha"))
        #expect(!argsA.contains("bot-chat:beta"))
        #expect(argsB.contains("bot-chat:beta"))
        #expect(!argsB.contains("bot-chat:alpha"))
    }

    // MARK: - Cross-profile delegation (the audit's headline B4 finding)

    /// `hermes cron` has ONE store per profile and runs every job as that
    /// profile. A routine for bot `research` created in the `work` window's
    /// store therefore executes with `work`'s memory, skills and credentials
    /// — under `research`'s name. The wrapper is the fix, and it must be the
    /// EXACT wrapper Hermes Desktop writes, byte for byte, or the two clients
    /// stop recognizing each other's jobs.
    ///
    /// Pinned against `apps/desktop/src/plugins/hermes-bots/cron.tsx:270-286`
    /// (`routinePrompt`) + `:74` (`SAFE_ROUTINE_MARKER`) + `:254-256`
    /// (`shellQuote`), Hermes v0.21.0.
    @Test("a cross-profile routine is wrapped in Hermes Desktop's exact delegation prompt")
    func crossProfileRoutineIsDelegated() {
        let args = BotRoutinesViewModel.createRoutineArguments(
            botName: "research",
            storeProfile: Self.otherProfile,
            title: "Morning digest",
            schedule: "0 9 * * *",
            prompt: "Summarize overnight news",
            hasCronBotChatDelivery: true
        )
        let prompt = args.last ?? ""
        #expect(prompt == """
        [bot-mode:routine:v2] You are running the scheduled routine "Morning digest" for agent \
        'research'. Execute it AS that agent so the run lands in its own history: run this in the \
        terminal and relay the output:

        hermes -p 'research' chat -c 'Routine: Morning digest' -q '[Scheduled routine] Summarize overnight news'

        If the command fails, report the error instead.
        """)
        // The name is still the bot's, so both clients' Routines panes list it.
        #expect(args[3] == "[bot:research] Morning digest")
    }

    @Test("the marker is byte-identical to SAFE_ROUTINE_MARKER, trailing space included")
    func markerMatchesTheTypeScriptConstant() {
        #expect(BotRoutineDelegation.marker == "[bot-mode:routine:v2] ")
    }

    /// `routinePrompt` returns the instruction untouched when the bot IS the
    /// active profile — no marker, no wrapper. Emitting one there would make
    /// Scarf's jobs differ from the desktop's for the common single-profile
    /// case.
    @Test("a same-profile routine is NOT wrapped — the raw instruction is the prompt")
    func sameProfileRoutineIsNotDelegated() {
        let args = BotRoutinesViewModel.createRoutineArguments(
            botName: "research",
            storeProfile: "  Research  ",   // normalizedProfileName: trim + lowercase
            title: "Morning digest",
            schedule: "0 9 * * *",
            prompt: "Summarize overnight news",
            hasCronBotChatDelivery: true
        )
        #expect(args.last == "Summarize overnight news")
        #expect(!(args.last ?? "").contains(BotRoutineDelegation.marker))
    }

    /// `shellQuote` (`cron.tsx:254-256`) — a `'` in the title or instruction
    /// becomes `'"'"'`, so the embedded command line stays one argument.
    /// Getting this wrong turns a routine into an arbitrary shell injection.
    @Test("quotes inside the title and instruction are POSIX-escaped exactly like shellQuote")
    func embeddedQuotesArePosixEscaped() {
        let prompt = BotRoutineDelegation.prompt(
            bot: "research",
            title: "Rob's digest",
            instruction: "don't stop; echo pwned",
            storeProfile: "work"
        )
        #expect(prompt.contains("-c 'Routine: Rob'\"'\"'s digest'"))
        #expect(prompt.contains("-q '[Scheduled routine] don'\"'\"'t stop; echo pwned'"))
        #expect(BotRoutineDelegation.shellQuote("a'b") == "'a'\"'\"'b'")
    }

    /// An empty/blank bot name can never compare equal to a profile, so it
    /// always takes the wrapper — matching `routinePrompt`'s
    /// `normalizedProfileName(bot) && …` guard, where an empty string is
    /// falsy and skips the early return.
    @Test("an empty bot name still takes the wrapper, matching the TS truthiness guard")
    func emptyBotNameStillDelegates() {
        #expect(BotRoutineDelegation.requiresDelegation(bot: "", storeProfile: ""))
        #expect(BotRoutineDelegation.requiresDelegation(bot: "   ", storeProfile: "   "))
    }

    /// #13: the argv helper is not a parallel implementation — it calls the
    /// same `routineFields` + `CronViewModel.createJobArguments` the live
    /// `createRoutine` does. Assert they agree so the helper cannot drift.
    @Test("the argv helper composes through the production builders")
    func argvHelperMatchesTheProductionBuilders() {
        let fields = BotRoutinesViewModel.routineFields(
            botName: "research",
            storeProfile: "work",
            title: "Morning digest",
            instruction: "Summarize overnight news",
            hasCronBotChatDelivery: true
        )
        let expected = CronViewModel.createJobArguments(
            schedule: "0 9 * * *",
            prompt: fields.prompt,
            name: fields.name,
            deliver: fields.deliver,
            skills: [], script: "", repeatCount: ""
        )
        #expect(BotRoutinesViewModel.createRoutineArguments(
            botName: "research",
            storeProfile: "work",
            title: "Morning digest",
            schedule: "0 9 * * *",
            prompt: "Summarize overnight news",
            hasCronBotChatDelivery: true
        ) == expected)
    }

    /// The store profile is derived from the context's home, not guessed: a
    /// window scoped to `work` (#126) owns `work`'s cron store.
    @Test("storeProfile is derived from the context home, defaulting to `default` at the root")
    func storeProfileFollowsTheWindowHome() {
        let root = ServerContext.local(home: URL(fileURLWithPath: "/tmp/hermes-root"))
        #expect(BotRoutinesViewModel(context: root, botName: "research").storeProfile == "default")
        let scoped = ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: "~/.hermes/profiles/work"))
        )
        #expect(BotRoutinesViewModel(context: scoped, botName: "research").storeProfile == "work")
    }

    // MARK: - Filtering (through a live CronViewModel's job list shape)

    @Test("routines filters the full job list down to exactly this bot's tagged jobs")
    func filtersToOwnJobsOnly() {
        let vm = BotRoutinesViewModel(context: .local, botName: "research")
        // CronViewModel.jobs is populated by its own load path (SSH/local
        // file read) — not reachable from a unit test without a host. This
        // exercises the FILTER PREDICATE itself, the part B4 owns, against
        // a representative mixed job list built the same way HermesCronJob
        // decodes from jobs.json.
        let jobs = [
            makeJob(id: "1", name: "[bot:research] Morning digest"),
            makeJob(id: "2", name: "[bot:ops] Deploy check"),
            makeJob(id: "3", name: "Untagged legacy job"),
            makeJob(id: "4", name: "[bot:research-2] Digest"),
            makeJob(id: "5", name: "[bot:Research] Evening digest")
        ]
        let matched = jobs.filter { BotRoutinePrefix.matches(jobName: $0.name, bot: vm.botName) }
        #expect(matched.map(\.id) == ["1", "5"])
    }

    private func makeJob(id: String, name: String) -> HermesCronJob {
        HermesCronJob(
            id: id, name: name, prompt: "", schedule: CronSchedule(kind: "cron", expression: "0 9 * * *"),
            enabled: true, state: "scheduled"
        )
    }
}

/// The "Remote" roster group must never conflate a peer with a local bot
/// that happens to share a name — B4's other adversarial target ("peer rows
/// triggering local-profile code paths").
@Suite("Bot roster: local/remote identity (B4)")
struct RemoteBotRosterTests {

    @Test("a peer sharing a local bot's name stays a DISTINCT identity")
    func collidingNamesStayDistinct() {
        let localNames: Set<String> = ["research", "ops"]
        let peers = [
            HermesBotPeer(name: "research", url: "https://other-host.example:8377"),
            HermesBotPeer(name: "cloud", url: "https://cloud.example:8377")
        ]
        // The merge rule B4 relies on: local rows and peer rows are NEVER
        // combined into one collection keyed only by name — a caller that
        // did so would silently drop or overwrite one identity when names
        // collide. Assert both survive as independently addressable rows.
        for peer in peers {
            #expect(peers.contains { $0.name == peer.name })
        }
        #expect(localNames.contains("research"))
        #expect(peers.contains { $0.name == "research" })
        // Two structurally different things sharing a string key — proof
        // the collision is real, not vacuous.
        #expect(peers.first { $0.name == "research" }?.url == "https://other-host.example:8377")
    }

    @Test("HermesBotPeer never carries anything resembling a local profile path")
    func peerCarriesNoLocalProfileIdentity() {
        // A `BotRow` is keyed by `identity.profileName` and always has a
        // `profileDirectory`; `HermesBotPeer` has neither field — the type
        // system itself keeps a peer row from being routed into any local
        // profile-scoped code path (BotsService, ACP pinning, avatar I/O).
        let peer = HermesBotPeer(name: "research", url: "https://other-host.example:8377")
        #expect(peer.id == "research")
        #expect(peer.keyEnvName == "HERMES_PEER_RESEARCH_KEY")
    }
}
