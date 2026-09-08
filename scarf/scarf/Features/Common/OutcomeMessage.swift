import Foundation

/// A user-facing message with its **outcome carried alongside the prose**
/// rather than encoded in it (GW-F4).
///
/// Twenty-one surfaces used to render a bare `String?` channel with a green
/// checkmark, so every guarded-write refusal the GW-E arc added — "Failed
/// to write .env", "Another Scarf process is updating config.yaml" — showed
/// up as a success badge over a save that never happened. The one view
/// model that did try to distinguish them compared the message text, which
/// is a lie waiting on the next copy edit.
///
/// The outcome is a stored fact from here on. `OutcomeMessageBar` reads it
/// for colour, glyph and the VoiceOver announcement;
/// ``OutcomeMessageHosting`` reads it to decide whether the message may
/// auto-clear.
/// `nonisolated`: the app target defaults to `@MainActor` isolation, and
/// this value is built inside `Task.detached` bodies (`saveForm`,
/// `GatewayBehaviorViewModel`'s two-step save) that are off the main actor
/// by design. It is an immutable `Sendable` pair of a string and a flag —
/// there is nothing here for isolation to protect.
nonisolated struct OutcomeMessage: Sendable, Equatable {
    /// The prose to show. Deliberately verbatim: the refusal messages name
    /// the file, the decision and the remedy, and a paraphrase loses the
    /// remedy.
    let text: String
    /// True when nothing — or not everything — the user asked for happened.
    let isFailure: Bool

    static func success(_ text: String) -> OutcomeMessage {
        OutcomeMessage(text: text, isFailure: false)
    }
    static func failure(_ text: String) -> OutcomeMessage {
        OutcomeMessage(text: text, isFailure: true)
    }

    /// Grace period before a SUCCESS message clears itself. Failures never
    /// use it — see ``OutcomeMessageHosting/applySaveOutcome(_:)``.
    static let successTTL: TimeInterval = 3
}

/// The outcome-typed message channel shared by every save bar and toast in
/// the app (GW-F4).
///
/// The conforming view models each had the same four lines — assign the
/// message, schedule a three-second clear — with no record of whether the
/// operation had actually succeeded. Conforming here gives them one call
/// that stores the outcome and, crucially, **skips the clear timer on a
/// failure**: a refusal the user blinked past is the same as no refusal at
/// all, and it is exactly the failure mode this batch exists to end.
@MainActor
protocol OutcomeMessageHosting: AnyObject {
    /// The prose currently on the bar. `nil` = nothing shown.
    var message: String? { get set }
    /// Whether ``message`` describes a failure. Read by
    /// `OutcomeMessageBar` for its colour, glyph and announcement.
    var messageIsFailure: Bool { get set }
}

extension OutcomeMessageHosting {
    /// Show `outcome`, auto-clearing successes only.
    func applySaveOutcome(_ outcome: OutcomeMessage) {
        message = outcome.text
        messageIsFailure = outcome.isFailure
        guard !outcome.isFailure else { return }
        let shown = outcome.text
        DispatchQueue.main.asyncAfter(deadline: .now() + OutcomeMessage.successTTL) { [weak self] in
            // Only clear the message this timer was scheduled for: a result
            // that landed during the wait (especially a failing one) must
            // not be wiped by an older timer.
            guard let self, self.message == shown, !self.messageIsFailure else { return }
            self.message = nil
            self.messageIsFailure = false
        }
    }

    /// Show a success that clears itself.
    func showSuccess(_ text: String) { applySaveOutcome(.success(text)) }

    /// Show a failure that stays until the user dismisses it or retries.
    func showSaveFailure(_ text: String) { applySaveOutcome(.failure(text)) }

    /// Clear the bar — the dismiss button's action.
    func dismissMessage() {
        message = nil
        messageIsFailure = false
    }
}
