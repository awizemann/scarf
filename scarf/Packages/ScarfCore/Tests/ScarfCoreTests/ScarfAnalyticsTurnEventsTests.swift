import Testing
import Foundation
@testable import ScarfCore

/// Phase 4 (chat, session & Hermes) instrumentation, `ScarfCore` half: the
/// agent-turn lifecycle events `RichChatViewModel` emits through the seam,
/// the count bucket they use, the `error_kind` mapping, and the
/// once-per-version dedupe in `HermesCapabilitiesStore`.
///
/// Nested inside `ScarfAnalyticsSeamTests` on purpose: `.serialized` covers a
/// suite *and its subgroups*, but two sibling top-level suites still run in
/// parallel — and both install into the same process-wide
/// `ScarfAnalytics.recorder`, so as siblings they clear each other's captures
/// mid-test. Nesting puts both under one serialized subtree.
extension ScarfAnalyticsSeamTests {

@Suite("ScarfAnalytics turn events", .serialized)
struct ScarfAnalyticsTurnEventsTests {

    /// Captures what `ScarfCore` emits. `@unchecked Sendable` around a lock
    /// because the seam is deliberately callable from any isolation.
    private final class Capture: ScarfAnalyticsRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(String, [String: String])] = []
        var events: [(name: String, props: [String: String])] {
            lock.lock(); defer { lock.unlock() }
            return _events.map { (name: $0.0, props: $0.1) }
        }
        func named(_ name: String) -> [[String: String]] {
            events.filter { $0.name == name }.map(\.props)
        }
        func record(_ name: String, _ props: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            _events.append((name, props))
        }
    }

    private func withCapture(_ body: (Capture) throws -> Void) rethrows {
        let capture = Capture()
        ScarfAnalytics.install(capture)
        defer { ScarfAnalytics.install(nil) }
        try body(capture)
    }

    private func toolCall(_ id: String) -> ACPToolCallEvent {
        ACPToolCallEvent(
            toolCallId: id,
            title: "read a file",
            kind: "read",
            status: "in_progress",
            content: "",
            rawInput: nil
        )
    }

    private func promptResult(_ stopReason: String) -> ACPPromptResult {
        ACPPromptResult(
            stopReason: stopReason,
            inputTokens: 1, outputTokens: 1,
            thoughtTokens: 0, cachedReadTokens: 0
        )
    }

    // MARK: - Buckets

    @Test("the tool-call count bucket covers every edge")
    func toolCallBuckets() {
        #expect(ScarfAnalytics.toolCallCountBucket(-3) == "0")
        #expect(ScarfAnalytics.toolCallCountBucket(0) == "0")
        #expect(ScarfAnalytics.toolCallCountBucket(1) == "1_3")
        #expect(ScarfAnalytics.toolCallCountBucket(3) == "1_3")
        #expect(ScarfAnalytics.toolCallCountBucket(4) == "4_10")
        #expect(ScarfAnalytics.toolCallCountBucket(10) == "4_10")
        #expect(ScarfAnalytics.toolCallCountBucket(11) == "gt_10")
        #expect(ScarfAnalytics.toolCallCountBucket(.max) == "gt_10")
    }

    // MARK: - error_kind

    @Test("stop reasons map onto the taxonomy's error_kind, and only those")
    func errorKindMapping() {
        func kind(_ reason: String) -> String? {
            RichChatViewModel.analyticsTurnErrorKind(stopReason: reason)
        }
        #expect(kind("end_turn") == nil)
        #expect(kind("END_TURN") == nil)          // case-insensitive
        #expect(kind("cancelled") == "cancelled")
        #expect(kind("canceled") == "cancelled")  // both spellings
        #expect(kind("timeout") == "timeout")
        #expect(kind("timed_out") == "timeout")
        #expect(kind("error") == "agent_error")
        #expect(kind("refusal") == "agent_error")
        #expect(kind("max_tokens") == "agent_error")
        // An unrecognized reason must collapse, never pass through: this is
        // agent-supplied text.
        let hostile = "failed for user hunter2 at /Users/someone/secret.txt"
        #expect(kind(hostile) == "agent_error")
        #expect(kind(hostile)?.contains("hunter2") == false)
    }

    // MARK: - Exactly one event per turn

    @Test @MainActor func aStreamingTurnEmitsExactlyOneCompletedEvent() {
        withCapture { capture in
            let vm = RichChatViewModel(context: .local)
            vm.setSessionId("s")
            vm.addUserMessage(text: "hello")

            // A realistic stream: chunks interleaved with two tool calls,
            // each of which drives `finalizeStreamingMessage` — the very
            // thing that resets the *user-visible* stopwatch. The analytics
            // turn must survive all of it.
            for i in 0..<2 {
                vm.handleACPEvent(.messageChunk(sessionId: "s", text: "thinking…"))
                vm.handleACPEvent(.toolCallStart(sessionId: "s", call: toolCall("t\(i)")))
                vm.handleACPEvent(.toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
                    toolCallId: "t\(i)",
                    kind: "read",
                    status: "completed",
                    content: "ok",
                    rawOutput: "ok"
                )))
            }
            vm.handleACPEvent(.messageChunk(sessionId: "s", text: "done"))
            vm.handleACPEvent(.promptComplete(sessionId: "s", response: promptResult("end_turn")))

            let completed = capture.named("agent_turn_completed")
            #expect(completed.count == 1)
            #expect(capture.named("agent_turn_failed").isEmpty)
            #expect(completed.first?["tool_call_count_bucket"] == "1_3")
            #expect(completed.first?["duration_bucket"] == "lt_1s")
            // No message text, session id, or tool name anywhere.
            for props in completed {
                #expect(Set(props.keys) == ["duration_bucket", "tool_call_count_bucket"])
                for value in props.values {
                    for leak in ["hello", "done", "thinking", "s", "read", "t0"] where leak.count > 2 {
                        #expect(!value.contains(leak))
                    }
                }
            }
        }
    }

    @Test @MainActor func aLateConnectionLossDoesNotDoubleReport() {
        withCapture { capture in
            let vm = RichChatViewModel(context: .local)
            vm.setSessionId("s")
            vm.addUserMessage(text: "hi")
            vm.handleACPEvent(.promptComplete(sessionId: "s", response: promptResult("end_turn")))
            // The transport notices the socket died *after* the turn already
            // settled. That's not a second turn, and not a failure.
            vm.handleACPEvent(.connectionLost(reason: "socket closed"))

            #expect(capture.named("agent_turn_completed").count == 1)
            #expect(capture.named("agent_turn_failed").isEmpty)
        }
    }

    @Test @MainActor func aMidRunSteerDoesNotStartASecondTurn() {
        withCapture { capture in
            let vm = RichChatViewModel(context: .local)
            vm.setSessionId("s")
            vm.addUserMessage(text: "do the thing")
            vm.handleACPEvent(.toolCallStart(sessionId: "s", call: toolCall("t0")))
            // `/steer`-shaped send: arrives while the agent is still working.
            #expect(vm.isAgentWorking)
            vm.addUserMessage(text: "actually, focus on X")
            vm.handleACPEvent(.toolCallStart(sessionId: "s", call: toolCall("t1")))
            vm.handleACPEvent(.promptComplete(sessionId: "s", response: promptResult("end_turn")))

            let completed = capture.named("agent_turn_completed")
            #expect(completed.count == 1)
            // Both tool calls belong to the one turn — the steer didn't
            // reset the tally.
            #expect(completed.first?["tool_call_count_bucket"] == "1_3")
        }
    }

    @Test @MainActor func aDroppedConnectionFailsTheTurnOnce() {
        withCapture { capture in
            let vm = RichChatViewModel(context: .local)
            vm.setSessionId("s")
            vm.addUserMessage(text: "hi")
            vm.handleACPEvent(.connectionLost(reason: "ControlMaster died"))
            vm.handleACPEvent(.connectionLost(reason: "ControlMaster died"))

            let failed = capture.named("agent_turn_failed")
            #expect(failed.count == 1)
            #expect(failed.first == ["error_kind": "connection_lost"])
            #expect(capture.named("agent_turn_completed").isEmpty)
        }
    }

    @Test @MainActor func aRefusalFailsTheTurnAsAgentError() {
        withCapture { capture in
            let vm = RichChatViewModel(context: .local)
            vm.setSessionId("s")
            vm.addUserMessage(text: "hi")
            vm.handleACPEvent(.promptComplete(sessionId: "s", response: promptResult("refusal")))

            #expect(capture.named("agent_turn_failed") == [["error_kind": "agent_error"]])
            #expect(capture.named("agent_turn_completed").isEmpty)
        }
    }

    @Test @MainActor func resettingMidTurnReportsNothing() {
        withCapture { capture in
            let vm = RichChatViewModel(context: .local)
            vm.setSessionId("s")
            vm.addUserMessage(text: "hi")
            vm.handleACPEvent(.toolCallStart(sessionId: "s", call: toolCall("t0")))
            // The user switched sessions mid-stream. The abandoned turn has
            // no honest outcome — report neither success nor failure.
            vm.reset()

            #expect(capture.named("agent_turn_completed").isEmpty)
            #expect(capture.named("agent_turn_failed").isEmpty)

            // And a stale event arriving afterwards still reports nothing.
            vm.handleACPEvent(.promptComplete(sessionId: "s", response: promptResult("end_turn")))
            #expect(capture.named("agent_turn_completed").isEmpty)
        }
    }

    @Test @MainActor func anIdleSessionNeverReportsATurn() {
        withCapture { capture in
            let vm = RichChatViewModel(context: .local)
            vm.setSessionId("s")
            // No user send: this is the auto-resume / replay shape, where
            // Hermes streams prior session state after `session/load`.
            vm.handleACPEvent(.messageChunk(sessionId: "s", text: "replayed"))
            vm.handleACPEvent(.promptComplete(sessionId: "s", response: promptResult("end_turn")))

            #expect(capture.named("agent_turn_completed").isEmpty)
            #expect(capture.named("agent_turn_failed").isEmpty)
        }
    }

    // MARK: - session_resume_fallback

    @Test @MainActor func theSlashCommandFallbackLatchesPerSession() {
        withCapture { capture in
            let vm = RichChatViewModel(context: .local)
            // No session yet: the sparse menu isn't a resume fallback.
            _ = vm.availableCommands
            #expect(capture.named("session_resume_fallback").isEmpty)

            vm.setSessionId("s")
            // Hermes never re-advertises commands after `session/load`, so
            // the menu falls back to the static list. Read it the way the
            // composer does — many times per second.
            for _ in 0..<50 { _ = vm.availableCommands }

            let fallbacks = capture.named("session_resume_fallback")
            #expect(fallbacks == [["kind": "slash_command_fallback"]])
        }
    }

    @Test @MainActor func anAdvertisedCommandListIsNotAFallback() {
        withCapture { capture in
            let vm = RichChatViewModel(context: .local)
            vm.setSessionId("s")
            vm.handleACPEvent(.availableCommands(sessionId: "s", commands: [
                ["name": "compact", "description": "compact the conversation"]
            ]))
            for _ in 0..<10 { _ = vm.availableCommands }
            #expect(capture.named("session_resume_fallback").isEmpty)
        }
    }

    // MARK: - hermes_version_detected dedupe

    @Test @MainActor func aVersionIsReportedOncePerProcess() {
        withCapture { capture in
            HermesCapabilitiesStore.resetReportedVersionsForTesting()
            defer { HermesCapabilitiesStore.resetReportedVersionsForTesting() }

            let caps = HermesCapabilities.parse("Hermes Agent v0.20.1 (2026.4.30)")
            #expect(caps.semver?.description == "0.20.1")

            // Every window's store probes the same host; a refresh re-probes.
            for _ in 0..<5 {
                HermesCapabilitiesStore.noteDetectedVersion(caps, provisional: false)
            }
            var events = capture.named("hermes_version_detected")
            #expect(events == [["version": "0.20.1", "provisional": "false"]])
            // The raw banner never reaches a prop.
            #expect(events.first?["version"] == "0.20.1")

            // A *different* version (the host was upgraded mid-session) is a
            // new fact and does report.
            let upgraded = HermesCapabilities.parse("Hermes Agent v0.21.0")
            HermesCapabilitiesStore.noteDetectedVersion(upgraded, provisional: false)
            events = capture.named("hermes_version_detected")
            #expect(events.count == 2)
            #expect(events.last?["version"] == "0.21.0")

            // So is the same version seen provisionally (remembered, not
            // probed) — but only once.
            HermesCapabilitiesStore.noteDetectedVersion(caps, provisional: true)
            HermesCapabilitiesStore.noteDetectedVersion(caps, provisional: true)
            events = capture.named("hermes_version_detected")
            #expect(events.count == 3)
            #expect(events.last == ["version": "0.20.1", "provisional": "true"])
        }
    }

    @Test @MainActor func anUnparseableVersionReportsNothing() {
        withCapture { capture in
            HermesCapabilitiesStore.resetReportedVersionsForTesting()
            defer { HermesCapabilitiesStore.resetReportedVersionsForTesting() }
            // `.empty` has no semver — and `versionLine` is exactly the kind
            // of free text that must never become a prop.
            HermesCapabilitiesStore.noteDetectedVersion(.empty, provisional: false)
            #expect(capture.named("hermes_version_detected").isEmpty)
        }
    }
}

}
