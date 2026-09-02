import Foundation
import Testing
import ScarfCore
@testable import scarf

/// F5 — the Memory editor's conflict discipline.
///
/// The pre-fix editor wrote unconditionally and re-synced its draft from the
/// view model on every `HermesFileWatcher` tick (~1.5s whenever an agent is
/// running). Both halves are covered here: the write must refuse to land on a
/// file that moved under it, and the refresh-when-CLEAN path must keep
/// working — a guard that also froze the ordinary reload would just trade one
/// bug for another.
@Suite("Memory editor conflict handling (F5)")
@MainActor
struct MemoryEditorConflictTests {

    /// An isolated `~/.hermes` so the suite never touches the developer's own
    /// memory files.
    private func makeHome() throws -> (String, ServerContext) {
        let home = NSTemporaryDirectory() + "scarf-memtest-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: home + "/memories", withIntermediateDirectories: true)
        return (home, ServerContext.local(home: URL(fileURLWithPath: home)))
    }

    private func writeMemory(_ home: String, _ text: String) throws {
        try text.write(toFile: home + "/memories/MEMORY.md", atomically: true, encoding: .utf8)
    }

    private func readMemory(_ home: String) -> String {
        (try? String(contentsOfFile: home + "/memories/MEMORY.md", encoding: .utf8)) ?? ""
    }

    @Test("A save whose baseline still matches disk lands")
    func cleanSaveLands() async throws {
        let (home, context) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try writeMemory(home, "original")

        let vm = MemoryViewModel(context: context)
        let outcome = await vm.save("mine", target: .memory, baseline: "original")

        #expect(outcome == .saved)
        #expect(readMemory(home) == "mine")
        // save() deliberately does not publish into memoryContent — the editor
        // commits that itself, after advancing its baseline. See the comment
        // on MemoryViewModel.save.
        #expect(vm.memoryContent == "")
    }

    @Test("A save is REFUSED when the file moved off the baseline")
    func staleSaveIsRefused() async throws {
        let (home, context) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try writeMemory(home, "original")

        let vm = MemoryViewModel(context: context)
        // The agent writes while the user is typing.
        try writeMemory(home, "the agent's new note")

        let outcome = await vm.save("mine", target: .memory, baseline: "original")

        #expect(outcome == .conflict(onDisk: "the agent's new note"))
        // The refusal must not have written anything.
        #expect(readMemory(home) == "the agent's new note")
    }

    @Test("force: true is the user's explicit overwrite answer")
    func forcedSaveOverwrites() async throws {
        let (home, context) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try writeMemory(home, "original")
        let vm = MemoryViewModel(context: context)
        try writeMemory(home, "the agent's new note")

        let outcome = await vm.save("mine", target: .memory, baseline: "original", force: true)

        #expect(outcome == .saved)
        #expect(readMemory(home) == "mine")
    }

    @Test("MEMORY.md and USER.md conflict independently")
    func targetsAreIndependent() async throws {
        let (home, context) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try writeMemory(home, "memory moved")
        try "user original".write(
            toFile: home + "/memories/USER.md", atomically: true, encoding: .utf8)

        let vm = MemoryViewModel(context: context)
        let user = await vm.save("user mine", target: .user, baseline: "user original")
        #expect(user == .saved)

        let memory = await vm.save("memory mine", target: .memory, baseline: "stale")
        #expect(memory == .conflict(onDisk: "memory moved"))
    }

    @Test("reload() reads the current disk copy, not the cached one")
    func reloadReadsDisk() async throws {
        let (home, context) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try writeMemory(home, "first")

        let vm = MemoryViewModel(context: context)
        #expect(await vm.reload(.memory) == "first")
        try writeMemory(home, "second")
        #expect(await vm.reload(.memory) == "second")
    }

    /// A file that has never been written reads as empty rather than failing,
    /// so a first-ever save must be a clean save against an empty baseline —
    /// not a phantom conflict that makes the editor unusable on a fresh host.
    @Test("First save on a fresh install is not a conflict")
    func firstSaveOnFreshInstall() async throws {
        let (home, context) = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let vm = MemoryViewModel(context: context)
        let outcome = await vm.save("first ever", target: .memory, baseline: "")

        #expect(outcome == .saved)
        #expect(readMemory(home) == "first ever")
    }
}
