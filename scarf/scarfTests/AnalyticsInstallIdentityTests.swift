import Foundation
import Stats
import StatsTesting
import Testing
@testable import scarf

/// The install id must survive a relaunch (decision 2026-09-14, `Analytics.consent`).
///
/// Serialized like `AnalyticsFacadeTests`: these build real `StatsClient`s.
/// Each run uses its OWN app id so the SDK's defaults suite
/// (`com.wizemann.stats.<appId>`) is a throwaway — the developer's real
/// `com.scarf.app` suite is never touched — and removes that suite on exit.
@Suite(.serialized)
struct AnalyticsInstallIdentityTests {
    /// One "launch": a fresh client over the SAME app id and storage directory,
    /// wrapped in the production tracker shape (`grant` = the launch consent).
    private func launch(
        appId: String, directory: URL, grant: StatsConsent?
    ) async throws -> String {
        let sink = InMemorySink()
        var configuration = Analytics.makeConfiguration(
            sink: sink, isPreRelease: true, storageDirectory: directory, clock: ManualClock()
        )
        configuration.appId = appId
        // The control needs the SDK default at construction too, otherwise
        // the configuration alone would already persist the id on a first
        // run and the control could not show the ephemeral behaviour.
        if grant == nil { configuration.consent = [.usage, .diagnostics] }
        let client = StatsClient(configuration: configuration)
        let tracker = StatsUsageTracker(client: client, consent: grant)
        await tracker.setEnabled(true)
        tracker.record(.sectionViewed(section: .dashboard))
        await client.flush()
        await client.shutdown()
        let ids = Set(await sink.sentEvents.map(\.installId))
        try #require(ids.count == 1, "expected one install id per launch, got \(ids)")
        return try #require(ids.first)
    }

    private func withThrowawayInstall(
        _ body: (String, URL) async throws -> Void
    ) async throws {
        let appId = "com.scarf.app.tests.\(UUID().uuidString)"
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-install-identity-\(UUID().uuidString)", isDirectory: true)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: "com.wizemann.stats.\(appId)")
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(appId, directory)
    }

    @Test("two consecutive launches from one tracker share the install id")
    func twoLaunchesShareTheInstallId() async throws {
        try await withThrowawayInstall { appId, directory in
            let first = try await launch(appId: appId, directory: directory, grant: Analytics.consent)
            let second = try await launch(appId: appId, directory: directory, grant: Analytics.consent)
            #expect(first == second, "the install id did not persist across launches: \(first) vs \(second)")
            #expect(first.count == 64 && first.allSatisfy(\.isHexDigit),
                    "the install id on the wire is not a SHA-256 hex digest — is the raw UUID leaking? \(first)")
        }
    }

    /// The control: without the launch grant the SDK mints a fresh id per
    /// session, so an equal pair above cannot be the harness comparing a
    /// constant.
    @Test("without the `.identity` grant the install id is ephemeral")
    func withoutTheGrantTheInstallIdIsEphemeral() async throws {
        try await withThrowawayInstall { appId, directory in
            let first = try await launch(appId: appId, directory: directory, grant: nil)
            let second = try await launch(appId: appId, directory: directory, grant: nil)
            #expect(first != second, "control failed: the two ungranted sessions shared an install id")
        }
    }

    /// The grant moves an EXISTING install: a suite that already recorded the
    /// older consent (which outranks `StatsConfiguration.consent`) is upgraded
    /// by the tracker's `setConsent` on the very next launch, not the one after.
    @Test("an install that recorded the older consent is upgraded on its next launch")
    func anOlderInstallIsUpgradedOnItsNextLaunch() async throws {
        try await withThrowawayInstall { appId, directory in
            _ = try await launch(appId: appId, directory: directory, grant: [.usage, .diagnostics])
            let first = try await launch(appId: appId, directory: directory, grant: Analytics.consent)
            let second = try await launch(appId: appId, directory: directory, grant: Analytics.consent)
            #expect(first == second)
        }
    }
}
