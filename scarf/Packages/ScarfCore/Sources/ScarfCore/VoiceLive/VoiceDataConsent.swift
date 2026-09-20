import Foundation
import Observation

// Live Voice privacy consent (F4, t-ba3ccc85). Alan's rule: Scarf never
// picks a voice model or provider; it uses the voice setup the user chose in
// Hermes. When that setup sends the user's data OUTSIDE their own devices
// and Hermes host to a third party, Scarf asks once, per device and per
// recipient, before the first session. A setup that stays local declares no
// recipient and needs no consent.

/// A third party a voice engine sends the user's data to directly: audio,
/// the device's network address, and the recent chat it seeds a session
/// with. Declared by the engine (``GPTLiveEngine/externalRecipient``) and
/// mapped from Hermes's mode (``VoiceChatMode/externalRecipient``).
public struct VoiceDataRecipient: Sendable, Hashable, Identifiable {
    /// Stable storage id. Never shown.
    public let id: String
    /// The company name the consent names. A proper noun, not translated.
    public let displayName: String
    /// Bump when what the engine sends to this recipient changes in a way
    /// the user must hear about again: every device then asks again.
    public let disclosureVersion: Int

    public init(id: String, displayName: String, disclosureVersion: Int) {
        self.id = id
        self.displayName = displayName
        self.disclosureVersion = disclosureVersion
    }

    /// OpenAI, for Hermes's GPT-Live mode.
    public static let openAI = VoiceDataRecipient(id: "openai", displayName: "OpenAI", disclosureVersion: 1)

    /// Who a mode's engine sends the user's data to, or `nil` when nothing
    /// leaves the user's devices and Hermes host.
    ///
    /// `.chained` is — and must stay — `nil`: ``ChainedVoiceEngine``
    /// transcribes on-device (`requiresOnDeviceRecognition`), so the audio
    /// never leaves the device and only turn text reaches the host the chat
    /// already talks to. (The host's own TTS provider may send the REPLY text
    /// onward — Hermes's default `edge` goes to Microsoft — but that is the
    /// user's Hermes configuration, surfaced in Settings, not something Scarf
    /// routes.)
    public static func forMode(_ mode: VoiceChatMode) -> VoiceDataRecipient? {
        mode.externalRecipient
    }
}

extension VoiceChatMode {
    /// Who, outside the user's devices and Hermes host, this mode's voice
    /// sessions send data to, or `nil` when nothing leaves them (no consent
    /// needed).
    public var externalRecipient: VoiceDataRecipient? {
        switch self {
        case .gptLive: return GPTLiveEngine.externalRecipient
        case .chained: return ChainedVoiceEngine.externalRecipient   // nil: on-device STT
        }
    }
}

/// The consent rule: which recipient, if any, the user must still agree to
/// before a session with an engine that sends data to `recipient` starts.
public enum VoiceDataConsent {
    /// `nil` means start now: the engine sends nothing to a third party, or
    /// the user already agreed on this device.
    @MainActor
    public static func pendingRecipient(
        for recipient: VoiceDataRecipient?,
        store: VoiceDataConsentStore
    ) -> VoiceDataRecipient? {
        guard let recipient, !store.hasConsented(to: recipient) else { return nil }
        return recipient
    }
}

/// Where this device remembers each recipient consent: `UserDefaults`, per
/// device (never synced to the Hermes host or iCloud), per recipient and
/// disclosure version. Observable so a Settings row updates on reset.
@MainActor
@Observable
public final class VoiceDataConsentStore {
    /// The app's store, in `UserDefaults.standard`.
    public static let shared = VoiceDataConsentStore(defaults: .standard)

    @ObservationIgnored private let defaults: UserDefaults
    /// Bumped on every write, so views reading the store re-render.
    private var revision = 0

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func hasConsented(to recipient: VoiceDataRecipient) -> Bool {
        consentDate(for: recipient) != nil
    }

    /// When the user agreed on this device, or `nil`.
    public func consentDate(for recipient: VoiceDataRecipient) -> Date? {
        _ = revision
        return defaults.object(forKey: Self.key(for: recipient)) as? Date
    }

    public func recordConsent(to recipient: VoiceDataRecipient, at date: Date = Date()) {
        defaults.set(date, forKey: Self.key(for: recipient))
        revision += 1
    }

    /// Forget the consent: the next session asks again.
    public func resetConsent(for recipient: VoiceDataRecipient) {
        defaults.removeObject(forKey: Self.key(for: recipient))
        revision += 1
    }

    static func key(for recipient: VoiceDataRecipient) -> String {
        "scarf.voiceLive.consent.\(recipient.id).v\(recipient.disclosureVersion)"
    }
}
