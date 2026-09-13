import Foundation
import Testing
import ScarfCore
@testable import scarf

/// GW-F4 — the outcome-typed message channel.
///
/// The bug this pins: twenty-one save bars rendered a `String?` channel with
/// a green checkmark, so every guarded-write refusal the GW-E arc added
/// ("Failed to write .env", a `registryBusy` contention failure) was shown
/// to the user as a SUCCESS. The rendering is a SwiftUI view and hard to
/// assert on; the semantics it reads are view-model state, and that is what
/// is tested here — per the house rule of keeping the testable part in the
/// view models.
@Suite("Outcome-typed message channel (GW-F4)")
@MainActor
struct GwF4OutcomeMessageChannelTests {

    /// A minimal conformer: the protocol's whole contract is these two
    /// stored properties plus the shared extension's behaviour.
    private final class Host: OutcomeMessageHosting {
        var message: String?
        var messageIsFailure = false
        var messageIsUnconfirmed = false
    }

    // MARK: - The outcome is a stored fact, not a string comparison

    @Test("a failure sets the failure flag alongside the prose")
    func failureIsTyped() {
        let host = Host()
        host.showSaveFailure("Failed to write .env")
        #expect(host.message == "Failed to write .env")
        #expect(host.messageIsFailure)
    }

    @Test("a success clears the failure flag left by an earlier refusal")
    func successResetsTheFlag() {
        let host = Host()
        host.showSaveFailure("Failed to write .env")
        host.showSuccess("Saved — restart gateway to apply")
        #expect(host.messageIsFailure == false)
        #expect(host.message == "Saved — restart gateway to apply")
    }

    @Test("dismiss clears both halves of the channel")
    func dismissClearsBoth() {
        let host = Host()
        host.showSaveFailure("Failed to write .env")
        host.dismissMessage()
        #expect(host.message == nil)
        #expect(host.messageIsFailure == false)
    }

    // MARK: - Failures never auto-clear

    /// The success path schedules a clear; the failure path must schedule
    /// nothing at all. Waiting out the real TTL would make the suite slow,
    /// so this asserts the observable consequence: after the success TTL has
    /// elapsed, a failure is still on screen.
    @Test("a failure survives the success auto-clear window")
    func failureDoesNotAutoClear() async throws {
        let host = Host()
        host.showSaveFailure("Refused to overwrite config.yaml")
        try await Task.sleep(for: .seconds(OutcomeMessage.successTTL + 0.5))
        #expect(host.message == "Refused to overwrite config.yaml")
        #expect(host.messageIsFailure)
    }

    @Test("a success does auto-clear")
    func successAutoClears() async throws {
        let host = Host()
        host.showSuccess("Saved display.skin")
        // The clear IS observable, so poll for it instead of sleeping out the
        // TTL and asserting once: this returns the moment the timer fires and
        // is bounded a second past it (round-5 P48). The two neighbours below
        // assert a NON-event and have nothing to poll — see
        // `allowedFixedSleeps` in `HermesP38SourceSweepTests`.
        let deadline = Date().addingTimeInterval(OutcomeMessage.successTTL + 1)
        while Date() < deadline, host.message != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(host.message == nil)
    }

    /// The regression that made a naive timer wrong: a refusal that lands
    /// while an EARLIER success's clear timer is still pending must not be
    /// wiped by it. The timer only clears the message it was scheduled for,
    /// and never clears a failure.
    @Test("a pending success timer never wipes a refusal that landed after it")
    func aLateFailureOutlivesAnEarlierSuccessTimer() async throws {
        let host = Host()
        host.showSuccess("Saved display.skin")
        host.showSaveFailure("Failed to write .env")
        try await Task.sleep(for: .seconds(OutcomeMessage.successTTL + 0.5))
        #expect(host.message == "Failed to write .env")
        #expect(host.messageIsFailure)
    }

    // MARK: - saveForm's outcomes

    @Test("saveForm's success and failure sentences carry the right outcome")
    func saveFormOutcomesAreTyped() {
        #expect(PlatformSetupHelpers.SaveOutcome.failure("Failed to write .env").isFailure)
        #expect(PlatformSetupHelpers.SaveOutcome.success("Saved").isFailure == false)
        // A PARTIAL save is a failure: some of what the user typed is not in
        // the file, and a green checkmark over that is the misreport GW-F4
        // exists to end.
        #expect(OutcomeMessage.failure("Saved, but failed to update: a, b").isFailure)
    }

    // MARK: - Settings' channel, bridged onto its own property names

    @Test("SettingsViewModel's saveMessage rides the shared channel")
    func settingsBridgesOntoTheSharedChannel() {
        let vm = SettingsViewModel(context: .local)
        vm.showSaveFailure("Could not save gateway: config.yaml is busy")
        #expect(vm.saveMessage == "Could not save gateway: config.yaml is busy")
        #expect(vm.saveMessageIsFailure)
        vm.dismissMessage()
        #expect(vm.saveMessage == nil)
        #expect(vm.saveMessageIsFailure == false)
    }

    // MARK: - The busy message names the file it is actually about

    /// GW-F3 pointed `RegistryWriteLock` at config.yaml, `.env` and
    /// MEMORY.md as well as the projects registry, and the busy message then
    /// had only a raw path to show for them. `GuardedTextFile` already
    /// carries a per-file label; F4 threads it through.
    @Test("registryBusy names the file by its label when it has one")
    func busyMessageIsPerFile() {
        let labelled = ProjectRegistryError.registryBusy(
            path: "/Users/x/.hermes/config.yaml", label: "config.yaml"
        )
        #expect(labelled.errorDescription?.contains("config.yaml") == true)
        #expect(labelled.errorDescription?.contains("/Users/x") == false)

        // No label — the raw path, which is what the registry's own callers
        // have always shown.
        let bare = ProjectRegistryError.registryBusy(path: "/r/projects.json", label: nil)
        #expect(bare.errorDescription?.contains("/r/projects.json") == true)
    }
}
