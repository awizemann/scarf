import Foundation
import Testing
@testable import ScarfCore

// MARK: - P50b: the review of P50's two commits

/// Source-shape assertions, the `CronSourceShapeP50Tests` precedent: the
/// symbols under review are `private` to a SwiftUI view in the iOS target,
/// which neither test host builds.
@Suite("P50b · the iOS cron editor's second door")
struct CronEditorEnabledGateP50bTests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private static var cronListView: String {
        get throws { try source("scarf/Scarf iOS/Cron/CronListView.swift") }
    }

    /// The record Hermes refuses: a one-shot that RAN is `enabled=False,
    /// state="completed", next_run_at=None` (`_complete_job_record`,
    /// `cron/jobs.py:1463-1465` @ `v2026.9.7`), and turning `enabled` back on
    /// without moving the schedule is precisely what
    /// `_reject_terminal_activation` (`:1865-1878`) raises for. The row
    /// toggle already declines it; this pins the shared offer that says so,
    /// which is the predicate the editor now consults too.
    @Test func theSharedOfferRefusesResumingACompletedOneShot() {
        let job = HermesCronJob(
            id: "job_1", name: "once", prompt: "hi",
            schedule: CronSchedule(kind: "once", runAt: "2020-01-01T00:00:00Z"),
            enabled: false, state: "completed")
        let offer = job.recoveryOffer(
            hostRefusesTerminalJobs: true,
            hostRecoversErrorRecurring: true,
            hostRefusesPastOneShotResume: true)
        #expect(offer.refusesResume,
                "the offer no longer refuses a completed one-shot — the editor gate keys on this")
        #expect(offer.canResume == false)
    }

    /// Decision 13 widened `isValid` so a spent one-shot's prompt can be
    /// saved, which newly put Save within reach of an ungated `Enabled`
    /// toggle. The editor must gate that toggle on the SAME predicate
    /// `IOSCronViewModel.setEnabled` uses, not on its own new rule.
    @Test func theEditorGatesEnabledOnTheSameOfferTheRowToggleUses() throws {
        let source = try Self.cronListView
        #expect(source.contains("private var enabledIsLocked: Bool"),
                "the editor's Enabled gate is gone — a terminal record can be re-enabled from the sheet again")
        #expect(source.contains("recoveryOffer.refusesResume"),
                "the gate no longer keys on the shared offer's refusesResume, which is what setEnabled refuses on")
        #expect(source.contains("Toggle(\"Enabled\", isOn: $enabled)\n                        .disabled(enabledIsLocked)"),
                "the Enabled toggle is not disabled by the gate")
    }

    /// The P47 lesson that a `.disabled` control still reports its binding:
    /// the gate must also keep the WRITE honest. Forcing `false` would be its
    /// own bug — a recurring job in `error` is terminal and enabled — so the
    /// locked arm writes the record's own stored flag.
    @Test func aLockedEnabledWritesTheRecordsOwnStoredFlag() throws {
        let source = try Self.cronListView
        #expect(source.contains("enabled: enabledIsLocked ? (existing?.enabled ?? enabled) : enabled"),
                "buildJob writes the sheet's enabled for a locked record — the gate is decorative")
        #expect(source.contains("enabled: enabled,") == false,
                "an ungated `enabled:` write is back in buildJob")
    }

    /// A parameter that IS the fix gets no default (round-5 lesson 10), and
    /// all three sheets must pass one: edit gets the record's offer, new and
    /// duplicate get `.none` (a duplicate's seed is `enabled: true,
    /// state: "scheduled"`, so it refuses nothing).
    @Test func everyEditorCallSitePassesAnOffer() throws {
        let source = try Self.cronListView
        #expect(source.contains("recoveryOffer: CronRecoveryOffer\n"),
                "the offer is no longer a stored property of the editor")
        #expect(source.contains("recoveryOffer: CronRecoveryOffer = ") == false,
                "the offer parameter grew a default — a forgetful caller gets the ungated editor back")
        let sites = source.components(separatedBy: "CronEditorView(").count - 1
        let passed = source.components(separatedBy: "recoveryOffer: ").count - 1
        // One declaration (`init`), one stored property, plus one per sheet.
        #expect(sites == 3, "expected three CronEditorView call sites, found \(sites)")
        #expect(passed >= sites, "a CronEditorView call site does not pass an offer")
        #expect(source.contains("recoveryOffer: vm.recoveryOffer(for: job)"),
                "the edit sheet no longer passes the record's own offer")
    }

    /// Every refusal sentence this screen shows lands in the list's top error
    /// banner and names Duplicate as the remedy
    /// (`IOSCronViewModel.resumeRefusalMessage` → "Duplicate it to schedule a
    /// new run."), while Duplicate lived only in a long-press context menu.
    /// Round-5 lesson 4 applied to a gesture rather than a CLI verb.
    @Test func duplicateIsReachableFromTheRowWithoutALongPress() throws {
        let source = try Self.cronListView
        let swipeBlock = try #require(
            source.range(of: ".swipeActions(edge: .trailing, allowsFullSwipe: false) {"),
            "the row's trailing swipe actions are gone")
        let rest = source[swipeBlock.upperBound...]
        let end = try #require(rest.range(of: "\n                        }"), "no closing brace")
        let block = String(rest[..<end.lowerBound])
        #expect(block.contains("duplicatingJob = job"),
                "Duplicate is not a swipe action — the banner names a remedy only a long press reaches")
        #expect(block.contains("Label(\"Duplicate\""))
        // The destructive action stays, and stays first.
        #expect(block.contains("Label(\"Delete\""))
    }

    /// The refusal sentence the footer renders is the SAME one the row toggle
    /// shows, so the two doors cannot drift into two wordings.
    @Test func theLockedToggleExplainsItselfWithTheRowsOwnSentence() throws {
        let source = try Self.cronListView
        #expect(source.contains("IOSCronViewModel.resumeRefusalMessage(") ,
                "the editor invented its own refusal copy instead of reusing the row's")
    }
}

/// `hermes kanban watch` takes `--assignee/--tenant/--kinds/--interval` and
/// nothing else (`hermes_cli/kanban_parser.py:359-365` @ `v2026.9.7`). P50
/// deleted `KanbanWatchFilter` for asserting a `--json` that does not exist,
/// but its alarm grepped ONE file, and the identical claim survived in
/// `HermesKanbanEvent`'s own doc comment. The alarm is the whole surface now.
@Suite("P50b · nothing claims a --json on kanban watch")
struct KanbanWatchJSONClaimP50bTests {

    private static let roots = [
        "scarf/Packages/ScarfCore/Sources",
        "scarf/scarf",
        "scarf/Scarf iOS",
    ]

    private static func swiftFiles() throws -> [URL] {
        var out: [URL] = []
        for root in roots {
            let base = CronEditorEnabledGateP50bTests.repoRoot.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append(url)
            }
        }
        return out
    }

    @Test func noSourceFileClaimsAJSONFlagOnKanbanWatch() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 100, "the scan found \(files.count) files — the roots moved")
        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("kanban watch") else { continue }
            // The verb may be NAMED; what it may not be given is a --json.
            for line in text.components(separatedBy: "\n")
            where line.contains("kanban watch") && line.contains("--json") {
                offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "a --json is claimed on `kanban watch`: \(offenders)")
    }

    /// The dead type stays dead.
    @Test func kanbanWatchFilterIsStillGone() throws {
        for url in try Self.swiftFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("KanbanWatchFilter"),
                    "KanbanWatchFilter is back in \(url.lastPathComponent)")
        }
    }
}
