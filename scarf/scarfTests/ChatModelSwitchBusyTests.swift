import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P1a — Hermes >= v0.21.4 refuses `session/set_model` while a turn is
/// running (`acp_adapter/server.py:1024-1026` @ v2026.9.21: `-32603
/// "Session is busy; switch models while the session is idle"`); older
/// hosts swapped the agent mid-turn. The chat header's model badge stays
/// reachable mid-turn on every host (hiding it would change pre-target
/// behaviour, C1), so the refusal must land as a clean, attributable
/// failure: the optimistic badge flip reverts and the banner carries
/// Hermes's own sentence — never a silent success, never a hang.
@Suite("P1a — mid-turn model switch refused by a busy session")
struct ChatModelSwitchBusyTests {

    typealias Channel = ChatViewModelStartLifecycleTests.ScriptedACPChannel

    @Test @MainActor func busyRefusalRevertsTheBadgeAndSurfacesHermesReason() async throws {
        let home = try ChatViewModelStartLifecycleTests.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = Channel(behavior: .busyOnSetModel(sessionId: "sess-busy"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }

        vm.startNewSession()
        let ready = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(ready)
        #expect(vm.currentModelPreset == nil)

        let preset = ModelPreset(name: "Fast", modelID: "claude-haiku", providerID: "anthropic")
        vm.switchModelPreset(preset)
        // Optimistic flip happens synchronously…
        #expect(vm.currentModelPreset?.id == preset.id)

        // …and is rolled back once the -32603 frame lands.
        let surfaced = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpError != nil
        }
        #expect(surfaced, "the busy refusal never surfaced")
        #expect(await ch.sentMethods.contains("session/set_model"))
        #expect(vm.currentModelPreset == nil, "the badge kept the model Hermes refused")
        #expect(vm.acpError?.contains("Session is busy") == true,
                "banner lost Hermes's reason: \(vm.acpError ?? "nil")")
        vm.leaveChat()
    }
}
