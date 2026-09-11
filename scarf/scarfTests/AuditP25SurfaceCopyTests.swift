import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Round-2 whole-surface audit, P25 — surface completeness and copy.
///
/// Two behaviours that were wrong in ways only the composed string or the
/// composed argv shows: the kanban card footer's relative time, and the
/// session export's handling of `trace`.
@MainActor
@Suite struct AuditP25SurfaceCopyTests {

    // MARK: - Kanban card footer: one "ago", not two

    /// `RelativeDateTimeFormatter.localizedString` already returns a full
    /// phrase ("3 min. ago"), so an arm that appends its own " ago" produces
    /// "3 min. ago ago" — which is what every done/todo/ready/triage card
    /// showed, in the footer AND in the accessibility label that reuses this
    /// string. The expectation is built from the same formatter the view
    /// uses, so it holds in any locale.
    @Test func doneCardFooterDoesNotDoubleTheAgoSuffix() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let completed = now.addingTimeInterval(-3 * 60)
        let iso = ISO8601DateFormatter().string(from: completed)
        let phrase = KanbanCardView.relativeShort(from: iso, now: now)
        #expect(phrase != nil)

        let label = KanbanCardView.relativeTimeLabel(
            status: .done,
            startedAt: nil,
            createdAt: nil,
            completedAt: iso,
            now: now
        )
        #expect(label == "done \(phrase!)")
        #expect(!label.hasSuffix("ago ago"))
    }

    /// Same bug in the `default` arm (todo / ready / triage), which rendered
    /// the bare relative phrase plus " ago".
    @Test func todoCardFooterDoesNotDoubleTheAgoSuffix() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200))
        let phrase = KanbanCardView.relativeShort(from: iso, now: now)
        let label = KanbanCardView.relativeTimeLabel(
            status: .todo,
            startedAt: nil,
            createdAt: iso,
            completedAt: nil,
            now: now
        )
        #expect(label == phrase)
        #expect(!label.hasSuffix("ago ago"))
    }

    /// The arms that were already correct stay correct: `running` prefixes
    /// and never suffixes, and a missing/garbage timestamp degrades to the
    /// bare status word rather than a dangling phrase.
    @Test func runningAndMissingTimestampArmsUnchanged() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let phrase = KanbanCardView.relativeShort(from: iso, now: now)!
        #expect(KanbanCardView.relativeTimeLabel(
            status: .running, startedAt: iso, createdAt: nil, completedAt: nil, now: now
        ) == "running \(phrase)")
        #expect(KanbanCardView.relativeTimeLabel(
            status: .running, startedAt: nil, createdAt: iso, completedAt: nil, now: now
        ) == "running")
        #expect(KanbanCardView.relativeTimeLabel(
            status: .done, startedAt: nil, createdAt: nil, completedAt: "not-a-date", now: now
        ) == "done")
        #expect(KanbanCardView.relativeTimeLabel(
            status: .todo, startedAt: nil, createdAt: nil, completedAt: nil, now: now
        ).isEmpty)
    }

    // MARK: - Export argv: the redact toggle keeps one meaning

    /// `trace` inverts the flag: it redacts unconditionally and `--no-redact`
    /// is the opt-out (`hermes_cli/sessions_cmd.py:394`,
    /// `subcommands/sessions.py:83` at v2026.9.7). `--redact` is read only by
    /// `_cmd_export`'s `_redact` closure, which the trace path never calls —
    /// so sending it was a no-op and the toggle did nothing at all.
    @Test func traceExportOptsOutOfRedactionInsteadOfAskingForIt() {
        let off = SessionsViewModel.exportArguments(
            output: "-", sessionId: "s1", format: .trace, redact: false,
            traceNoRedactAvailable: true
        )
        #expect(off == ["sessions", "export", "-", "--format", "trace", "--no-redact", "--session-id", "s1"])

        let on = SessionsViewModel.exportArguments(
            output: "-", sessionId: "s1", format: .trace, redact: true,
            traceNoRedactAvailable: true
        )
        #expect(on == ["sessions", "export", "-", "--format", "trace", "--session-id", "s1"])
        #expect(!on.contains("--redact"))
    }

    /// C1: `--no-redact` is registered for the first time at v2026.9.7, so a
    /// 0.21.0 host must never be handed it — argparse would exit 2 and the
    /// export would produce nothing. That host redacts traces anyway, so the
    /// argv is simply the unflagged one.
    @Test func traceExportWithholdsNoRedactBelowItsFloor() {
        let args = SessionsViewModel.exportArguments(
            output: "-", sessionId: "s1", format: .trace, redact: false,
            traceNoRedactAvailable: false
        )
        #expect(args == ["sessions", "export", "-", "--format", "trace", "--session-id", "s1"])
    }

    /// Every other format keeps the original polarity, including the
    /// pre-0.20 default shape the older argv tests pin.
    @Test func nonTraceFormatsKeepTheRedactFlag() {
        #expect(SessionsViewModel.exportArguments(
            output: "-", sessionId: nil, format: .jsonl, redact: true
        ) == ["sessions", "export", "-", "--redact"])
        #expect(SessionsViewModel.exportArguments(
            output: "/tmp/out.html", sessionId: "s1", format: .html, redact: true
        ) == ["sessions", "export", "/tmp/out.html", "--format", "html", "--redact", "--session-id", "s1"])
        #expect(SessionsViewModel.exportArguments(
            output: "-", sessionId: nil
        ) == ["sessions", "export", "-"])
    }

    // MARK: - "Export All" cannot serve trace

    /// With neither `--session-id` nor a filter, `_export_trace` resolves ONE
    /// session — `list_sessions_rich(limit=1, order_by_last_active=True)`
    /// (`hermes_cli/sessions_cmd.py:385-389`) — while Scarf's banner claimed
    /// the whole board. The CLI's multi-session trace path writes a directory
    /// of files and can't stream to the save panel's single file either, so
    /// the format is withheld from this flow instead.
    @Test func exportAllDoesNotOfferTrace() {
        let vm = SessionsViewModel(context: .local)
        vm.exportAll(formatsAvailable: true, traceNoRedactAvailable: true)
        #expect(vm.showExportOptionsSheet)
        #expect(vm.exportAllExcludesTrace)
        #expect(!vm.availableExportFormats.contains(.trace))
        // Everything else stays on a local context.
        #expect(vm.availableExportFormats == [.jsonl, .markdown, .quarto, .html])
    }

    /// A single session's export still offers it — that path passes
    /// `--session-id`, which is the branch `_export_trace` handles honestly.
    @Test func singleSessionExportStillOffersTrace() {
        let vm = SessionsViewModel(context: .local)
        vm.exportSession(
            Self.stubSession(id: "sess-1"),
            formatsAvailable: true,
            traceNoRedactAvailable: true
        )
        #expect(vm.showExportOptionsSheet)
        #expect(!vm.exportAllExcludesTrace)
        #expect(vm.availableExportFormats.contains(.trace))
    }

    /// Cancelling clears the flow flag, so the NEXT export's picker isn't
    /// still hiding trace.
    @Test func cancellingAnExportAllRestoresTrace() {
        let vm = SessionsViewModel(context: .local)
        vm.exportAll(formatsAvailable: true)
        vm.cancelExportOptions()
        #expect(!vm.exportAllExcludesTrace)
        #expect(vm.availableExportFormats.contains(.trace))
    }

    private static func stubSession(id: String) -> HermesSession {
        HermesSession(
            id: id, source: "acp", userId: nil, model: nil, title: nil,
            parentSessionId: nil, startedAt: Date(), endedAt: nil, endReason: nil,
            messageCount: 1, toolCallCount: 0, inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, estimatedCostUSD: nil,
            reasoningTokens: 0, actualCostUSD: nil, costStatus: nil, billingProvider: nil
        )
    }
}
