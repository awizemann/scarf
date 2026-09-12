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
        // Two tokens, matched independently and then ORDERED — the literal
        // this replaced pinned the toggle, a newline and TWENTY-FOUR SPACES,
        // so re-indenting the file by one level (a `Form` gaining a wrapper)
        // would have reported the gate as gone (round-6 P53). What the test
        // is about is that the gate reaches the toggle, not the column the
        // toggle sits in.
        let toggle = try #require(
            source.range(of: "Toggle(\"Enabled\", isOn: $enabled)"),
            "the Enabled toggle is gone")
        let after = source[toggle.upperBound...]
        let disabled = try #require(
            after.range(of: ".disabled(enabledIsLocked)"),
            "the Enabled toggle is not disabled by the gate")
        // Nothing but whitespace between them: a `.disabled` three modifiers
        // down is on a different control.
        let between = String(after[..<disabled.lowerBound])
        #expect(between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, """
            `.disabled(enabledIsLocked)` is no longer the toggle's own \
            modifier — something sits between them.
            """)
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
        // Counted INSIDE each `CronEditorView(` argument list, not over the
        // whole file. `passed >= sites` was vacuous: `recoveryOffer: ` also
        // matches the `init` parameter and the stored property, so it read 5
        // against 3 and would have held with every call site bare
        // (round-6 P53).
        var sites = 0
        var bare: [String] = []
        var search = source.startIndex
        while let call = source.range(of: "CronEditorView(", range: search..<source.endIndex) {
            sites += 1
            search = call.upperBound
            // Brace/paren-match the argument list so a nested call cannot
            // lend its argument to this one.
            var depth = 1
            var i = call.upperBound
            var args = ""
            while i < source.endIndex, depth > 0 {
                let c = source[i]
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1; if depth == 0 { break } }
                args.append(c)
                i = source.index(after: i)
            }
            if !args.contains("recoveryOffer:") {
                bare.append(args.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        #expect(sites == 3, "expected three CronEditorView call sites, found \(sites)")
        #expect(bare.isEmpty, Comment(rawValue:
            "a CronEditorView call site passes no offer: \(bare.joined(separator: " | "))"))
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

    /// The refusal the footer renders is the SAME rule the row toggle shows,
    /// so the two doors cannot drift into two wordings.
    ///
    /// Round-6 P53 moved the footer from `resumeRefusalMessage` to
    /// `editorEnabledLockNote`, which DERIVES its reason clause from that
    /// same sentence and then names a remedy the sheet can actually reach —
    /// `resumeRefusalMessage`'s two remedies are both on the list row the
    /// sheet is covering. What this test guards is unchanged: the editor must
    /// not invent its own copy. That the two stay one rule is pinned
    /// behaviourally in `CronEditorLockNoteP53Tests`.
    @Test func theLockedToggleExplainsItselfWithTheRowsOwnSentence() throws {
        let source = try Self.cronListView
        #expect(source.contains("IOSCronViewModel.editorEnabledLockNote("),
                "the editor invented its own refusal copy instead of deriving the row's")
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

    /// A `--json` claimed on `kanban watch`, within a PROXIMITY window.
    ///
    /// Per-LINE was the shape P50b shipped, and it is the same mistake one
    /// level down from the one P50b fixed: the claim it exists to stop is as
    /// easily written as a wrapped doc comment or a multi-line argv array,
    /// and neither puts the two tokens on one line (round-6 P53). Four lines
    /// after the verb, because the real doc comment that carried the false
    /// claim wrapped across three.
    ///
    /// A DENIAL is not a claim: the CORRECT doc comment in
    /// `HermesKanbanEvent.swift` says "no `--json`" inside that same window,
    /// so the negation has to be read rather than the flag alone. The list is
    /// the markers that actually occur, not a general negation heuristic —
    /// and ``theProximityMatcherIsCalibrated`` exercises both arms, because a
    /// matcher that silently stops matching reports nothing and looks exactly
    /// like a clean tree.
    static func kanbanWatchJSONClaims(in text: String) -> [String] {
        let negations = ["no `--json`", "not `--json`", "never `--json`",
                         "no --json", "without --json", "without `--json`"]
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for (i, line) in lines.enumerated() where line.contains("kanban watch") {
            let window = Array(lines[i..<min(i + 5, lines.count)])
            let claimed = window.contains { candidate in
                guard candidate.contains("--json") else { return false }
                let lowered = candidate.lowercased()
                return !negations.contains { lowered.contains($0) }
            }
            guard claimed else { continue }
            out.append("\(i + 1): "
                       + window.joined(separator: " ⏎ ").trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    @Test func theProximityMatcherIsCalibrated() {
        // The shape the per-line matcher missed: a wrapped argv.
        let wrapped = """
            let argv = [
                "kanban", "watch",
                "--json",
            ]
            """
        #expect(Self.kanbanWatchJSONClaims(in: wrapped.replacingOccurrences(
            of: "\"kanban\", \"watch\"", with: "// kanban watch")).count == 1,
            "the matcher no longer sees a claim a few lines under the verb")
        // The shape it must NOT report: the correct doc comment.
        let denial = """
            /// `hermes kanban watch` takes
            /// `--assignee/--tenant/--kinds/--interval` and nothing else
            /// — no `--json`.
            """
        #expect(Self.kanbanWatchJSONClaims(in: denial).isEmpty,
                "the matcher reports the sentence that states the fact correctly")
        // And distance still bounds it: a `--json` on an unrelated verb five
        // lines down is not this verb's flag.
        let faraway = "// kanban watch\n\n\n\n\n// tasks export --json\n"
        #expect(Self.kanbanWatchJSONClaims(in: faraway).isEmpty,
                "the window is no longer bounded")
    }

    @Test func noSourceFileClaimsAJSONFlagOnKanbanWatch() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 100, "the scan found \(files.count) files — the roots moved")
        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("kanban watch") else { continue }
            // The verb may be NAMED; what it may not be given is a --json.
            //
            // A per-LINE match was the P50b alarm's own mistake one level
            // down: the claim it exists to stop is just as easily written as
            // a wrapped doc comment or a multi-line argv array, and neither
            // puts the two tokens on one line. A PROXIMITY window instead —
            // a `--json` within four lines of a `kanban watch` (round-6 P53).
            for hit in Self.kanbanWatchJSONClaims(in: text) {
                offenders.append("\(url.lastPathComponent):\(hit)")
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
