import Foundation
import Testing
import Stats
import StatsTesting
@testable import scarf

/// Covers the shape of the configuration `Analytics` ships — the same factory
/// the app's real client is built from — around an `InMemorySink` and a
/// `ManualClock`, so nothing here touches the network, the wall clock, or the
/// app's real Application Support directory.
/// Serialized on purpose: swift-stats persists the enabled/disabled choice in a
/// `UserDefaults` suite named after the **app id**, which every client built
/// from `Analytics.makeConfiguration` necessarily shares. Two of these tests
/// running concurrently would fight over that one switch. Each harness also
/// re-asserts the default (enabled) rather than trusting whatever a previous
/// run left behind.
@Suite("Analytics facade", .serialized)
struct AnalyticsFacadeTests {

    /// A client configured exactly as the app configures its own, but sinking
    /// into memory and storing in a throwaway directory.
    private func makeHarness() async -> (StatsClient, InMemorySink, ManualClock, URL) {
        let sink = InMemorySink()
        let clock = ManualClock()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-analytics-tests-\(UUID().uuidString)", isDirectory: true)
        let configuration = Analytics.makeConfiguration(
            sink: sink,
            isPreRelease: true,
            storageDirectory: directory,
            clock: clock
        )
        let client = StatsClient(configuration: configuration)
        await client.setEnabled(true)
        return (client, sink, clock, directory)
    }

    @Test("the shipping configuration is the one the taxonomy specifies")
    func configurationMatchesPlan() {
        let configuration = Analytics.makeConfiguration(sink: InMemorySink(), isPreRelease: true)
        #expect(configuration.appId == "com.scarf.app")
        #expect(configuration.projectId == "scarf")
        #expect(configuration.installIdSalt == "scarf-macos-2026")
        #expect(configuration.autoEvents == [.appOpen, .appBackground, .sessions])
        #expect(configuration.isPreRelease == true)
    }

    @Test("record() reaches the sink, and app_open comes from the lifecycle hook")
    func recordsEvents() async throws {
        let (client, sink, _, directory) = await makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }

        await client.applicationDidBecomeActive()
        client.record("section_viewed", props: ["section": .string("chat")])
        await client.flush()
        await client.shutdown()

        let names = await sink.sentEventNames
        #expect(names.contains("app_open"))
        #expect(names.contains("section_viewed"))

        let recorded = try #require(await sink.sentEvents.first { $0.name == "section_viewed" })
        #expect(recorded.props["section"] == .string("chat"))
    }

    @Test("setEnabled(false) stops collection")
    func honorsOptOut() async throws {
        let (client, sink, _, directory) = await makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }

        await client.setEnabled(false)
        #expect(await client.isEnabled == false)

        await client.applicationDidBecomeActive()
        client.record("section_viewed", props: ["section": .string("chat")])
        await client.flush()
        await client.shutdown()

        #expect(await sink.sentEventNames.isEmpty)

        // Leave the shared, persisted switch back at its default so this test
        // cannot disable the next one that runs.
        await client.setEnabled(true)
    }

    @Test("re-enabling after opt-out resumes collection on the same client")
    func reenablingResumesCollection() async throws {
        let (client, sink, _, directory) = await makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }

        await client.setEnabled(false)
        #expect(await client.isEnabled == false)

        client.record("section_viewed", props: ["section": .string("chat")])
        await client.flush()
        #expect(await sink.sentEventNames.isEmpty)

        await client.setEnabled(true)
        #expect(await client.isEnabled == true)

        client.record("section_viewed", props: ["section": .string("chat")])
        await client.flush()
        await client.shutdown()

        let names = await sink.sentEventNames
        #expect(names.contains("section_viewed"))

        // Leave the shared, persisted switch back at its default so this test
        // cannot disable the next one that runs.
        await client.setEnabled(true)
    }
}
