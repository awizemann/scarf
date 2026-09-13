import Testing
import Foundation
@testable import ScarfCore

/// P56, round-6 decision 6 — the Kanban Review column's two exits, and the
/// floor walk that moved them off `hasKanbanV015`.
@Suite struct KanbanReviewExitsFloorP56Tests {

    /// Parse-the-version-line. `complete_task`'s UPDATE takes `'review'` from
    /// `v2026.8.13` (`pyproject.toml` = `0.20.1`) and not at `v2026.8.3`
    /// (`0.20.0`); `reopen-review` occurs zero times under `hermes_cli/`
    /// through `v2026.8.3` and twice from `v2026.8.13` on.
    @Test func theFloorIsV0201() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.13)").hasKanbanReviewExits)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)").hasKanbanReviewExits)
    }

    /// All-flags-on at the target tag.
    @Test func theTargetHostHasIt() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasKanbanReviewExits)
    }

    /// Degradation. **This is the case round-6 decision 6 got wrong**: a
    /// v0.15 host satisfies `hasKanbanV015`, and gating the exits there would
    /// have offered a drag that `complete_task` returns `False` for on five
    /// releases' worth of hosts.
    @Test func aV015HostHasKanbanV015ButNotTheReviewExits() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.15.0 (2026.5.28)")
        #expect(caps.hasKanbanV015)
        #expect(!caps.hasKanbanReviewExits)
    }

    /// Patch-still-on.
    @Test func aLaterPatchKeepsIt() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)").hasKanbanReviewExits)
    }
}

@Suite struct KanbanReviewPlannerP56Tests {

    private static let modern = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    private static let old = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.8.3)")

    /// `review -> done` is `kanban complete`: `complete_task`'s UPDATE reads
    /// `AND status IN ('running', 'ready', 'blocked', 'review')`
    /// (`hermes_cli/kanban_db.py:2572` @ `v2026.9.7`).
    @Test func reviewToDoneCompletes() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .review, to: .done), caps: Self.modern)
        #expect(plan.steps == [.complete(resultRequired: false)])
    }

    /// `review -> upNext` is `kanban reopen-review`: `reopen_review_task`
    /// moves the row to `_landing_status_after_parents`, i.e. `ready` or
    /// `todo` (`hermes_cli/kanban_db.py:3295-3328` @ `v2026.9.7`), and this
    /// board collapses both into Up Next.
    @Test func reviewToUpNextReopens() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .review, to: .upNext), caps: Self.modern)
        #expect(plan.steps == [.reopenReview])
    }

    /// Both were `KanbanError.forbiddenTransition("No CLI path exists…")`
    /// before P56 — on every host.
    @Test(arguments: [KanbanBoardColumn.done, .upNext])
    func anOlderHostKeepsAnHonestRefusal(_ destination: KanbanBoardColumn) {
        #expect(throws: KanbanError.self) {
            _ = try KanbanService.plan(
                for: KanbanTransition(from: .review, to: destination), caps: Self.old)
        }
    }

    /// …and the refusal names the HOST, not the gesture, so the user knows
    /// an upgrade is the remedy.
    @Test func theOlderHostRefusalNamesTheVersion() {
        do {
            _ = try KanbanService.plan(
                for: KanbanTransition(from: .review, to: .done), caps: Self.old)
            Issue.record("a v0.20.0 host was offered the Review exit")
        } catch let err as KanbanError {
            #expect(err.errorDescription?.contains("v0.20.1") == true,
                    "refusal doesn't name the floor: \(err.errorDescription ?? "")")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    /// `review -> blocked` stays refused even on the newest host:
    /// `block_task` updates only `WHERE … AND status IN ('running', 'ready')`
    /// (`hermes_cli/kanban_db.py:2929` @ `v2026.9.7`), the same reason
    /// `scheduled -> blocked` is absent. A two-step would land the card
    /// somewhere the user did not drop it.
    @Test func reviewToBlockedStaysRefused() {
        #expect(throws: KanbanError.self) {
            _ = try KanbanService.plan(
                for: KanbanTransition(from: .review, to: .blocked), caps: Self.modern)
        }
    }

    /// …and it is refused for the RIGHT reason on an old host too. The
    /// version guard is scoped to the two destinations it is about; raising
    /// it here would name an upgrade that does not help, since `block_task`
    /// refuses a `review` row at every tag.
    @Test func theBlockedRefusalNeverBlamesTheHostVersion() {
        for caps in [Self.modern, Self.old] {
            do {
                _ = try KanbanService.plan(
                    for: KanbanTransition(from: .review, to: .blocked), caps: caps)
                Issue.record("review -> blocked was planned")
            } catch let err as KanbanError {
                #expect(err.errorDescription?.contains("v0.20.1") == false,
                        "the blocked refusal blames the host version: \(err.errorDescription ?? "")")
            } catch {
                Issue.record("wrong error type: \(error)")
            }
        }
    }

    /// Review is still not a drag DESTINATION — the dispatcher owns entry —
    /// and the new source arms must not have opened it.
    @Test func reviewIsStillNotADestination() {
        #expect(throws: KanbanError.self) {
            _ = try KanbanService.plan(
                for: KanbanTransition(from: .upNext, to: .review), caps: Self.modern)
        }
    }

    /// Archiving a review card is reached by context menu, and `to ==
    /// .archived` short-circuits ABOVE the new `from == .review` block — so
    /// the gate must not have stolen it on an older host either.
    @Test func archivingAReviewCardIsUngated() throws {
        for caps in [Self.modern, Self.old, HermesCapabilities.empty] {
            let plan = try KanbanService.plan(
                for: KanbanTransition(from: .review, to: .archived), caps: caps)
            #expect(plan.steps == [.archive])
        }
    }
}

@Suite struct KanbanReopenReviewArgvP56Tests {

    /// `task_ids` is `nargs="+"` and `--reason` a plain `add_argument`
    /// (`hermes_cli/kanban_parser.py:323-326` @ `v2026.9.7`) — exactly ONE
    /// list-valued parser, which is what makes `--` safe here (unlike
    /// `archive`, whose `--rm` the separator would starve; P54).
    @Test func idsGoBehindTheSeparator() {
        let argv = KanbanService.reopenReviewArgv(taskIds: ["t_a", "t_b"])
        #expect(argv == ["kanban", "reopen-review", "--", "t_a", "t_b"])
    }

    /// A reason that begins with a dash is one `--reason=…` token, so
    /// argparse never tests it for option-ness (P42's lesson: `--` protects
    /// positionals only).
    @Test func aDashLeadingReasonSurvivesAsOneToken() throws {
        let argv = KanbanService.reopenReviewArgv(taskIds: ["t_a"], reason: "-- needs tests")
        #expect(HermesCLIOption.value(of: "--reason", in: argv) == "-- needs tests")
        #expect(argv.last == "t_a")
        // And it stays in FRONT of the separator — an option stranded behind
        // `--` is a positional, which is how P54's `archive --rm` bug reads.
        let separator = try #require(argv.firstIndex(of: "--"))
        let reason = try #require(argv.firstIndex(where: { $0.hasPrefix("--reason") }))
        #expect(reason < separator)
    }

    @Test func aBlankReasonIsOmittedEntirely() {
        #expect(KanbanService.reopenReviewArgv(taskIds: ["t_a"], reason: "   ")
                == ["kanban", "reopen-review", "--", "t_a"])
    }

    @Test func theBoardSelectorRidesTheSharedPrefix() {
        let argv = KanbanService.reopenReviewArgv(board: "scarf", taskIds: ["t_a"])
        #expect(argv.first == "kanban")
        #expect(HermesCLIOption.value(of: "--board", in: argv) == "scarf")
        #expect(argv.contains("reopen-review"))
    }
}
