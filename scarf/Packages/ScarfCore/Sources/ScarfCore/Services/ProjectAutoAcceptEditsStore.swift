import Foundation

/// Which projects the user has told Scarf to start chats in with the
/// per-session edit-approval mode already set to `accept_edits`.
///
/// **What this actually is.** Hermes prompts before every file edit
/// unless the ACP session's mode says otherwise (`session/set_mode`,
/// v0.15+). Alan's projects are ones he has already decided he trusts
/// the agent to edit, and re-answering the same dialog per edit is
/// noise. So this records, per project, "open my chats here in
/// accept_edits". Enforcement stays entirely Hermes-side — sensitive
/// paths still prompt, exactly as they do when the mode is flipped by
/// hand from the chat header — Scarf only chooses the opening posture.
///
/// **Why it is not stored with the project.** It is a bypass of the
/// approval prompt, and the party the prompt protects the user FROM is
/// the agent. Everything under the project — `.scarf/manifest.json`,
/// `.scarf/dashboard.json`, the registry row in `~/.hermes/scarf/` — is
/// writable by that agent, so a setting kept there would let the asker
/// grant itself the answer: one `write_file` into the manifest and every
/// future edit in that project is pre-approved without a human ever
/// having seen a toggle. That is the same reasoning that put the
/// mini-app grant key in the Keychain and the image-host allowlist in
/// `UserDefaults`; see ``ImageHostConsentStore``.
///
/// **And the carrier is not the gate.** `UserDefaults` in the app's
/// container is harder to reach than `~/.hermes`, not out of reach — the
/// agent has a terminal, and `defaults write` is one command. So each
/// record is HMAC-tagged with the machine key ``MiniAppGrantSigner``
/// mints and keeps in the login Keychain, over `(version, projectId)`.
/// Scarf can mint the tag; the agent cannot. A record that does not
/// verify is not a record: it is ignored, the project reads as OFF, and
/// the user keeps getting the prompts they would have got anyway. Every
/// failure mode here — no key, locked Keychain, forged value, a copy of
/// the plist from another Mac — lands on "ask the user", which is the
/// only safe direction for a setting whose ON state removes a
/// confirmation.
///
/// The tag binds to the project id it was recorded under (the project
/// ROOT path, matching every other per-project Scarf surface that lacks
/// a UUID). As with the image allowlist, that binds the decision to a
/// path rather than to a project identity; the payload is already
/// composed so a stable uuid can replace the id without a format change.
public struct ProjectAutoAcceptEditsStore: Sendable {

    /// Held as a NAME rather than a `UserDefaults` instance so the store
    /// stays a `Sendable` value type. Resolving per call is a dictionary
    /// lookup, and these are user-interaction-rate operations.
    private let suiteName: String?
    private let signer: MiniAppGrantSigner
    private static let keyPrefix = "com.scarf.project.autoAcceptEdits."

    /// Structural separator inside one stored record
    /// (`<state>\u{1F}<tag>`).
    private static let recordSeparator = "\u{1F}"

    /// Payload version. Bumping it invalidates every stored record,
    /// which turns every project back OFF — the safe direction, and the
    /// only migration this needs.
    private static let payloadVersion = "scarf-auto-accept-edits-v1"

    /// The only state that is ever STORED. "Off" is the absence of a
    /// record, never a record saying `off`: a stored negative would be
    /// something an attacker could delete to flip the setting on, and a
    /// missing key already means off.
    private static let enabledState = "on"

    /// - Parameter suiteName: a test-only defaults suite, so a suite can
    ///   set and clear without touching the user's real preferences.
    /// - Parameter testServiceSuffix: routes the signing key into a
    ///   test-only Keychain service, so a suite can sign and verify
    ///   without touching the user's real Keychain.
    public nonisolated init(suiteName: String? = nil, testServiceSuffix: String? = nil) {
        self.suiteName = suiteName
        self.signer = MiniAppGrantSigner(testServiceSuffix: testServiceSuffix)
    }

    private nonisolated var defaults: UserDefaults {
        guard let suiteName, let suite = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return suite
    }

    /// Whether this project has a VERIFIABLE record that the user turned
    /// auto-accept on. Missing record, untagged record, wrong tag, a tag
    /// minted for a different project, an unexpected state string, or a
    /// signing key that can't be reached all read as `false` — the
    /// prompts stay.
    public nonisolated func isEnabled(projectId: String) -> Bool {
        guard let record = defaults.string(forKey: Self.key(projectId)),
              let (state, tag) = Self.split(record),
              state == Self.enabledState,
              signer.isValidTag(tag, forPayload: Self.payload(projectId: projectId))
        else { return false }
        return true
    }

    /// Record (or clear) the user's choice for this project.
    ///
    /// Returns `false` when turning it ON could not be TAGGED — the
    /// Keychain wouldn't produce the machine key — because an untagged
    /// record is one this store would refuse to read back anyway, and
    /// writing it would only look like a setting to a human reading the
    /// plist. Turning it OFF always succeeds: removal needs no key, and
    /// a user revoking a bypass must never be blocked by a locked
    /// Keychain.
    @discardableResult
    public nonisolated func setEnabled(_ enabled: Bool, projectId: String) -> Bool {
        guard enabled else {
            defaults.removeObject(forKey: Self.key(projectId))
            return true
        }
        guard !projectId.contains(Self.recordSeparator),
              let tag = signer.tag(forPayload: Self.payload(projectId: projectId))
        else { return false }
        defaults.set(
            Self.enabledState + Self.recordSeparator + tag,
            forKey: Self.key(projectId)
        )
        return true
    }

    // MARK: - Record plumbing

    private nonisolated static func split(_ record: String) -> (state: String, tag: String)? {
        let parts = record.components(separatedBy: recordSeparator)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// The bytes the tag covers: version, project, state. Every field
    /// that decides WHAT was enabled and FOR WHAT is in here, so a tag
    /// cannot be lifted from one project's record into another's.
    private nonisolated static func payload(projectId: String) -> String {
        [payloadVersion, projectId, enabledState].joined(separator: recordSeparator)
    }

    private nonisolated static func key(_ projectId: String) -> String {
        keyPrefix + projectId
    }
}
