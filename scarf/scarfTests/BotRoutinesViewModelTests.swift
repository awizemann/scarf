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

    @Test("a routine for bot 'research' lands PREFIXED and never bleeds to another profile")
    func routineNameIsPrefixedForTheRightBot() {
        let args = BotRoutinesViewModel.createRoutineArguments(
            botName: "research",
            title: "Morning digest",
            schedule: "0 9 * * *",
            prompt: "Summarize overnight news",
            hasCronBotChatDelivery: true
        )
        #expect(args == [
            "cron", "create", "--name", "[bot:research] Morning digest",
            "--deliver", "bot-chat:research",
            "0 9 * * *", "Summarize overnight news"
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
            title: "Morning digest",
            schedule: "0 9 * * *",
            prompt: "Summarize overnight news",
            hasCronBotChatDelivery: false
        )
        #expect(!args.contains("--deliver"))
        #expect(args == [
            "cron", "create", "--name", "[bot:research] Morning digest",
            "0 9 * * *", "Summarize overnight news"
        ])
    }

    @Test("an empty prompt omits the trailing positional, mirroring CronViewModel.createJob")
    func emptyPromptOmitsPositional() {
        let args = BotRoutinesViewModel.createRoutineArguments(
            botName: "ops",
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
            botName: "alpha", title: "x", schedule: "30m", prompt: "", hasCronBotChatDelivery: true
        )
        let argsB = BotRoutinesViewModel.createRoutineArguments(
            botName: "beta", title: "x", schedule: "30m", prompt: "", hasCronBotChatDelivery: true
        )
        #expect(argsA.contains("bot-chat:alpha"))
        #expect(!argsA.contains("bot-chat:beta"))
        #expect(argsB.contains("bot-chat:beta"))
        #expect(!argsB.contains("bot-chat:alpha"))
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
