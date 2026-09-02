import Testing
import Foundation
@testable import ScarfCore

/// F5 — Kanban CLI contracts + board/list parity.
///
/// Every shape asserted here is transcribed from the emitting Python at
/// tag `v2026.8.31` (Hermes v0.21.0), `hermes_cli/kanban.py` and
/// `hermes_cli/kanban_db.py` — not from the audit report and not from
/// memory. The two argparse declarations that drive most of this file:
///
/// ```python
/// p_promote.add_argument("task_id")
/// p_promote.add_argument("reason", nargs="*", help="Audit-trail reason (recorded on the task_events row)")
/// p_promote.add_argument("--ids", nargs="+", default=None, help="Additional task ids to promote with the same reason (bulk mode)")
/// p_promote.add_argument("--force", action="store_true", ...)
/// p_promote.add_argument("--dry-run", action="store_true", ...)
/// p_promote.add_argument("--json", dest="json", action="store_true", ...)
///
/// p_asg = sub.add_parser("assignees", ...)
/// p_asg.add_argument("--json", action="store_true")
/// ```
///
/// `_cmd_promote` then does `reason = " ".join(args.reason).strip()` and
/// `ids = [args.task_id, *args.ids]` — which is exactly why extra
/// positional ids landed inside the audit-trail reason.
@Suite("F5 Kanban CLI contracts")
struct SectionAuditF5KanbanTests {

    // MARK: - promote

    /// The headline bug: Scarf passed every id positionally, so ids[1…]
    /// were swept into `reason` (`nargs="*"`) and written to the
    /// `task_events` audit row, while only ids[0] was actually promoted.
    /// Exit code 0 throughout.
    @Test func bulkPromoteUsesIdsFlagAndNeverLeaksIdsIntoTheReason() {
        let argv = KanbanService.promoteArgv(
            taskIds: ["t_aaa", "t_bbb", "t_ccc"],
            reason: "manual recovery after the dispatcher stalled"
        )

        #expect(argv == [
            "kanban", "promote",
            "--json",
            "--ids", "t_bbb", "t_ccc",
            "--",
            "t_aaa",
            "manual recovery after the dispatcher stalled"
        ])

        // The reason is ONE argv element — never space-split. `_cmd_promote`
        // re-joins `args.reason` with spaces, so splitting would only destroy
        // runs of whitespace and hand argparse a dash-leading word to claim.
        let reasonElements = argv.filter { $0.contains(" ") }
        #expect(reasonElements == ["manual recovery after the dispatcher stalled"])

        // No id may appear anywhere after the single positional slot.
        guard let endOfOptions = argv.firstIndex(of: "--") else {
            Issue.record("argv must contain an end-of-options marker")
            return
        }
        let positionals = Array(argv[(endOfOptions + 1)...])
        #expect(positionals.first == "t_aaa")
        #expect(!positionals.dropFirst().contains("t_bbb"))
        #expect(!positionals.dropFirst().contains("t_ccc"))
    }

    /// `--` goes AFTER every flag and IMMEDIATELY before the positionals
    /// (the F2 rule). `--ids` is `nargs="+"`, so it has to be the LAST
    /// flag — the `--` is what terminates its greedy consumption.
    @Test func promoteEndOfOptionsFollowsEveryFlagAndImmediatelyPrecedesPositionals() {
        let argv = KanbanService.promoteArgv(
            taskIds: ["t_aaa", "t_bbb"],
            reason: "why",
            force: true,
            dryRun: true
        )

        #expect(argv == [
            "kanban", "promote",
            "--force", "--dry-run", "--json",
            "--ids", "t_bbb",
            "--",
            "t_aaa", "why"
        ])

        let endOfOptions = argv.firstIndex(of: "--")!
        // Nothing flag-shaped may follow `--`: argparse reads every token
        // after it as a positional and rejects a flag as an extra argument.
        #expect(!argv[(endOfOptions + 1)...].contains { $0.hasPrefix("--") })
        // And `--ids`' values must all sit before it.
        #expect(argv.firstIndex(of: "--ids")! < endOfOptions)
        #expect(argv[endOfOptions - 1] == "t_bbb")
    }

    /// Single-id promote must stay on the plain positional form — one id,
    /// no `--ids` at all.
    @Test func singlePromoteKeepsThePositionalFormWithoutIdsFlag() {
        let argv = KanbanService.promoteArgv(taskIds: ["t_only"], reason: "recovered by hand")
        #expect(argv == ["kanban", "promote", "--json", "--", "t_only", "recovered by hand"])
        #expect(!argv.contains("--ids"))
    }

    @Test func promoteWithoutReasonOmitsTheTrailingPositional() {
        #expect(KanbanService.promoteArgv(taskIds: ["t_only"]) == [
            "kanban", "promote", "--json", "--", "t_only"
        ])
        // Empty string is not a reason either — an empty trailing argv
        // element would still be joined into a comment-worthy "".
        #expect(KanbanService.promoteArgv(taskIds: ["t_only"], reason: "") == [
            "kanban", "promote", "--json", "--", "t_only"
        ])
    }

    /// `--board` is a GLOBAL flag on the top-level `kanban` parser, so it
    /// sits before the verb and must not disturb the `--`/positional tail.
    @Test func promoteKeepsTheGlobalBoardFlagAheadOfTheVerb() {
        let argv = KanbanService.promoteArgv(board: "release", taskIds: ["t_a", "t_b"])
        #expect(argv == [
            "kanban", "--board", "release", "promote",
            "--json", "--ids", "t_b", "--", "t_a"
        ])
    }

    @Test func promoteWithNoIdsProducesNoCommand() {
        #expect(KanbanService.promoteArgv(taskIds: []).isEmpty)
    }

    // MARK: - schedule (identical argparse shape, identical latent bug)

    /// `p_schedule.add_argument("task_id")` + `reason` `nargs="*"` +
    /// `--ids` `nargs="+"` — verbatim the promote shape, so bulk schedule
    /// had the same silent reason-corruption bug.
    @Test func bulkScheduleUsesIdsFlagAndNeverLeaksIdsIntoTheReason() {
        let argv = KanbanService.scheduleArgv(
            taskIds: ["t_aaa", "t_bbb", "t_ccc"],
            reason: "parked until the vendor API is back"
        )

        #expect(argv == [
            "kanban", "schedule",
            "--ids", "t_bbb", "t_ccc",
            "--",
            "t_aaa",
            "parked until the vendor API is back"
        ])

        let endOfOptions = argv.firstIndex(of: "--")!
        let positionals = Array(argv[(endOfOptions + 1)...])
        #expect(positionals == ["t_aaa", "parked until the vendor API is back"])
        #expect(!positionals.contains("t_bbb"))
        #expect(!positionals.contains("t_ccc"))
    }

    @Test func singleScheduleKeepsThePositionalFormWithoutIdsFlag() {
        let argv = KanbanService.scheduleArgv(taskIds: ["t_only"], reason: "waiting on review")
        #expect(argv == ["kanban", "schedule", "--", "t_only", "waiting on review"])
        #expect(!argv.contains("--ids"))
    }

    // MARK: - assignees

    /// `--json` needs no capability gate: the flag is present at every tag
    /// that ships the subcommand at all (v2026.5.7 / v0.13.0 through
    /// v2026.8.31 / v0.21.0), and v2026.4.30 / v0.12.0 has no
    /// `hermes_cli/kanban.py` whatsoever.
    @Test func assigneesAlwaysRequestsJSON() {
        #expect(KanbanService.assigneesArgv() == ["kanban", "assignees", "--json"])
        #expect(KanbanService.assigneesArgv(board: "release")
            == ["kanban", "--board", "release", "assignees", "--json"])
    }

    /// Verbatim `json.dumps` of `kanban_db.known_assignees`, which returns
    /// `{"name": …, "on_disk": …, "counts": {status: n}}` per entry.
    static let assigneesJSON = """
    [
      {
        "name": "builder",
        "on_disk": true,
        "counts": {
          "running": 2,
          "ready": 3,
          "done": 7
        }
      },
      {
        "name": "retired-bot",
        "on_disk": false,
        "counts": {
          "blocked": 1
        }
      },
      {
        "name": "idle-profile",
        "on_disk": true,
        "counts": {}
      }
    ]
    """

    @Test func assigneesDecodeReadsTheRealNameOnDiskCountsShape() throws {
        let rows = try JSONDecoder().decode(
            [HermesKanbanAssignee].self,
            from: Data(Self.assigneesJSON.utf8)
        )

        #expect(rows.map(\.profile) == ["builder", "retired-bot", "idle-profile"])
        #expect(rows.map(\.id) == ["builder", "retired-bot", "idle-profile"])

        // Counts are real, not the all-zero rows the text parser produced.
        #expect(rows[0].counts == ["running": 2, "ready": 3, "done": 7])
        // `done` is terminal, so it counts toward the total but not toward
        // active — the same status set `HermesKanbanStats.activeCount` uses.
        #expect(rows[0].activeCount == 5)
        #expect(rows[0].totalCount == 12)
        #expect(rows[0].onDisk)

        // A name that only appears on tasks (renamed/removed profile).
        #expect(!rows[1].onDisk)
        #expect(rows[1].activeCount == 1)

        // A fresh profile with no work is a legitimate zero, not a parse miss.
        #expect(rows[2].onDisk)
        #expect(rows[2].totalCount == 0)
    }

    /// The pre-fix decoder was keyed on `{profile, active, total}` — a
    /// shape Hermes emits at NO version — so every decode failed silently
    /// and fell through to a text-table parse. Assert the invented shape
    /// is genuinely rejected, so nothing quietly resurrects it.
    @Test func assigneesRejectsTheInventedProfileActiveTotalShape() {
        let invented = #"[{"profile": "builder", "active": 2, "total": 12}]"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                [HermesKanbanAssignee].self,
                from: Data(invented.utf8)
            )
        }
    }

    /// The v0.12-era human table (what `_cmd_assignees` prints WITHOUT
    /// `--json`: a `NAME  ON DISK  COUNTS` header then `name  yes  k=v, …`)
    /// must decode to nothing rather than to an all-zero row set with a
    /// phantom "NAME" entry. `KanbanService.assignees()` now throws on it
    /// instead of parsing it; here we assert the decode itself fails, so
    /// the parser reports nil rather than inventing rows.
    @Test func assigneesTextTableIsNotDecodedIntoPhantomRows() {
        let table = """
        NAME                  ON DISK   COUNTS
        builder               yes       ready=3, running=2
        retired-bot           no        blocked=1
        """
        let decoded = try? JSONDecoder().decode(
            [HermesKanbanAssignee].self,
            from: Data(table.utf8)
        )
        #expect(decoded == nil)
        // Specifically: no "NAME" row, which is what the old header-tolerant
        // text parser leaked into the assignee picker.
        #expect(decoded?.contains { $0.profile == "NAME" } != true)
    }

    // MARK: - list scope parity (board vs. list mode)

    /// List mode used to hand-roll `["kanban", "list", "--json"]`, so a
    /// project- or chat-scoped route silently widened to every task on the
    /// host the moment the user flipped Board → List. Both modes now build
    /// the same `KanbanListFilter` and go through `KanbanService`.
    @Test func listArgvCarriesTenantScope() {
        let argv = KanbanService.listArgv(
            filter: KanbanListFilter(status: .running, tenant: "scarf")
        )
        #expect(argv == ["kanban", "list", "--json", "--status", "running", "--tenant", "scarf"])
    }

    @Test func listArgvCarriesSessionScope() {
        let argv = KanbanService.listArgv(
            filter: KanbanListFilter(session: "sess_1234")
        )
        #expect(argv == ["kanban", "list", "--json", "--session", "sess_1234"])
    }

    /// The chat-scoped board view keys on session alone (session ids are
    /// globally unique); the project view keys on tenant. Both must
    /// survive the trip through the shared builder together.
    @Test func listArgvCarriesTenantAndSessionTogether() {
        let argv = KanbanService.listArgv(
            filter: KanbanListFilter(tenant: "scarf", session: "sess_1234", includeArchived: true)
        )
        #expect(argv == [
            "kanban", "list", "--json",
            "--tenant", "scarf",
            "--session", "sess_1234",
            "--archived"
        ])
    }

    /// An unscoped route stays unscoped — no phantom empty flags.
    @Test func listArgvWithoutScopeAddsNoScopeFlags() {
        let argv = KanbanService.listArgv(filter: KanbanListFilter())
        #expect(argv == ["kanban", "list", "--json"])
    }

    // MARK: - transition planner

    /// `unblock` accepts `scheduled` as well as `blocked`. Verified at
    /// v2026.8.31: `p_unblock`'s help reads "Return blocked/scheduled
    /// tasks to ready, or todo while parents remain open", and
    /// `_cmd_unblock` fails with "cannot unblock {tid}
    /// (not blocked/scheduled?)". The planner omitted `scheduled`, so a
    /// parked card could not be dragged anywhere.
    @Test func plannerAcceptsScheduledAsAnUnblockSource() throws {
        let toUpNext = try KanbanService.plan(for: KanbanTransition(from: .scheduled, to: .upNext))
        #expect(toUpNext.steps == [.unblock])

        let toRunning = try KanbanService.plan(for: KanbanTransition(from: .scheduled, to: .running))
        #expect(toRunning.steps == [.unblock, .dispatch])

        let toDone = try KanbanService.plan(for: KanbanTransition(from: .scheduled, to: .done))
        #expect(toDone.steps == [.unblock, .complete(resultRequired: false)])
    }

    /// …but NOT `scheduled → blocked`. `kanban_db.block_task` only updates
    /// rows `WHERE status IN ('running', 'ready')`, so blocking a parked
    /// task returns False and prints "cannot block <id>". Planning it
    /// would have produced a verb that always fails.
    @Test func plannerStillRejectsScheduledToBlocked() {
        #expect(throws: KanbanError.self) {
            _ = try KanbanService.plan(for: KanbanTransition(from: .scheduled, to: .blocked))
        }
    }

    /// `scheduled` stays unreachable as a DESTINATION by drag — parking is
    /// the explicit Schedule action, which is the `schedule` verb.
    @Test func plannerStillRejectsDragsIntoScheduled() {
        #expect(throws: KanbanError.self) {
            _ = try KanbanService.plan(for: KanbanTransition(from: .upNext, to: .scheduled))
        }
    }

    /// Regression guard for the blocked-source cases the scheduled cases
    /// were modelled on — they must keep their existing plans.
    @Test func plannerKeepsBlockedSourcePlansUnchanged() throws {
        #expect(try KanbanService.plan(for: KanbanTransition(from: .blocked, to: .upNext)).steps == [.unblock])
        #expect(try KanbanService.plan(for: KanbanTransition(from: .blocked, to: .running)).steps
            == [.unblock, .dispatch])
    }
}
