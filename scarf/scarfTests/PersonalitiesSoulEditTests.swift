import Foundation
import Testing
import ScarfCore
@testable import scarf

/// S03-F1: the SOUL.md editor used to open blank (the draft was copied
/// before the asynchronous load finished) and Save replaced the real file
/// with that blank buffer. These pin the guards: nothing saves before the
/// file was loaded, and blanking a non-empty SOUL.md needs confirmation.
@Suite("Personalities SOUL.md edit (S03-F1)")
@MainActor
struct PersonalitiesSoulEditTests {

    @Test func decisionRefusesBeforeTheFileWasLoaded() {
        #expect(PersonalitiesViewModel.soulSaveDecision(draft: "new", loaded: false, current: "") == .refuse)
        #expect(PersonalitiesViewModel.soulSaveDecision(draft: "", loaded: false, current: "") == .refuse)
    }

    @Test func decisionAsksBeforeBlankingANonEmptyFile() {
        #expect(PersonalitiesViewModel.soulSaveDecision(draft: "  \n", loaded: true, current: "voice") == .confirmClearing)
        #expect(PersonalitiesViewModel.soulSaveDecision(draft: "", loaded: true, current: "") == .save)
        #expect(PersonalitiesViewModel.soulSaveDecision(draft: "edited", loaded: true, current: "voice") == .save)
    }

    private func makeHome(soul: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let soul {
            try soul.write(to: home.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        }
        return home
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func loadThenBlankSaveWithoutConfirmationKeepsTheFile() async throws {
        let home = try makeHome(soul: "Be kind.\n")
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = PersonalitiesViewModel(context: .local(home: home))
        #expect(!vm.soulLoaded)
        // Before the load lands, a save is a no-op (the old blank-editor path).
        vm.saveSOUL("only this")
        vm.load()
        await waitUntil { vm.soulLoaded }
        #expect(vm.soulLoaded)
        #expect(vm.soulMarkdown == "Be kind.\n")
        let path = home.appendingPathComponent("SOUL.md")
        #expect(try String(contentsOf: path, encoding: .utf8) == "Be kind.\n")

        vm.saveSOUL("")  // blank without confirmation: refused
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try String(contentsOf: path, encoding: .utf8) == "Be kind.\n")

        vm.saveSOUL("", confirmedClearing: true)
        await waitUntil { vm.soulMarkdown.isEmpty }
        #expect(try String(contentsOf: path, encoding: .utf8) == "")
    }

    @Test func absentFileLoadsAsEmptyAndSaves() async throws {
        let home = try makeHome(soul: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = PersonalitiesViewModel(context: .local(home: home))
        vm.load()
        await waitUntil { vm.soulLoaded }
        #expect(vm.soulLoaded)
        vm.saveSOUL("Hello")
        await waitUntil { vm.soulMarkdown == "Hello" }
        #expect(try String(contentsOf: home.appendingPathComponent("SOUL.md"), encoding: .utf8) == "Hello")
    }

    @Test func unreadableFileKeepsEditingOff() async throws {
        let home = try makeHome(soul: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        // Invalid UTF-8: exists, but readText returns nil.
        try Data([0xFF, 0xFE, 0xFD]).write(to: home.appendingPathComponent("SOUL.md"))
        let vm = PersonalitiesViewModel(context: .local(home: home))
        vm.load()
        await waitUntil { vm.message != nil }
        #expect(!vm.soulLoaded)
        vm.saveSOUL("x")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try Data(contentsOf: home.appendingPathComponent("SOUL.md")) == Data([0xFF, 0xFE, 0xFD]))
    }
}
