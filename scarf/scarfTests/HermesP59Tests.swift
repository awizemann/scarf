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
