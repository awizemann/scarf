import Testing
import Foundation
@testable import ScarfCore

/// P42 · decision 7 — a user-typed option VALUE that begins with `-` must
/// survive argparse.
///
/// `--` is not the fix and never was: it ends the OPTIONS, so everything
/// after it is a positional. `parse_args(["--name", "-nightly", "--", sched])`
/// is still `error: argument --name: expected one argument` (exit 2) because
/// argparse tests `-nightly` for option-ness before `--name` is ever given a
/// value. Proven against CPython's argparse, then pinned here.
///
/// Every flag asserted below was walked at `v2026.9.7`:
/// `hermes_cli/subcommands/cron.py:25-31` (`--name`/`--deliver`),
/// `:32-37` (`--failure-deliver`), `:38` (`--repeat`), `:39-40` (`--skill`,
/// `action="append"`), `:41-47` (`--script`), `:63-65` (`--workdir`),
/// `:91-97` (`cron edit --schedule/--prompt/--name/--deliver`),
/// `:98-102` (`--add-skill`/`--remove-skill`);
/// `hermes_cli/kanban_parser.py:266` (`comment --author`),
/// `:280-283` (`complete --result`/`--summary`/`--metadata`),
/// `:444` (`kanban --board`). Every one is a bare `add_argument` with no
/// `nargs`, which is the only shape the `=` form is valid for.
@Suite struct HermesCLIOptionP42Tests {

    // MARK: - The primitive

    @Test func theJoinedFormIsOneTokenSplitOnTheFirstEquals() throws {
        #expect(HermesCLIOption.joined("--name", "-nightly") == "--name=-nightly")
        // An empty value is a real gesture (`cron edit --workdir ""` clears
        // the field, `subcommands/cron.py:126-128` @ v2026.9.7) and must not
        // collapse to a bare flag.
        #expect(HermesCLIOption.joined("--workdir", "") == "--workdir=")
        // A value that itself contains `=` keeps every later `=`, because
        // argparse splits on the FIRST one only.
        let token = HermesCLIOption.joined("--metadata", #"{"a":"b=c"}"#)
        let parts = try #require(HermesCLIOption.split(token))
        #expect(parts.flag == "--metadata")
        #expect(parts.value == #"{"a":"b=c"}"#)
    }

    @Test func splitIgnoresTokensThatAreNotEqualsBearingLongOptions() {
        #expect(HermesCLIOption.split("--json") == nil)
        #expect(HermesCLIOption.split("--") == nil)
        #expect(HermesCLIOption.split("-nightly") == nil)
        #expect(HermesCLIOption.split("not-an-option=x") == nil)
    }

    // MARK: - fleet copy

    @Test func fleetCronCreateCarriesEveryUserTextValueInOneToken() {
        let caps = HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)")
        let (args, _) = FleetApplyPlan.cronCreateArgs(
            name: "-nightly", deliver: "discord:ops", failureDeliver: "local",
            repeatCount: 3, skills: ["--x"], workdir: "-/tmp/w",
            schedule: "0 9 * * *", prompt: "-go", caps: caps)
        #expect(args.contains("--name=-nightly"))
        #expect(args.contains("--deliver=discord:ops"))
        #expect(args.contains("--failure-deliver=local"))
        #expect(args.contains("--repeat=3"))
        #expect(args.contains("--skill=--x"))
        #expect(args.contains("--workdir=-/tmp/w"))
        for flag in ["--name", "--deliver", "--failure-deliver", "--repeat",
                     "--skill", "--workdir"] {
            #expect(!args.contains(flag), "\(flag) is still a two-token pair")
        }
        #expect(Array(args.suffix(3)) == ["--", "0 9 * * *", "-go"])
    }

    // MARK: - kanban

    @Test func kanbanCreateCarriesEveryUserTextValueInOneToken() {
        let argv = KanbanCreateRequest(
            title: "-dash title", body: "-body", assignee: "-alice",
            parentIds: ["--p"], tenant: "-scarf:x", priority: -1,
            idempotencyKey: "-k", maxRuntimeSeconds: 60, createdBy: "-bob",
            skills: ["--s"], maxRetries: 2,
            completionContract: "-local"
        ).argv()
        #expect(argv.contains("--body=-body"))
        #expect(argv.contains("--assignee=-alice"))
        #expect(argv.contains("--tenant=-scarf:x"))
        #expect(argv.contains("--priority=-1"))
        #expect(argv.contains("--parent=--p"))
        #expect(argv.contains("--created-by=-bob"))
        #expect(argv.contains("--skill=--s"))
        #expect(argv.contains("--idempotency-key=-k"))
        #expect(argv.contains("--completion-contract=-local"))
        for flag in ["--body", "--assignee", "--tenant", "--priority", "--parent",
                     "--created-by", "--skill", "--idempotency-key",
                     "--completion-contract", "--max-runtime", "--max-retries"] {
            #expect(!argv.contains(flag), "\(flag) is still a two-token pair")
        }
        // The title is still the trailing positional behind `--`.
        #expect(Array(argv.suffix(2)) == ["--", "-dash title"])
    }

    @Test func kanbanListFilterCarriesEveryUserTextValueInOneToken() {
        let argv = KanbanListFilter(
            status: .running, assignee: "-alice", tenant: "-t", session: "-s", sort: "-p"
        ).argv()
        #expect(argv.contains("--status=running"))
        #expect(argv.contains("--assignee=-alice"))
        #expect(argv.contains("--tenant=-t"))
        #expect(argv.contains("--session=-s"))
        #expect(argv.contains("--sort=-p"))
        for flag in ["--status", "--assignee", "--tenant", "--session", "--sort"] {
            #expect(!argv.contains(flag), "\(flag) is still a two-token pair")
        }
    }

    @Test func kanbanBoardAndDiagnosticsScopeCarryTheirValuesInOneToken() {
        #expect(KanbanService.listArgv(board: "-ops", filter: .all)
                    .contains("--board=-ops"))
        #expect(KanbanService.diagnosticsArgv(taskId: "-t_1")
                == ["kanban", "diagnostics", "--json", "--task=-t_1"])
    }

    // MARK: - the `--` guards these builders still need

    /// `complete` and `archive` take their ids as POSITIONALS
    /// (`task_ids` `nargs="+"` at `hermes_cli/kanban_parser.py:279`,
    /// `nargs="*"` at `:336` @ `v2026.9.7`), so they need the `--` marker
    /// `unblock` already had — the `=` form does nothing for a positional.
    @Test func theBulkIDVerbsGuardTheirPositionalsWithTheEndOfOptionsMarker() throws {
        let complete = KanbanService.completeArgv(taskIds: ["-t_1"], result: "-done")
        #expect(complete.contains("--result=-done"))
        let marker = try #require(complete.firstIndex(of: "--"))
        #expect(Array(complete[complete.index(after: marker)...]) == ["-t_1"])

        let archive = KanbanService.archiveArgv(taskIds: ["-t_2"])
        #expect(Array(archive.suffix(2)) == ["--", "-t_2"])
    }

    // MARK: - the reader

    @Test func theArgvInspectorReadsBothSpellings() {
        #expect(HermesCLIOption.value(of: "--name", in: ["--name=x"]) == "x")
        #expect(HermesCLIOption.value(of: "--name", in: ["--name", "x"]) == "x")
        #expect(HermesCLIOption.value(of: "--name", in: ["--name"]) == nil)
        #expect(HermesCLIOption.value(of: "--name", in: ["--nameish=x"]) == nil)
        #expect(HermesCLIOption.values(of: "--skill", in: ["--skill=a", "--skill", "b"])
                == ["a", "b"])
        #expect(!HermesCLIOption.contains("--skill", in: ["--skills=a"]))
    }
}

/// P42 · the kanban half of `t-dafcc4a5` and the round-4 LOWs it carried.
@Suite struct KanbanEnvelopeP42Tests {

    private func task(_ extraKeys: String) throws -> HermesKanbanTask {
        let json = """
            {"id":"t_1","title":"T","status":"todo"\(extraKeys.isEmpty ? "" : ",\(extraKeys)")}
            """
        return try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
    }

    /// Both keys ride in `_TASK_DICT_FIELDS`, so every `--json` task envelope
    /// carries them (`hermes_cli/kanban_output.py:18-24` @ `v2026.9.7`).
    /// Decoded now, so a linked task and a provider pin are visible instead
    /// of being silently thrown away by the decoder.
    @Test func providerOverrideAndProjectIDAreDecoded() throws {
        let full = try task(#""provider_override":"nous","project_id":"p_42","model_override":"kimi-k2""#)
        #expect(full.providerOverride == "nous")
        #expect(full.projectId == "p_42")
        #expect(full.modelOverride == "kimi-k2")
    }

    /// C1 / the tolerant-decode contract: a pre-v0.21.1 row carries neither
    /// key and must still decode, with both nil — the UI chip is what the
    /// capability flag gates, never the decode.
    @Test func aPreTargetRowStillDecodesWithBothNil() throws {
        let bare = try task("")
        #expect(bare.providerOverride == nil)
        #expect(bare.projectId == nil)
        #expect(bare.id == "t_1")
    }

    /// The floor behind the `Provider:` chip. P42 read the FILE move for the
    /// KEY's birth and floored this at v0.21.1; the real floor is **v0.19.1**
    /// (`v2026.7.30:80`). See `HermesKanbanProviderFloorP42bTests` for the
    /// full walk — this pins the one fact this suite's chip depends on.
    @Test func theProviderChipIsGatedAtV0191() {
        #expect(HermesCapabilities.parse("Hermes Agent v0.19.1 (2026.7.30)").hasKanbanProviderOverride)
        #expect(!HermesCapabilities.parse("Hermes Agent v0.19.0 (2026.7.20)").hasKanbanProviderOverride)
        #expect(!HermesCapabilities.empty.hasKanbanProviderOverride)
        // `model_override`'s own gate is older and must not move with it.
        #expect(HermesCapabilities.parse("Hermes Agent v0.21.0 (2026.8.31)").hasKanbanV015)
    }
}
