import Testing
import Foundation
@testable import scarf
import ScarfCore

/// Round-6 P59 — both memory-reset consumers go through the one formatter.
///
/// The Mac `MemoryView` and the iOS `MemoryListView` carried the SAME
/// two-way collapse (`outcome.detail ?? (exit-code branch)`), written twice,
/// in two targets, under the same comment. That is the P48 "idle twin" shape:
/// a rule fixed on one member of a pair while the sibling keeps the defect.
/// The branches now live in `HermesMemoryResetVerdict.failureSummary`
/// (behaviour: `MemoryResetFailureSummaryP59Tests`, in ScarfCore, where the
/// verdict lives) and this pins that neither view has quietly reimplemented
/// them — a behavioural test on the formatter cannot see a view that stopped
/// calling it.
@Suite("the memory-reset alert text has one home (P59)")
struct MemoryResetConsumersP59Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    /// The two consumers, by path — both roots, because the iOS twin lives in
    /// a target this suite does not compile.
    private static let consumers = [
        "scarf/scarf/Features/Memory/Views/MemoryView.swift",
        "scarf/Scarf iOS/Memory/MemoryListView.swift",
    ]

    @Test("every memory-reset consumer calls the shared formatter")
    func consumersCallTheFormatter() throws {
        for relative in Self.consumers {
            let url = Self.repoRoot.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            // Premise: the file still judges memory reset at all. A consumer
            // that was renamed away would otherwise pass by absence.
            #expect(source.contains("HermesMemoryResetVerdict.judge"), Comment(rawValue:
                "\(relative) no longer judges `memory reset` — this list is stale"))
            #expect(source.contains("HermesMemoryResetVerdict.failureSummary"), Comment(rawValue: """
                \(relative) builds the failure text itself. The three branches \
                have one home so the two twins cannot drift; the last time \
                they were written twice, both collapsed `.unconfirmed` into \
                the quoted arm.
                """))
            // And the collapsed shape itself, gone. Comments are not code:
            // both files EXPLAIN `detail ??` in prose, so the needle is the
            // call, not the words.
            let code = source.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains("outcome.detail ?? (result.exitCode"), Comment(rawValue:
                "\(relative) still reaches the honest sentence only on EMPTY output"))
        }
    }
}

/// Round-6 P59 — the kanban teaching sheet is gated on `hasKanban`.
///
/// The sheet's button runs `hermes tools enable kanban --platform cli`. On a
/// host below the flag's floor `kanban` is not a toolset, so that argv is an
/// unknown verb: Hermes routes it to the AGENT and exits 0 (charter C5). The
/// trigger had NO version gate at all, while its own doc comment claimed a
/// v0.12 skip that no line implemented — and the floor is v0.13 anyway
/// (`hermes_cli/kanban.py` does not exist at `v2026.4.30`; the module
/// arrives at `v2026.5.7`, and the slash roster's `CommandDef("kanban", …)`
/// is `hermes_cli/commands.py:163` at that tag — NOT in `kanban.py`, which
/// is what P59 wrote and P60 re-opened both tags to correct).
///
/// The detector cannot stand in for the gate: it reads `config.yaml`, and a
/// 0.12 config has no `kanban` in its toolsets for exactly the reason the
/// sheet must not offer to add one — `.disabled` is what a pre-floor host
/// answers.
@Suite("the kanban teaching sheet follows the host (P59)")
@MainActor
struct KanbanOnboardingGateP59Tests {

    private static func caps(_ line: String) -> HermesCapabilities {
        HermesCapabilities.parseLine(line)
    }

    @Test("a 0.12 host is never offered a toolset it does not have")
    func aPreFloorHostNeverTriggers() {
        let host = Self.caps("Hermes Agent v0.12.0 (2026.4.30)")
        #expect(host.detected, "the fixture must parse, or this passes for the wrong reason")
        #expect(host.hasKanban == false)
        #expect(ChatViewModel.shouldOfferKanbanOnboarding(
            capabilities: host, dismissed: false) == false, """
            A 0.12 host is offered `hermes tools enable kanban`, which that \
            host routes to the agent at exit 0 (charter C5).
            """)
    }

    @Test("a 0.13 host can be offered it")
    func theFloorHostTriggers() {
        let host = Self.caps("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(host.hasKanban)
        #expect(ChatViewModel.shouldOfferKanbanOnboarding(capabilities: host, dismissed: false))
    }

    @Test("dismissal still suppresses it on a supported host")
    func dismissalStillWins() {
        let host = Self.caps("Hermes Agent v0.21.1 (2026.9.7)")
        #expect(host.hasKanban)
        #expect(ChatViewModel.shouldOfferKanbanOnboarding(
            capabilities: host, dismissed: true) == false)
    }

    /// An unwired / undetected store must stay quiet rather than teach a
    /// feature it cannot confirm exists.
    @Test("undetected capabilities do not trigger")
    func emptyCapabilitiesDoNotTrigger() {
        #expect(HermesCapabilities.empty.detected == false)
        #expect(ChatViewModel.shouldOfferKanbanOnboarding(
            capabilities: .empty, dismissed: false) == false)
    }

    /// The gate is reached from the `/goal` arm, and the doc block belongs to
    /// the function it documents — `a275f59a` inserted
    /// `goalArgumentDescribesATarget` between the two, so the "skipped
    /// when…" list read as documentation of the argument parser.
    @Test("the trigger reads the capability, and its doc sits on it")
    func theCallSiteAndTheDocAreInPlace() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("Self.shouldOfferKanbanOnboarding("),
                "`maybeTriggerKanbanOnboarding` no longer consults the gate")
        let doc = try #require(source.range(of: "/// Decide whether to surface the toolset-off teaching sheet"))
        let after = source[doc.upperBound...].prefix(1400)
        #expect(after.contains("private func maybeTriggerKanbanOnboarding()"), """
            The "skipped when…" doc block is not attached to \
            `maybeTriggerKanbanOnboarding` — it documents whatever \
            declaration follows it.
            """)
        #expect(!after.prefix(900).contains("static func goalArgumentDescribesATarget"),
                "`goalArgumentDescribesATarget` is between the doc and its function again")
        // And the corrected version, with the tag the flag's floor cites.
        #expect(after.contains("v0.13"), "the skip bullet still names the wrong floor")
        #expect(after.contains("v2026.5.7"), "the floor is claimed without its tag (charter C2)")
    }
}
