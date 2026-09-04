import Testing
import Foundation
@testable import ScarfCore

/// `ProjectAutoAcceptEditsStore` records a per-project decision that
/// REMOVES a confirmation prompt, so the interesting tests are not the
/// round-trip — they're the ones that prove the record can't be written
/// by the party the prompt exists to guard against.
@Suite struct ProjectAutoAcceptEditsStoreTests {

    private func scratch() -> (store: ProjectAutoAcceptEditsStore, suite: String) {
        let suite = "com.scarf.tests.autoaccept.\(UUID().uuidString)"
        return (
            ProjectAutoAcceptEditsStore(
                suiteName: suite, testServiceSuffix: "aae-\(UUID().uuidString)"
            ),
            suite
        )
    }

    @Test func defaultsOffAndRoundTripsPerProject() {
        let (store, suite) = scratch()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        #expect(store.isEnabled(projectId: "/p/one") == false)

        #expect(store.setEnabled(true, projectId: "/p/one"))
        #expect(store.isEnabled(projectId: "/p/one"))
        // A decision about one project says nothing about another.
        #expect(store.isEnabled(projectId: "/p/two") == false)

        #expect(store.setEnabled(false, projectId: "/p/one"))
        #expect(store.isEnabled(projectId: "/p/one") == false)
    }

    /// The attack this store exists to stop: the agent has a terminal, so
    /// `defaults write <bundle> com.scarf.project.autoAcceptEdits./p/one
    /// on` is one command away. Without the tag that string would read
    /// back as "the user turned this on" and every future edit in the
    /// project would skip the prompt.
    @Test func untaggedRecordWrittenByHandIsIgnored() {
        let (store, suite) = scratch()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("on", forKey: "com.scarf.project.autoAcceptEdits./p/one")
        #expect(store.isEnabled(projectId: "/p/one") == false)

        // …and neither does a record that merely LOOKS tagged.
        defaults.set("on\u{1F}bm90LWEtdGFn", forKey: "com.scarf.project.autoAcceptEdits./p/one")
        #expect(store.isEnabled(projectId: "/p/one") == false)
    }

    /// A tag Scarf really minted, moved onto a different project — the
    /// payload binds the project id, so it doesn't verify there.
    @Test func tagCannotBeLiftedOntoAnotherProject() throws {
        let (store, suite) = scratch()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(store.setEnabled(true, projectId: "/p/one"))
        let genuine = try #require(
            defaults.string(forKey: "com.scarf.project.autoAcceptEdits./p/one")
        )

        defaults.set(genuine, forKey: "com.scarf.project.autoAcceptEdits./p/two")
        #expect(store.isEnabled(projectId: "/p/two") == false)
        // The original is untouched by the forgery attempt.
        #expect(store.isEnabled(projectId: "/p/one"))
    }

    /// A record from ANOTHER Mac's plist (a different machine key) is not
    /// this user's decision — it re-asks rather than importing consent.
    /// Modelled by verifying with a store on a different Keychain service.
    @Test func recordFromADifferentMachineKeyDoesNotVerify() {
        let suite = "com.scarf.tests.autoaccept.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let machineA = ProjectAutoAcceptEditsStore(
            suiteName: suite, testServiceSuffix: "aae-A-\(UUID().uuidString)"
        )
        let machineB = ProjectAutoAcceptEditsStore(
            suiteName: suite, testServiceSuffix: "aae-B-\(UUID().uuidString)"
        )

        #expect(machineA.setEnabled(true, projectId: "/p/one"))
        #expect(machineA.isEnabled(projectId: "/p/one"))
        #expect(machineB.isEnabled(projectId: "/p/one") == false)
    }

    /// Turning it OFF is a revocation and must never be blocked or
    /// half-applied — including when the stored record was a forgery we
    /// were already ignoring.
    @Test func disablingClearsEvenAnUnverifiableRecord() {
        let (store, suite) = scratch()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("on\u{1F}forged", forKey: "com.scarf.project.autoAcceptEdits./p/one")
        #expect(store.setEnabled(false, projectId: "/p/one"))
        #expect(defaults.string(forKey: "com.scarf.project.autoAcceptEdits./p/one") == nil)
    }

    /// A project id carrying the structural separator can't be signed
    /// injectively, so the write is REFUSED rather than stored under an
    /// ambiguous payload.
    @Test func projectIdCarryingTheSeparatorIsRefused() {
        let (store, suite) = scratch()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        #expect(store.setEnabled(true, projectId: "/p/one\u{1F}/p/two") == false)
        #expect(store.isEnabled(projectId: "/p/one\u{1F}/p/two") == false)
    }
}
