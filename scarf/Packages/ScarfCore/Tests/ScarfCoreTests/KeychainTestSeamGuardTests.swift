import Testing
import Foundation
@testable import ScarfCore

/// Guards the fix for the keychain-prompt stall described in the
/// `mac-scarftests-run-green-only-serially` memory note: several scarfTests
/// reached the REAL login-keychain item `com.scarf.miniapp-grants` /
/// `hmac-key-v1` through `MiniAppGrantSigner.signingKey()` — every fresh,
/// ad-hoc-signed test build is a new code identity, so `Security.framework`
/// either mints a SecurityAgent consent prompt or blocks on one for an
/// existing item's ACL, and an unattended run stalls with nobody to answer
/// it.
///
/// `ProjectConfigKeychain` now auto-detects `XCTestConfigurationFilePath`
/// (set by Xcode for every unit/UI test bundle) and routes ALL I/O —
/// including call sites that construct it with no test parameters at all,
/// like `ProjectLifecycleService.cleanUpAfterRemoval`'s
/// `MiniAppGrantStore(context:)` — through `InMemoryKeychainStore` instead
/// of `Security.framework`. This suite proves that detection actually
/// fires, so a future refactor that breaks it fails loudly here instead of
/// stalling some other suite 20 minutes into a background test run.
@Suite struct KeychainTestSeamGuardTests {

    @Test func processIsRecognizedAsAnXCTestHost() {
        // If this ever reads false, every other assertion in this suite
        // (and the auto-detection itself) is testing nothing.
        #expect(ProjectConfigKeychain.isRunningUnderXCTest)
    }

    @Test func defaultKeychainNeverReachesTheRealSecurityFramework() {
        // The exact shape of the bug: a bare `ProjectConfigKeychain()`,
        // with no `testServiceSuffix`, is what `ProjectConfigService()`,
        // `ProjectTemplateUninstaller`'s default parameter, and (via
        // `MiniAppGrantSigner`) `MiniAppGrantStore(context:)` all
        // construct.
        let keychain = ProjectConfigKeychain()
        #expect(keychain.isBackedByInMemoryStoreForTesting)
    }

    @Test func suffixedKeychainAlsoStaysInMemoryUnderXCTest() {
        // The suffix is still useful for namespacing concurrent tests
        // against each other, but it must not be what's protecting the
        // user's real Keychain — the XCTest check does that unconditionally.
        let keychain = ProjectConfigKeychain(testServiceSuffix: "guard-\(UUID().uuidString)")
        #expect(keychain.isBackedByInMemoryStoreForTesting)
    }

    @Test func defaultMiniAppGrantSignerNeverReachesTheRealSecurityFramework() {
        // The exact signer `ProjectLifecycleService.cleanUpAfterRemoval`
        // constructs via `MiniAppGrantStore(context:)` with no
        // `testKeySuffix` — the ProjectTemplateUninstaller -> cleanup ->
        // revokeAll chain named in the task.
        let signer = MiniAppGrantSigner()
        #expect(signer.isBackedByInMemoryStoreForTesting)
    }

    @Test func defaultSignerCanMintAndVerifyWithoutTouchingRealKeychain() throws {
        // Not just "it doesn't crash": prove the seam is functionally a
        // real substitute, not a stub that always fails closed.
        let signer = MiniAppGrantSigner()
        let grant = MiniAppGrant(
            projectId: "proj-\(UUID().uuidString)",
            miniAppId: "app-\(UUID().uuidString)",
            permissions: ["file:read"],
            decidedAt: "2026-09-18T00:00:00Z"
        )
        #expect(signer.isKeyAvailable())
        let tag = try signer.signedTag(for: grant)
        var signed = grant
        signed.signature = tag
        #expect(signer.isAuthentic(signed))
    }

    @Test func inMemoryStoreRoundTripsAndDeletesLikeTheRealKeychainWould() throws {
        let suffix = "guard-roundtrip-\(UUID().uuidString)"
        let keychain = ProjectConfigKeychain(testServiceSuffix: suffix)
        let ref = TemplateKeychainRef.make(
            templateSlug: "guard-slug", fieldKey: "token", projectPath: "/tmp/guard-project"
        )
        #expect(try keychain.get(ref: ref) == nil)
        try keychain.set(ref: ref, secret: Data("secret-value".utf8))
        // A SEPARATE instance with the same suffix must see it — the real
        // Keychain is a shared, process-wide resource, and the fake has to
        // match that so tests that construct a fresh instance per call
        // (as several scarfTests do) keep working.
        let secondHandle = ProjectConfigKeychain(testServiceSuffix: suffix)
        #expect(try secondHandle.get(ref: ref) == Data("secret-value".utf8))
        try secondHandle.delete(ref: ref)
        #expect(try keychain.get(ref: ref) == nil)
    }
}
