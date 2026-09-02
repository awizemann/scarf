import Foundation
import Testing
@testable import ScarfCore

/// F6 — the bounded-read half of the "unbounded/eager work" sweep.
///
/// `HermesLogService.readLastLines` used `FileManager.contents(atPath:)` on
/// the local branch, loading a whole `agent.log` into memory to take its last
/// 500 lines. These pin the replacement: same lines out, without the file
/// coming with them.
@Suite("SectionAuditF6BoundedRead")
struct SectionAuditF6BoundedReadTests {

    private func makeEntry(_ raw: String, id: Int = 0) -> LogEntry {
        LogEntry(
            id: id, timestamp: "", level: .info, sessionId: nil,
            logger: "agent", message: raw, raw: raw
        )
    }

    private func write(_ contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("f6-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("agent.log").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func returnsTheLastNLinesInOrder() throws {
        let path = try write((1...1_000).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let lines = HermesLogService.readLocalTail(path: path, count: 500)
        #expect(lines.count == 500)
        #expect(lines.first == "line 501")
        #expect(lines.last == "line 1000")
    }

    /// The whole point: a file far larger than the window must not be read in
    /// full. The observable proxy is that a short window over a big file still
    /// returns exactly the window, and does it without the process resident
    /// size mattering — assert the content contract, which the old
    /// whole-file read also satisfied, PLUS the chunked reader's own edge:
    /// the oldest returned line is never a partial one.
    @Test func neverReturnsAPartialFirstLine() throws {
        // Lines long enough that a 500-line window spans many 64 KiB chunks,
        // so the window boundary lands mid-line with near certainty.
        let body = String(repeating: "x", count: 300)
        let path = try write((1...5_000).map { "line \($0) \(body)" }.joined(separator: "\n") + "\n")
        let lines = HermesLogService.readLocalTail(path: path, count: 500)
        #expect(lines.count == 500)
        for line in lines {
            #expect(line.hasPrefix("line "))
            #expect(line.hasSuffix(body))
        }
        #expect(lines.last == "line 5000 \(body)")
    }

    @Test func shortFileReturnsEverythingAndKeepsItsFirstLine() throws {
        let path = try write("alpha\nbeta\ngamma\n")
        let lines = HermesLogService.readLocalTail(path: path, count: 500)
        // The whole file fits in the first chunk, so offset stays 0 and the
        // first line must NOT be dropped as partial.
        #expect(lines == ["alpha", "beta", "gamma"])
    }

    @Test func emptyAndMissingFilesAreEmpty() throws {
        let path = try write("")
        #expect(HermesLogService.readLocalTail(path: path, count: 500).isEmpty)
        #expect(HermesLogService.readLocalTail(path: "/nope/nothing.log", count: 500).isEmpty)
    }

    @Test func fileWithoutATrailingNewlineKeepsItsLastLine() throws {
        let path = try write("alpha\nbeta\ngamma")
        #expect(HermesLogService.readLocalTail(path: path, count: 2) == ["beta", "gamma"])
    }

    // MARK: - Retention cap

    @Test @MainActor func logsViewModelDropsOldestEntriesAndSaysSo() throws {
        let vm = LogsViewModel(context: .local)
        let cap = LogsViewModel.maxRetainedEntries
        vm.entries = (0..<cap).map { makeEntry("entry \($0)", id: $0) }
        #expect(vm.didDropOldEntries == false)
        // One over the cap: the oldest goes, and the banner arms.
        vm.appendBoundedForTesting([makeEntry("overflow", id: 999_999)])
        #expect(vm.entries.count == cap)
        #expect(vm.entries.last?.raw == "overflow")
        #expect(vm.entries.first?.raw == "entry 1")
        #expect(vm.didDropOldEntries)
    }

    @Test @MainActor func filteredEntriesTrackEveryInput() throws {
        let vm = LogsViewModel(context: .local)
        vm.entries = [
            makeEntry("alpha keep", id: 1),
            makeEntry("beta drop", id: 2),
        ]
        #expect(vm.filteredEntries.count == 2)
        // Search is an input; the memo must move with it.
        vm.searchText = "keep"
        #expect(vm.filteredEntries.map(\.raw) == ["alpha keep"])
        vm.searchText = ""
        #expect(vm.filteredEntries.count == 2)
    }
}
