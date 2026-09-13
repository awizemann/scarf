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

    /// **Three states, not two** (P54b, round-6).
    ///
    /// The text this channel carries has been three-state since P47 gave
    /// the CLI verdicts a `confidence`: a run can have succeeded, failed,
    /// or exited 0 having printed nothing that proves either. The SEAL was
    /// still two-state, so the third case wore the failure's red triangle
    /// and its "Failed:" VoiceOver prefix — asserting a refusal Hermes
    /// never made. ``MCPServerTestResultView`` already resolves the same
    /// three-way verdict into green / amber / red; this is that resolution
    /// for the shared bar.
    enum Kind: Sendable, Equatable {
        /// Hermes proved the thing happened.
        case success
        /// Exit 0 with nothing recognisable printed — we do not know.
        case unconfirmed
        /// Hermes said no, or the process failed.
        case failure
    }

    let kind: Kind

    /// True when nothing — or not everything — the user asked for happened.
    /// **Only a proven failure**: an unconfirmed run has proven nothing, and
    /// a two-way reader that folds it in here is the bug this enum ended.
    var isFailure: Bool { kind == .failure }

    static func success(_ text: String) -> OutcomeMessage {
        OutcomeMessage(text: text, kind: .success)
    }
    static func failure(_ text: String) -> OutcomeMessage {
        OutcomeMessage(text: text, kind: .failure)
    }
    /// An exit-0 run that printed no verdict. Neutral, and it does NOT
    /// auto-clear — "we do not know" is something the user must read.
    static func unconfirmed(_ text: String) -> OutcomeMessage {
        OutcomeMessage(text: text, kind: .unconfirmed)
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
    /// Whether ``message`` describes a proven failure. Read (through
    /// ``OutcomeMessageHosting/messageKind``) by `OutcomeMessageBar` for its
    /// colour, glyph and announcement.
    var messageIsFailure: Bool { get set }
    /// Whether ``message`` describes an exit-0 run that proved nothing
    /// (P54b). Mutually exclusive with ``messageIsFailure``; both false is
    /// a success. Two stored `Bool`s rather than a stored `Kind` so the
    /// nine conformers keep the property names their views and tests
    /// already read.
    var messageIsUnconfirmed: Bool { get set }
}

extension OutcomeMessageHosting {
    /// The three-state seal, recomposed from the two stored flags.
    var messageKind: OutcomeMessage.Kind {
        if messageIsFailure { return .failure }
        if messageIsUnconfirmed { return .unconfirmed }
        return .success
    }

    /// Show `outcome`, auto-clearing successes only.
    func applySaveOutcome(_ outcome: OutcomeMessage) {
        message = outcome.text
        messageIsFailure = outcome.kind == .failure
        messageIsUnconfirmed = outcome.kind == .unconfirmed
        // Only a PROVEN success fades. An unconfirmed run is a thing the
        // user has to act on (check the host), exactly like a refusal.
        guard outcome.kind == .success else { return }
        let shown = outcome.text
        DispatchQueue.main.asyncAfter(deadline: .now() + OutcomeMessage.successTTL) { [weak self] in
            // Only clear the message this timer was scheduled for: a result
            // that landed during the wait (especially a failing one) must
            // not be wiped by an older timer.
            guard let self, self.message == shown,
                  !self.messageIsFailure, !self.messageIsUnconfirmed else { return }
            self.message = nil
            self.messageIsFailure = false
            self.messageIsUnconfirmed = false
        }
    }

    /// Show a success that clears itself.
    func showSuccess(_ text: String) { applySaveOutcome(.success(text)) }

    /// Show a failure that stays until the user dismisses it or retries.
    func showSaveFailure(_ text: String) { applySaveOutcome(.failure(text)) }

    /// Show an exit-0 run that proved nothing — neutral, and it stays.
    func showUnconfirmed(_ text: String) { applySaveOutcome(.unconfirmed(text)) }

    /// Clear the bar — the dismiss button's action.
    func dismissMessage() {
        message = nil
        messageIsFailure = false
        messageIsUnconfirmed = false
    }
}
