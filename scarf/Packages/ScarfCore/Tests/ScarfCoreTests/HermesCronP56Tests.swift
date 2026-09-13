import Testing
import Foundation
@testable import ScarfCore

/// P56 — the iOS cron editor. Two findings: a re-timed job that kept the old
/// `next_run_at`, and the schedule validations `hermes cron edit` performs
/// that the form (which never shells it) did not.
@Suite struct CronScheduleFormRefusalP56Tests {

    // MARK: cron expressions

    @Test func aBlankCronExpressionIsRefused() {
        #expect(HermesCronJob.scheduleFormRefusal(
            kind: "cron", expression: "   ", runAt: "", carriedIntervalMinutes: nil)
            == .cronExpressionMissing)
    }

    /// `parse_schedule`'s pre-filter is "five or more whitespace fields, each
    /// `[A-Za-z\d*\-,/]+`" (`cron/jobs.py:757-758` @ `v2026.9.7`). Four
    /// fields is not a cron expression; nor is prose.
    @Test(arguments: ["0 9 * *", "every monday", "9am", "0 9 * * @daily"])
    func aMalformedCronExpressionIsRefused(_ expr: String) {
        #expect(HermesCronJob.scheduleFormRefusal(
            kind: "cron", expression: expr, runAt: "", carriedIntervalMinutes: nil)
            == .cronExpressionMalformed,
            "\(expr) passed the shape filter")
    }

    /// Named months/weekdays reach croniter on purpose, and a six-field
    /// expression (seconds) is legal — the filter only inspects the first
    /// five fields.
    @Test(arguments: ["0 9 * * 1-5", "*/15 * * * *", "0 9 * * MON-FRI", "0 0 9 * * *"])
    func arealCronExpressionIsAccepted(_ expr: String) {
        #expect(HermesCronJob.scheduleFormRefusal(
            kind: "cron", expression: expr, runAt: "", carriedIntervalMinutes: nil) == nil,
            "\(expr) was refused")
    }

    /// ASCII-exact, like the Python character class. A full-width digit is
    /// not a cron field, and `CharacterSet.alphanumerics` would have taken it.
    @Test func aNonASCIIDigitIsNotACronField() {
        #expect(!HermesCronJob.cronExpressionHasParseableShape("０ 9 * * *"))
        #expect(HermesCronJob.cronExpressionHasParseableShape("0 9 * * *"))
    }

    // MARK: interval minutes

    /// The sheet has no minutes field, so a new interval job — or one
    /// switched to `interval` from another kind — has none to write, and
    /// `compute_next_run` answers `nil` for an interval without `minutes`
    /// (`cron/jobs.py:1106-1110` @ `v2026.9.7`): scheduled forever, never run.
    @Test func anIntervalWithNoCarriedMinutesIsRefused() {
        #expect(HermesCronJob.scheduleFormRefusal(
            kind: "interval", expression: "", runAt: "", carriedIntervalMinutes: nil)
            == .intervalMinutesMissing)
    }

    /// Editing an EXISTING interval job still saves: `buildJob` carries the
    /// stored `minutes` while the kind is unchanged, so the refusal must not
    /// fire on a prompt-only edit.
    @Test func anIntervalThatCarriesItsStoredMinutesIsAccepted() {
        #expect(HermesCronJob.scheduleFormRefusal(
            kind: "interval", expression: "", runAt: "", carriedIntervalMinutes: 30) == nil)
    }

    // MARK: one-shot timestamps

    @Test(arguments: ["tomorrow at nine", "2026-13-45T99:00:00", "soon"])
    func anUnreadableOneShotTimeIsRefused(_ text: String) {
        #expect(HermesCronJob.scheduleFormRefusal(
            kind: "once", expression: "", runAt: text, carriedIntervalMinutes: nil)
            == .oneShotTimeUnparseable,
            "\(text) was accepted as a timestamp")
    }

    @Test(arguments: ["2026-09-20T09:00:00", "2026-09-20T09:00:00Z", "2026-09-20T09:00:00+02:00"])
    func areadableOneShotTimeIsAccepted(_ text: String) {
        #expect(HermesCronJob.scheduleFormRefusal(
            kind: "once", expression: "", runAt: text, carriedIntervalMinutes: nil) == nil,
            "\(text) was refused")
    }

    /// An EMPTY one-shot time belongs to `oneShotTimeIsUnusable`, which
    /// already refuses it with its own message. Two warnings under one field
    /// would be a worse form, so this gate stands down.
    @Test func anEmptyOneShotTimeIsLeftToTheOtherGate() {
        #expect(HermesCronJob.scheduleFormRefusal(
            kind: "once", expression: "", runAt: "  ", carriedIntervalMinutes: nil) == nil)
    }

    /// An unknown kind is not this gate's business — the picker only offers
    /// three, and inventing a refusal for a kind Hermes might add later would
    /// refuse a record the host wrote.
    /// Faithful to the pre-filter, which inspects `parts[:5]` and nothing
    /// beyond — so a trailing seventh field passes here exactly as it passes
    /// `parse_schedule` (`cron/jobs.py:757-758` @ `v2026.9.7`), and croniter
    /// is left to reject it on the host. Scarf refuses what Hermes's own
    /// pre-filter refuses and no more: guessing at croniter's grammar would
    /// refuse expressions the host accepts.
    @Test func theFilterStopsWhereHermesStops() {
        #expect(HermesCronJob.cronExpressionHasParseableShape("0 9 * * 1-5 extra more"))
    }

    @Test func anUnknownKindIsNotRefused() {
        #expect(HermesCronJob.scheduleFormRefusal(
            kind: "solar", expression: "", runAt: "", carriedIntervalMinutes: nil) == nil)
    }

    /// Every case carries a non-empty message — the enum is what the form
    /// renders, so a case added without copy is a blank warning row.
    @Test func everyRefusalHasCopy() {
        for refusal in CronScheduleFormRefusal.allCases {
            #expect(!refusal.message.isEmpty, "\(refusal) has no message")
        }
    }
}

/// Source-shape pins for the two fixes that live inside a SwiftUI `View`'s
/// private members, where no unit test can reach them. Brace-matched to the
/// declaration they are about, in the `CronSourceShapeP50Tests` pattern.
@Suite struct CronEditorSourceShapeP56Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    private static func editorSource() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("scarf/Scarf iOS/Cron/CronListView.swift"),
            encoding: .utf8)
    }

    /// The body of a `private var`/`private func` declaration, from its
    /// opening brace to the matching close — counted, not guessed, so a
    /// declaration that grows a nested closure is still bounded correctly.
    private static func body(of declaration: String, in source: String) throws -> String {
        let decl = try #require(
            source.range(of: declaration),
            "\(declaration) not found — it was renamed or removed")
        var depth = 0
        var started = false
        var out = ""
        for ch in source[decl.upperBound...] {
            if ch == "{" { depth += 1; started = true }
            if started { out.append(ch) }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
        }
        Issue.record("unbalanced braces after \(declaration)")
        return out
    }

    /// The HIGH. `_evaluate_due_job` fires on the STORED `next_run_at`
    /// (`cron/jobs.py:2925` @ `v2026.9.7`) and only recomputes when it is
    /// absent, so a re-timed job that carries the old value keeps the old
    /// appointment — and only `cron` kinds self-repair
    /// (`_reanchor_stale_cron`, `:2801-2819`). A moved one-shot is RETIRED
    /// unrun by `_retire_expired_oneshot` (`:2853-2865`).
    @Test func buildJobDropsNextRunAtWhenTheScheduleMoved() throws {
        let body = try Self.body(of: "private func buildJob() -> HermesCronJob", in: try Self.editorSource())
        #expect(body.contains("nextRunAt: scheduleMoved ? nil : existing?.nextRunAt"),
                "buildJob forwards next_run_at across a schedule change again")
        // The guard it reuses must still be computed from the schedule the
        // form would write, not from a sheet-dirty flag.
        #expect(body.contains("let scheduleMoved = existing?.schedule != schedule"))
    }

    /// The other runtime fields are still forwarded — the fix is scoped to
    /// the one field a schedule change invalidates, and dropping `last_run_at`
    /// or the failure counters would be its own regression.
    @Test func buildJobStillCarriesTheOtherRuntimeFields() throws {
        let body = try Self.body(of: "private func buildJob() -> HermesCronJob", in: try Self.editorSource())
        for field in ["lastRunAt: existing?.lastRunAt",
                      "lastError: existing?.lastError",
                      "deliveryFailures: existing?.deliveryFailures",
                      "lastDeliveryError: existing?.lastDeliveryError"] {
            #expect(body.contains(field), "buildJob stopped forwarding \(field)")
        }
    }

    /// Lesson 14. The form is the only validation iOS has, so `isValid` has
    /// to consult the schedule-shape refusal as well as the past-one-shot one.
    @Test func isValidConsultsTheScheduleShapeRefusal() throws {
        let source = try Self.editorSource()
        let body = try Self.body(of: "private var isValid: Bool", in: source)
        #expect(body.contains("scheduleRefusal == nil"),
                "Save no longer refuses a schedule shape Hermes would have rejected")
        #expect(body.contains("!oneShotTimeIsUnusable"),
                "the P50 decision-13 gate was dropped")
        // And the refusal is actually rendered — a grey Save with no reason
        // is the bug P50 fixed on the sibling gate.
        #expect(source.contains("cron.editor.scheduleRefusal"),
                "the refusal has no row on the sheet")
    }

    /// `carriedIntervalMinutes` must be what `buildJob` would WRITE. Passing
    /// the record's stored `minutes` unconditionally would accept a job
    /// switched from `cron` to `interval`, which carries none.
    @Test func theIntervalGateAsksWhatTheSaveWouldWrite() throws {
        let body = try Self.body(of: "private var scheduleRefusal: CronScheduleFormRefusal?",
                                 in: try Self.editorSource())
        #expect(body.contains("existing?.schedule.kind == scheduleKind"),
                "the interval gate ignores a kind switch")
        #expect(body.contains("carriedIntervalMinutes"))
    }
}
