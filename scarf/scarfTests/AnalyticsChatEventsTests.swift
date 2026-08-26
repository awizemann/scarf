import Foundation
import Testing
import Stats
import StatsTesting
import ScarfCore
@testable import scarf

/// Phase 4 (chat, session & Hermes) instrumentation, app-side half: the
/// classification helpers whose output becomes a prop, and one end-to-end
/// pass proving a `ScarfCore` turn event reaches the app's sink through the
/// bridge — the same shape `AnalyticsConnectionEventsTests` uses for Phase 3.
///
/// Nested inside Phase 3's suite because `.serialized` covers a suite *and
/// its subgroups* but not its siblings: both suites build real `StatsClient`s
/// around `Analytics.makeConfiguration` (one app-id-keyed `UserDefaults`
/// enabled flag between them) and both install into the process-wide
/// `ScarfAnalytics.recorder`, which as top-level siblings they would clear
/// out from under each other mid-test. One serialized subtree fixes both.
extension AnalyticsConnectionEventsTests {

@Suite("Analytics chat events", .serialized)
struct AnalyticsChatEventsTests {

    /// Forwards `ScarfCore`'s seam into a specific client — the same shape as
    /// the app's private `Analytics.CoreBridge`, pointed at a test client.
    private struct TestBridge: ScarfAnalyticsRecording {
        let client: StatsClient
        func record(_ name: String, _ props: [String: String]) {
            client.record(name, props: props.mapValues { StatsValue.string($0) })
        }
    }

    private func makeHarness() async -> (StatsClient, InMemorySink, URL) {
        let sink = InMemorySink()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-analytics-chat-\(UUID().uuidString)", isDirectory: true)
        let client = StatsClient(configuration: Analytics.makeConfiguration(
            sink: sink,
            isPreRelease: true,
            storageDirectory: directory,
            clock: ManualClock()
        ))
        await client.setEnabled(true)
        return (client, sink, directory)
    }

    // MARK: - The seam, for a Phase 4 event

    @Test("an agent turn finished inside ScarfCore lands in the app's sink")
    @MainActor
    func turnEventReachesTheSink() async throws {
        let (client, sink, directory) = await makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }

        ScarfAnalytics.install(TestBridge(client: client))
        defer { ScarfAnalytics.install(nil) }

        // Drive the real emission site: a user send, a tool call, a clean
        // finish. `RichChatViewModel` links no analytics SDK.
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "please read config.yaml in /Users/someone")
        vm.handleACPEvent(.toolCallStart(sessionId: "s", call: ACPToolCallEvent(
            toolCallId: "call-1",
            title: "read /Users/someone/config.yaml",
            kind: "read",
            status: "in_progress",
            content: "",
            rawInput: nil
        )))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn",
            inputTokens: 10, outputTokens: 20,
            thoughtTokens: 0, cachedReadTokens: 0
        )))

        await client.flush()
        await client.shutdown()

        let completed = try #require(await sink.sentEvents.first { $0.name == "agent_turn_completed" })
        #expect(completed.props["tool_call_count_bucket"] == .string("1_3"))
        #expect(completed.props["duration_bucket"] == .string("lt_1s"))
        // Nothing about the prompt, the path, the tool, or the session may
        // ride along — the props carry the fact, never the identity.
        #expect(Set(completed.props.keys) == ["duration_bucket", "tool_call_count_bucket"])
        for value in completed.props.values {
            if case .string(let s) = value {
                for fragment in ["config.yaml", "/Users", "someone", "call-1", "read"] {
                    #expect(!s.contains(fragment))
                }
            }
        }
    }

    // MARK: - permission decision

    @Test("permission option ids collapse to approve/deny and nothing else")
    func permissionDecisions() {
        func decision(_ id: String) -> String {
            ChatViewModel.analyticsPermissionDecision(optionId: id).rawValue
        }
        #expect(decision("deny") == "deny")
        #expect(decision("reject_once") == "deny")
        #expect(decision("reject_always") == "deny")
        #expect(decision("Decline") == "deny")
        #expect(decision("cancel") == "deny")
        #expect(decision("allow") == "approve")
        #expect(decision("allow_once") == "approve")
        #expect(decision("allow_always") == "approve")
        // `allow_now` must not be swallowed by a naive "no" marker.
        #expect(decision("allow_now") == "approve")
        // An option id we've never seen still yields one of the two tokens,
        // and never echoes the id.
        let exotic = "proceed-with-/Users/someone/secret.txt"
        #expect(["approve", "deny"].contains(decision(exotic)))
        #expect(!decision(exotic).contains("/Users"))
    }

    // MARK: - input mode

    @Test("input modes are exactly the taxonomy's tokens")
    func inputModeTokens() {
        #expect(ChatViewModel.ChatInputMode.typed.rawValue == "typed")
        #expect(ChatViewModel.ChatInputMode.voice.rawValue == "voice")
        #expect(ChatViewModel.ChatInputMode.quickCommand.rawValue == "quick_command")
    }

    // MARK: - buckets, re-exposed

    @Test("the facade's tool-call bucket is the package's, not a second copy")
    func toolCallBucketIsShared() {
        for count in [0, 1, 3, 4, 10, 11, 999] {
            #expect(Analytics.toolCallCountBucket(count) == ScarfAnalytics.toolCallCountBucket(count))
        }
    }
}

}
