import Testing
import Foundation
@testable import ScarfCore

/// `ActivityViewModel.load()` on a LOCAL context whose state.db does not
/// exist must render the empty state, not the read-warning banner —
/// `DashboardViewModel` has treated a missing local state.db as a fresh
/// install since gh#102, and the section sweep's isolated home has no
/// state.db, so the banner was the long-standing `SectionSweepUITests`
/// red (t-a9ef75f0). A state.db that EXISTS and cannot be read still
/// warns, and the local copy must not tell the user to check SSH.
@Suite struct ActivityAbsentStateDBTests {
    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test @MainActor func aMissingLocalStateDBIsAnEmptyFeedNotAWarning() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = ActivityViewModel(context: .local(home: home))
        await vm.load()
        #expect(vm.loadError == nil)
        #expect(vm.toolMessages.isEmpty)
        #expect(vm.isLoading == false)
    }

    @Test @MainActor func anUnreadableLocalStateDBStillWarnsWithoutBlamingSSH() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("not a sqlite database".utf8).write(to: home.appendingPathComponent("state.db"))
        let vm = ActivityViewModel(context: .local(home: home))
        await vm.load()
        let error = try #require(vm.loadError)
        #expect(!error.contains("SSH"))
        #expect(error.contains("Can't read Hermes state"))
    }
}
