import Testing
import Foundation
@testable import ScarfCore

/// P50 — round-5 decisions 11 and 13, plus the section's cron/kanban LOWs.
///
/// One shape between them: a sentence, a gate or a type that claims
/// something the tagged Hermes source does not grant.
@Suite struct CronRecoveryHintP50Tests {

    static func job(
        state: String,
        kind: String,
        enabled: Bool = false,
        past: Bool = false,
        extra: String = ""
    ) throws -> HermesCronJob {
        let runAt = past ? "2020-01-01T09:00:00+00:00" : "2099-01-01T09:00:00+00:00"
        let schedule: String
        switch kind {
        case "cron":     schedule = #"{"kind":"cron","expr":"0 9 * * *"}"#
        case "interval": schedule = #"{"kind":"interval","minutes":30}"#
        default:         schedule = #"{"kind":"once","run_at":"\#(runAt)"}"#
        }
        let json = """
            {"id":"j1","name":"Nightly","prompt":"p","enabled":\(enabled),
             "state":"\(state)","schedule":\(schedule)\(extra.isEmpty ? "" : ",\(extra)")}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    // MARK: - Decision 11: the pre-v0.21 `error` hint

    /// The finding. On a host in `[0.20.6, 0.21.0)` the hint told the user to
    /// "edit the schedule to re-arm it" — a gesture that host REFUSES on this
    /// exact record: `update_job` @ `v2026.8.27` writes `next_run_at` for any
    /// record whose `state != "paused"` (`cron/jobs.py:2310`, `:2322`,
    /// `:2345`), an `error` job qualifies, and the guard immediately below
    /// raises because `is_terminal_job` is the bare `state in {completed,
    /// error}` (`:638-640`) with no `_is_recoverable_error_job` exemption at
    /// that tag (`:2367-2375`). `create_job` (`:1915`) carries no terminal
    /// guard, so Duplicate is the door — and it is rendered on every surface
    /// that renders this hint.
    @Test func theErrorHintNamesDuplicateNotEditingTheSchedule() throws {
        let job = try Self.job(state: "error", kind: "cron", enabled: true)
        let offer = job.recoveryOffer(
            hostRefusesTerminalJobs: true,
            hostRecoversErrorRecurring: false,   // a 0.20.6 host
            hostRefusesPastOneShotResume: true)
        let hint = try #require(offer.hint)
        #expect(offer.isDeadEnd)
        #expect(!hint.lowercased().contains("edit the schedule"), Comment(rawValue: hint))
        #expect(hint.lowercased().contains("duplicate"), Comment(rawValue: hint))
    }

    /// The sibling walk (round-5 addendum, lesson 3). `HermesCronRecoveryP38Tests`
    /// asserted this over the `noFutureOccurrences` family ONLY, which is how
    /// the `error` arm kept its dead remedy for two more rounds. Every hint
    /// the type can produce is in scope here, statically and through the real
    /// function, so the next arm added cannot quietly opt out.
    @Test func everyHintTheOfferCanProduceNamesDuplicate() throws {
        var hints: [String] = [
            CronRecoveryOffer.noFutureOccurrencesHint,
            CronRecoveryOffer.noFutureOccurrencesHint(repeatTimes: nil),
            CronRecoveryOffer.noFutureOccurrencesHint(repeatTimes: 3),
            CronRecoveryOffer.pastDeadlineOneShotHint,
            CronRecoveryOffer.errorNeedsNewerHermesHint,
        ]
        // And every arm the function actually reaches, so a hint that exists
        // only inline would still be caught.
        let cases: [(HermesCronJob, Bool, Bool, Bool)] = [
            (try Self.job(state: "error", kind: "cron", enabled: true), true, false, true),
            (try Self.job(state: "error", kind: "interval", enabled: true), true, false, true),
            (try Self.job(state: "completed", kind: "cron"), true, true, true),
            (try Self.job(state: "completed", kind: "interval"), true, true, true),
            (try Self.job(state: "scheduled", kind: "once", enabled: false, past: true), false, true, true),
        ]
        for (job, refusesTerminal, recoversError, refusesPast) in cases {
            let offer = job.recoveryOffer(
                hostRefusesTerminalJobs: refusesTerminal,
                hostRecoversErrorRecurring: recoversError,
                hostRefusesPastOneShotResume: refusesPast)
            if let hint = offer.hint { hints.append(hint) }
        }
        #expect(hints.count >= 8)
        for hint in hints {
            #expect(hint.lowercased().contains("duplicate"), Comment(rawValue: hint))
            #expect(!hint.lowercased().contains("edit the schedule"), Comment(rawValue: hint))
            #expect(!hint.lowercased().contains("re-arm it"), Comment(rawValue: hint))
        }
    }

    /// A v0.21.0+ host never SEES that hint — it gets the Resume button, via
    /// `_is_recoverable_error_job` (`cron/jobs.py:1865-1878` @ `v2026.9.7`).
    /// Pinned so the copy change cannot be mistaken for a floor change.
    @Test func aV021HostStillGetsResumeAndNoHintAtAll() throws {
        let job = try Self.job(state: "error", kind: "cron", enabled: true)
        let offer = job.recoveryOffer(
            hostRefusesTerminalJobs: true,
            hostRecoversErrorRecurring: true,
            hostRefusesPastOneShotResume: true)
        #expect(offer.canResume)
        #expect(offer.hint == nil)
    }
}

/// Decision 13 and the LOWs — asserted on the SOURCE, the `CronScheduleDisplayP42cTests`
/// precedent: `CronEditorView.oneShotTimeIsUnusable` is `private` to a SwiftUI
/// view in the iOS target, which neither test host builds.
@Suite struct CronSourceShapeP50Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The body of `oneShotTimeIsUnusable`, from its declaration to the
    /// closing brace of the `return` line that ends it. Crude on purpose, as
    /// the P42c precedent is: the assertions are about a handful of spellings.
    private static func unusableBody(of source: String) throws -> String {
        let start = try #require(
            source.range(of: "private var oneShotTimeIsUnusable: Bool {"),
            "oneShotTimeIsUnusable not found — the gate was renamed or removed")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace")
        return String(rest[..<end.lowerBound])
    }

    /// Decision 13. The refusal must consult the record's OWN stored time, so
    /// a prompt-only edit of a spent one-shot goes through while a create or
    /// a duplicate that types a spent time is still refused. Hermes agrees for
    /// the case admitted: a one-shot that ran is `enabled=False,
    /// state="completed", next_run_at=None` (`_complete_job_record`,
    /// `cron/jobs.py:1463-1465` @ `v2026.9.7`), so a `--prompt`-only
    /// `cron edit` clears `_reject_terminal_activation` (`:1865-1878`) and
    /// returns early from `_fill_missing_next_run` (`:1912-1927`).
    @Test func theIOSEditorLetsAnUneditedSpentOneShotSaveItsPrompt() throws {
        let body = try Self.unusableBody(
            of: try Self.source("scarf/Scarf iOS/Cron/CronListView.swift"))
        #expect(body.contains("existing?.schedule.runAt"),
                "the gate no longer compares against the record's stored time — a prompt-only edit is blocked again")
        #expect(body.contains("stored == raw"))
        // Still refused for everything that is NOT that: an empty time, and a
        // spent time the user supplied.
        #expect(body.contains("if raw.isEmpty { return true }"))
        #expect(body.contains("HermesCronJob.oneShotScheduleIsPastGrace(raw)"))
    }

    /// LOW. `trigger_job` uses the BARE `is_terminal_job` (`cron/jobs.py:2012`
    /// @ `v2026.9.7`) — no recoverable-error exemption — so Run Now on a
    /// terminal job is a guaranteed exit 1. The row context menu disabled it;
    /// the detail pane's PRIMARY button did not. Both sites pinned, so a third
    /// Run Now forces a re-walk.
    @Test func bothCronViewRunNowSitesRefuseATerminalJob() throws {
        let source = try Self.source("scarf/scarf/Features/Cron/Views/CronView.swift")
        let sites = source.components(
            separatedBy: ".disabled(viewModel.refusesTerminalJobLocally(job))").count - 1
        #expect(sites == 2, "expected exactly two guarded Run Now sites, found \(sites)")
    }

    /// LOW. `KanbanWatchFilter` was dead (no non-test reader) and its doc
    /// asserted a `hermes kanban watch --json` that does not exist: the verb
    /// takes `--assignee/--tenant/--kinds/--interval` and nothing else
    /// (`hermes_cli/kanban_parser.py:359-365` @ `v2026.9.7`), and its help is
    /// "Live-stream task_events to the terminal". Deleted; this is the alarm
    /// against the false citation coming back.
    @Test func nothingClaimsAJSONFlagOnKanbanWatch() throws {
        let source = try Self.source(
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Models/KanbanFilters.swift")
        #expect(!source.contains("KanbanWatchFilter"))
        #expect(!source.contains("kanban watch"))
    }
}
