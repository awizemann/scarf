import Testing
import Foundation
@testable import ScarfCore

/// The Live Voice consent rule and its per-device store (F4, t-ba3ccc85).
@Suite @MainActor struct VoiceDataConsentTests {

    /// A throwaway defaults suite per test, so nothing touches the real one.
    private static func store() -> VoiceDataConsentStore {
        let suite = "scarf.tests.voiceConsent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return VoiceDataConsentStore(defaults: defaults)
    }

    private static let other = VoiceDataRecipient(id: "acme", displayName: "Acme", disclosureVersion: 1)

    @Test func gptLiveDeclaresOpenAIAndChainedDeclaresNobody() {
        #expect(GPTLiveEngine.externalRecipient == .openAI)
        #expect(VoiceChatMode.gptLive.externalRecipient == .openAI)
        #expect(VoiceChatMode.chained.externalRecipient == nil)
    }

    /// A mode whose data stays local never asks, whatever the store holds.
    @Test func aModeWithNoExternalRecipientNeedsNoConsent() {
        let store = Self.store()
        #expect(VoiceDataConsent.pendingRecipient(for: nil, store: store) == nil)
        #expect(VoiceDataConsent.pendingRecipient(for: VoiceChatMode.chained.externalRecipient, store: store) == nil)
    }

    @Test func anExternalRecipientNeedsConsentUntilRecorded() {
        let store = Self.store()
        #expect(VoiceDataConsent.pendingRecipient(for: .openAI, store: store) == .openAI)
        store.recordConsent(to: .openAI)
        #expect(VoiceDataConsent.pendingRecipient(for: .openAI, store: store) == nil)
        #expect(store.consentDate(for: .openAI) != nil)
    }

    @Test func consentIsPerRecipient() {
        let store = Self.store()
        store.recordConsent(to: .openAI)
        #expect(VoiceDataConsent.pendingRecipient(for: Self.other, store: store) == Self.other)
        store.recordConsent(to: Self.other)
        store.resetConsent(for: Self.other)
        #expect(store.hasConsented(to: .openAI))
        #expect(!store.hasConsented(to: Self.other))
    }

    @Test func resetAsksAgain() {
        let store = Self.store()
        store.recordConsent(to: .openAI)
        store.resetConsent(for: .openAI)
        #expect(VoiceDataConsent.pendingRecipient(for: .openAI, store: store) == .openAI)
        #expect(store.consentDate(for: .openAI) == nil)
    }

    /// A new disclosure version (what is sent changed) asks every device
    /// again.
    @Test func aNewDisclosureVersionAsksAgain() {
        let store = Self.store()
        store.recordConsent(to: .openAI)
        let revised = VoiceDataRecipient(id: "openai", displayName: "OpenAI", disclosureVersion: 2)
        #expect(VoiceDataConsent.pendingRecipient(for: revised, store: store) == revised)
    }

    /// The acceptance persists in the defaults, so a new store (a relaunch)
    /// remembers it.
    @Test func consentSurvivesANewStoreOverTheSameDefaults() {
        let suite = "scarf.tests.voiceConsent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        VoiceDataConsentStore(defaults: defaults).recordConsent(to: .openAI)
        #expect(VoiceDataConsentStore(defaults: defaults).hasConsented(to: .openAI))
    }
}
