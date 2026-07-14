import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Coverage for the mismatch banner's "Choose model…" escape hatch
/// (t-79569a15): when `model.default` carries a provider prefix that
/// `model.provider` doesn't match, the banner's one-click fixes may
/// both be wrong (and for an unknown prefix the align fix isn't even
/// offered) — the user needs a path that just opens the full model
/// picker. The pick applies through `confirmModelPreflight`'s shared
/// plan-routed write path and the banner re-evaluates afterwards.
///
/// The write path is scripted through the `modelConfigPlanApplier`
/// seam — the production applier shells out to a real `hermes` binary,
/// which would ignore the temp-home override and write the developer's
/// actual ~/.hermes.
@Suite struct ChatViewModelMismatchChooseModelTests {

    /// Records the plan handed to the applier and (optionally) mutates
    /// config.yaml the way the real `hermes config set` run would, so
    /// the post-pick diagnostics refresh reads the new state.
    final class PlanRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[LocalModelConfigPlan.Operation]] = []
        func record(_ ops: [LocalModelConfigPlan.Operation]) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(ops)
        }
        var plans: [[LocalModelConfigPlan.Operation]] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }

    /// A temp Hermes home whose config.yaml carries a provider-prefix
    /// mismatch: `model.default` names a provider (`mycorp`) that isn't
    /// the configured `model.provider` (`nous`).
    static func mismatchedHome(
        modelDefault: String = "mycorp/private-model",
        provider: String = "nous"
    ) throws -> TempHermesHome {
        let home = try TempHermesHome()
        try "model:\n  default: \(modelDefault)\n  provider: \(provider)\n"
            .write(toFile: home.path + "/config.yaml", atomically: true, encoding: .utf8)
        return home
    }

    /// Build a VM over the home with a seeded provider roster (skips
    /// the models.dev catalog load inside `refreshConfigDiagnostics`)
    /// and wait for the mismatch diagnostics to land.
    @MainActor
    static func mismatchedVM(
        home: TempHermesHome,
        roster: Set<String> = ["anthropic", "nous", "openai"]
    ) async throws -> (ChatViewModel, ModelPreflight.Mismatch) {
        let vm = ChatViewModel(context: home.context)
        vm.knownProviderIDs = roster
        vm.refreshConfigDiagnostics()
        let detected = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.modelProviderMismatch != nil
        }
        try #require(detected, "mismatch diagnostics never landed")
        return (vm, try #require(vm.modelProviderMismatch))
    }

    // MARK: - (a) The choose action is reachable from an unknown prefix

    /// An unknown-prefix mismatch (roster loaded, prefix not on it)
    /// hides the banner's "Use <prefix>" button — pre-change the user
    /// had no constructive path. `chooseModelForMismatch` must open
    /// the preflight picker sheet (same `modelPreflightReason` gate
    /// `ChatView`'s sheet binding reads) without stashing a chat-start
    /// to replay.
    @Test @MainActor func unknownPrefixMismatchExposesTheChooseAction() async throws {
        let home = try Self.mismatchedHome()
        defer { home.cleanup() }
        let (vm, mismatch) = try await Self.mismatchedVM(home: home)

        // The align gate itself is unchanged (pinned in depth by
        // ModelPreflightTests) — this pins that the scenario really is
        // the no-align one the choose action was built for.
        #expect(mismatch.prefixIsKnownProvider == false)

        #expect(vm.modelPreflightReason == nil)
        vm.chooseModelForMismatch(mismatch)
        let reason = try #require(vm.modelPreflightReason)
        #expect(reason.contains("mycorp/private-model"))
        #expect(reason.contains("nous"))
        // Banner-initiated: no interrupted chat-start exists, so a
        // cancel (or pick) must not boot a session.
        vm.cancelModelPreflight()
        #expect(vm.modelPreflightReason == nil)
        #expect(vm.isStartingSession == false)
        #expect(vm.hasActiveProcess == false)
    }

    /// Known-prefix mismatches keep the choose action too — it's on
    /// every mismatch banner, not just the unknown-prefix one.
    @Test @MainActor func knownPrefixMismatchAlsoOffersTheChooseAction() async throws {
        let home = try Self.mismatchedHome(modelDefault: "anthropic/claude-sonnet-4-5")
        defer { home.cleanup() }
        let (vm, mismatch) = try await Self.mismatchedVM(home: home)
        #expect(mismatch.prefixIsKnownProvider == true)
        vm.chooseModelForMismatch(mismatch)
        #expect(vm.modelPreflightReason != nil)
    }

    // MARK: - (b) A pick applies through the shared plan path and clears the banner

    /// Simulated pick after "Choose model…": `confirmModelPreflight`
    /// must write via `LocalModelConfigPlan` (classic two-op remote
    /// write for a config with no local keys, provider first), must
    /// NOT replay a chat start (none is pending), and the mismatch
    /// state must clear once the diagnostics re-read the coherent
    /// config.
    @Test @MainActor func pickThroughSharedApplyPathWritesPlanAndClearsMismatch() async throws {
        let home = try Self.mismatchedHome()
        defer { home.cleanup() }
        let (vm, mismatch) = try await Self.mismatchedVM(home: home)

        let recorder = PlanRecorder()
        let configPath = home.path + "/config.yaml"
        vm.modelConfigPlanApplier = { ops in
            recorder.record(ops)
            // Emulate the `hermes config set` effect so the post-pick
            // diagnostics refresh reads the coherent pair.
            try? "model:\n  default: claude-sonnet-4-5\n  provider: anthropic\n"
                .write(toFile: configPath, atomically: true, encoding: .utf8)
            return true
        }

        vm.chooseModelForMismatch(mismatch)
        vm.confirmModelPreflight(model: "claude-sonnet-4-5", provider: "anthropic")
        // The sheet gate clears synchronously at entry (same as the
        // missing-config preflight flow).
        #expect(vm.modelPreflightReason == nil)

        let applied = await ChatViewModelStartLifecycleTests.waitUntil {
            !recorder.plans.isEmpty
        }
        #expect(applied, "pick never reached the plan applier")
        // Plan-routed classic remote write: the mismatched config has
        // no local-managed keys, so the plan is exactly
        // [set provider, set model] — no clears, provider first.
        #expect(recorder.plans == [[
            .set(key: "model.provider", value: "anthropic"),
            .set(key: "model.default", value: "claude-sonnet-4-5"),
        ]])

        let cleared = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.modelProviderMismatch == nil
        }
        #expect(cleared, "mismatch banner never re-evaluated after the pick")
        // No stashed start args → the pick must not boot a session.
        #expect(vm.isStartingSession == false)
        #expect(vm.hasActiveProcess == false)
        #expect(vm.acpError == nil)
    }

    // MARK: - (c) Plan refusal surfaces the save-failed banner

    /// Belt-and-braces: if the confirmed pick is one the plan REFUSES
    /// (empty plan — a local-provider target with no sourceable base
    /// URL; unreachable through the picker, which requires the base
    /// URL, but the seam contract says [] is possible), the existing
    /// save-failed error banner must surface and the mismatch must
    /// stay: config.yaml was not touched.
    @Test @MainActor func planRefusalSurfacesSaveFailedBanner() async throws {
        let home = try Self.mismatchedHome(modelDefault: "vllm/some-model")
        defer { home.cleanup() }
        let (vm, mismatch) = try await Self.mismatchedVM(home: home)

        let recorder = PlanRecorder()
        vm.modelConfigPlanApplier = { ops in
            recorder.record(ops)
            return true
        }

        vm.chooseModelForMismatch(mismatch)
        // vllm is a local descriptor; the config has no model.base_url
        // and the descriptor has no default endpoint, so the plan
        // returns [] (pinned in LocalModelConfigPlanTests).
        vm.confirmModelPreflight(model: "some-model", provider: "vllm")

        let failed = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpError != nil
        }
        #expect(failed, "refused plan never surfaced the save-failed banner")
        #expect(vm.acpError?.contains("Couldn't save model+provider") == true)
        // An empty plan is a refusal BEFORE the applier — nothing may
        // have been written.
        #expect(recorder.plans.isEmpty)
        #expect(vm.modelProviderMismatch != nil, "mismatch cleared without a config write")
    }
}
