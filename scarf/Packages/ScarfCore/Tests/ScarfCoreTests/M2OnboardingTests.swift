import Testing
import Foundation
@testable import ScarfCore

/// Exercises the iOS onboarding state machine + supporting types
/// that moved to ScarfCore in M2. Uses only ScarfCore types — no
/// Citadel, no Keychain, no SwiftUI — so the whole suite runs on
/// Linux CI. Apple-target CI runs the same tests plus
/// `ScarfIOSSmokeTests` for the platform-specific bits.
@Suite struct M2OnboardingTests {

    // MARK: - SSHKeyBundle + InMemorySSHKeyStore

    @Test func keyBundleMemberwise() {
        let bundle = SSHKeyBundle(
            privateKeyPEM: "-----BEGIN X-----\nabc\n-----END X-----",
            publicKeyOpenSSH: "ssh-ed25519 AAAABBBB user@host",
            comment: "user@host",
            createdAt: "2026-04-22T12:00:00Z"
        )
        #expect(bundle.comment == "user@host")
        #expect(bundle.displayFingerprint.hasPrefix("ssh-ed25519 "))
        #expect(bundle.displayFingerprint.contains("…"))
    }

    @Test func inMemoryKeyStoreBasics() async throws {
        let store = InMemorySSHKeyStore()
        let initial = try await store.load()
        #expect(initial == nil)

        let bundle = SSHKeyBundle(
            privateKeyPEM: "p", publicKeyOpenSSH: "ssh-ed25519 abc name",
            comment: "name", createdAt: "2026-04-22T12:00:00Z"
        )
        try await store.save(bundle)
        let loaded = try await store.load()
        #expect(loaded == bundle)

        try await store.delete()
        let afterDelete = try await store.load()
        #expect(afterDelete == nil)
    }

    // MARK: - IOSServerConfig + InMemory store

    @Test func iosServerConfigToServerContext() {
        let cfg = IOSServerConfig(
            host: "box.local", user: "alan", port: 2222,
            hermesBinaryHint: "/opt/hermes/bin/hermes",
            remoteHome: "/opt/hermes/.hermes",
            displayName: "Home Server"
        )
        let id = UUID()
        let ctx = cfg.toServerContext(id: id)
        #expect(ctx.id == id)
        #expect(ctx.displayName == "Home Server")
        #expect(ctx.isRemote == true)
        if case .ssh(let ssh) = ctx.kind {
            #expect(ssh.host == "box.local")
            #expect(ssh.user == "alan")
            #expect(ssh.port == 2222)
            #expect(ssh.remoteHome == "/opt/hermes/.hermes")
            #expect(ssh.hermesBinaryHint == "/opt/hermes/bin/hermes")
        } else {
            Issue.record("expected .ssh kind")
        }
        #expect(ctx.paths.home == "/opt/hermes/.hermes")
        #expect(ctx.paths.stateDB == "/opt/hermes/.hermes/state.db")
    }

    @Test func iosServerConfigDefaultsUseRemoteHome() {
        let cfg = IOSServerConfig(host: "h", displayName: "h")
        let ctx = cfg.toServerContext(id: UUID())
        // No remoteHome set → default "~/.hermes"
        #expect(ctx.paths.home == "~/.hermes")
    }

    @Test func inMemoryConfigStoreBasics() async throws {
        let store = InMemoryIOSServerConfigStore()
        let initial = try await store.load()
        #expect(initial == nil)

        let cfg = IOSServerConfig(host: "h", displayName: "h")
        try await store.save(cfg)
        #expect(try await store.load() == cfg)

        try await store.delete()
        #expect(try await store.load() == nil)
    }

    // MARK: - OnboardingLogic validators

    @Test func validateServerDetailsAcceptsHappyPath() {
        let v = OnboardingLogic.validateServerDetails(host: "box.local", portText: "")
        #expect(v.isHostValid == true)
        #expect(v.isPortValid == true)
        #expect(v.canAdvance == true)
    }

    @Test func validateServerDetailsRejectsEmptyHost() {
        let v = OnboardingLogic.validateServerDetails(host: "  ", portText: "")
        #expect(v.isHostValid == false)
        #expect(v.canAdvance == false)
    }

    @Test func validateServerDetailsRejectsHostWithSpaces() {
        let v = OnboardingLogic.validateServerDetails(host: "bad host name", portText: "")
        #expect(v.isHostValid == false)
    }

    @Test func validateServerDetailsPortRange() {
        #expect(OnboardingLogic.validateServerDetails(host: "h", portText: "22").canAdvance)
        #expect(OnboardingLogic.validateServerDetails(host: "h", portText: "65535").canAdvance)
        #expect(!OnboardingLogic.validateServerDetails(host: "h", portText: "0").canAdvance)
        #expect(!OnboardingLogic.validateServerDetails(host: "h", portText: "65536").canAdvance)
        #expect(!OnboardingLogic.validateServerDetails(host: "h", portText: "not a number").canAdvance)
    }

    @Test func authorizedKeysLineTrimsAndNewlines() {
        let b = SSHKeyBundle(
            privateKeyPEM: "",
            publicKeyOpenSSH: "  ssh-ed25519 AAAA foo  \n",
            comment: "foo", createdAt: ""
        )
        let line = OnboardingLogic.authorizedKeysLine(for: b)
        #expect(line == "ssh-ed25519 AAAA foo\n")
    }

    @Test func privateKeyShapeCheckHappyPath() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt
        ZWQyNTUxOQAAACCN4e59+wtJp6GgmCNZMnRsPk6M4tGRYl+Uzs3wX8Ug4AAAAKCG13O1
        -----END OPENSSH PRIVATE KEY-----
        """
        #expect(OnboardingLogic.isLikelyValidOpenSSHPrivateKey(pem) == true)
    }

    @Test func privateKeyShapeRejectsGarbage() {
        #expect(OnboardingLogic.isLikelyValidOpenSSHPrivateKey("") == false)
        #expect(OnboardingLogic.isLikelyValidOpenSSHPrivateKey("just text") == false)
        // Legacy RSA PEM shouldn't pass — users need to re-export.
        #expect(OnboardingLogic.isLikelyValidOpenSSHPrivateKey("""
        -----BEGIN RSA PRIVATE KEY-----
        abcdef
        -----END RSA PRIVATE KEY-----
        """) == false)
    }

    @Test func parsePublicKeyLineHappyPath() {
        #expect(OnboardingLogic.parseOpenSSHPublicKeyLine("ssh-ed25519 AAAABBBBCCC alan@macbook")
                == "ssh-ed25519 AAAABBBBCCC alan@macbook")
        #expect(OnboardingLogic.parseOpenSSHPublicKeyLine("ssh-rsa AAAABBBBCCC")
                == "ssh-rsa AAAABBBBCCC")
    }

    @Test func parsePublicKeyLineRejectsNonsense() {
        #expect(OnboardingLogic.parseOpenSSHPublicKeyLine("") == nil)
        #expect(OnboardingLogic.parseOpenSSHPublicKeyLine("not-an-algo abc") == nil)
        #expect(OnboardingLogic.parseOpenSSHPublicKeyLine("ssh-ed25519") == nil)
    }

    // MARK: - SSHConnectionTester mock basics

    @Test func mockTesterRecordsCalls() async throws {
        let mock = MockSSHConnectionTester()
        try await mock.testConnection(
            config: IOSServerConfig(host: "h", displayName: "h"),
            key: SSHKeyBundle(privateKeyPEM: "p", publicKeyOpenSSH: "ssh-ed25519 x n", comment: "n", createdAt: "")
        )
        #expect(await mock.callCount == 1)
    }

    @Test func mockTesterPropagatesConfiguredError() async {
        let mock = MockSSHConnectionTester(
            behavior: .failure(.authenticationFailed(host: "h", detail: "no key"))
        )
        do {
            try await mock.testConnection(
                config: IOSServerConfig(host: "h", displayName: "h"),
                key: SSHKeyBundle(privateKeyPEM: "p", publicKeyOpenSSH: "ssh-ed25519 x n", comment: "n", createdAt: "")
            )
            Issue.record("expected throw")
        } catch let error as SSHConnectionTestError {
            if case .authenticationFailed(let host, _) = error {
                #expect(host == "h")
            } else {
                Issue.record("wrong case: \(error)")
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: - OnboardingViewModel end-to-end

    /// Build a VM with all dependencies injected + a canned key bundle
    /// from a closure generator.
    @MainActor
    private func makeVM(
        testerBehavior: MockSSHConnectionTester.Behavior = .success,
        existingKey: SSHKeyBundle? = nil
    ) async -> (OnboardingViewModel, InMemorySSHKeyStore, InMemoryIOSServerConfigStore, MockSSHConnectionTester) {
        let ks = InMemorySSHKeyStore(initial: existingKey)
        let cs = InMemoryIOSServerConfigStore()
        let tester = MockSSHConnectionTester(behavior: testerBehavior)
        let fixedBundle = SSHKeyBundle(
            privateKeyPEM: """
            -----BEGIN OPENSSH PRIVATE KEY-----
            b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt
            ZWQyNTUxOQAAACCN4e59+wtJp6GgmCNZMnRsPk6M4tGRYl+Uzs3wX8Ug4AAAAKCG13O1
            -----END OPENSSH PRIVATE KEY-----
            """,
            publicKeyOpenSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test-key",
            comment: "test-key",
            createdAt: "2026-04-22T12:00:00Z"
        )
        let vm = OnboardingViewModel(
            keyStore: ks,
            configStore: cs,
            tester: tester,
            keyGenerator: { fixedBundle }
        )
        return (vm, ks, cs, tester)
    }

    @Test @MainActor func vmStartsAtServerDetails() async {
        let (vm, _, _, _) = await makeVM()
        #expect(vm.step == .serverDetails)
    }

    @Test @MainActor func vmBlocksAdvanceOnInvalidHost() async {
        let (vm, _, _, _) = await makeVM()
        vm.host = ""
        vm.advanceFromServerDetails()
        #expect(vm.step == .serverDetails)
    }

    @Test @MainActor func vmAdvancesOnValidHost() async {
        let (vm, _, _, _) = await makeVM()
        vm.host = "box.local"
        vm.advanceFromServerDetails()
        #expect(vm.step == .keySource)
    }

    @Test @MainActor func vmGenerateHappyPath() async {
        let (vm, ks, cs, _) = await makeVM()
        vm.host = "box.local"
        vm.user = "alan"
        vm.displayName = "Home"
        vm.advanceFromServerDetails()
        vm.pickKeyChoice(.generate)
        #expect(vm.step == .generate)
        await vm.generateKey()
        #expect(vm.step == .showPublicKey)
        #expect(vm.keyBundle?.comment == "test-key")
        // Keychain NOT yet saved — save happens on confirmPublicKeyAdded.
        #expect(try! await ks.load() == nil)
        #expect(try! await cs.load() == nil)
    }

    @Test @MainActor func vmConfirmPublicKeySavesAndStartsTest() async {
        let (vm, ks, cs, tester) = await makeVM()
        vm.host = "box.local"
        vm.user = "alan"
        vm.displayName = "Home"
        vm.advanceFromServerDetails()
        vm.pickKeyChoice(.generate)
        await vm.generateKey()
        await vm.confirmPublicKeyAdded()
        #expect(vm.step == .connected)
        let stored = try! await ks.load()
        #expect(stored?.comment == "test-key")
        let savedCfg = try! await cs.load()
        #expect(savedCfg?.host == "box.local")
        #expect(savedCfg?.user == "alan")
        #expect(savedCfg?.displayName == "Home")
        #expect(await tester.callCount == 1)
    }

    @Test @MainActor func vmConnectionFailureRoutesToTestFailed() async {
        let (vm, _, cs, _) = await makeVM(
            testerBehavior: .failure(.hostUnreachable(host: "box.local", underlying: "no route"))
        )
        vm.host = "box.local"
        vm.advanceFromServerDetails()
        vm.pickKeyChoice(.generate)
        await vm.generateKey()
        await vm.confirmPublicKeyAdded()
        if case .testFailed(let reason) = vm.step {
            #expect(reason.contains("box.local"))
        } else {
            Issue.record("expected .testFailed, got \(vm.step)")
        }
        // Config NOT saved on failed test.
        #expect(try! await cs.load() == nil)
    }

    @Test @MainActor func vmRetryAfterFailureWorks() async {
        let (vm, _, cs, tester) = await makeVM(
            testerBehavior: .failure(.authenticationFailed(host: "h", detail: "x"))
        )
        vm.host = "box.local"
        vm.advanceFromServerDetails()
        vm.pickKeyChoice(.generate)
        await vm.generateKey()
        await vm.confirmPublicKeyAdded()
        guard case .testFailed = vm.step else {
            Issue.record("expected .testFailed")
            return
        }

        // User added the key on the remote; switch the mock to success
        // and retry.
        await tester.setBehavior(.success)
        await vm.runConnectionTest()
        #expect(vm.step == .connected)
        #expect(try! await cs.load() != nil)
    }

    @Test @MainActor func vmImportKeyHappyPath() async {
        let (vm, _, _, _) = await makeVM()
        vm.host = "box.local"
        vm.advanceFromServerDetails()
        vm.pickKeyChoice(.importExisting)
        vm.importPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt
        -----END OPENSSH PRIVATE KEY-----
        """
        let ok = vm.importKey(
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA name",
            deviceComment: "imported",
            iso8601Date: "2026-04-22T12:00:00Z"
        )
        #expect(ok == true)
        #expect(vm.step == .showPublicKey)
        #expect(vm.keyBundle?.comment == "imported")
    }

    @Test @MainActor func vmImportRejectsBadPEM() async {
        let (vm, _, _, _) = await makeVM()
        vm.host = "h"
        vm.advanceFromServerDetails()
        vm.pickKeyChoice(.importExisting)
        vm.importPEM = "not a key"
        let ok = vm.importKey(
            publicKey: "ssh-ed25519 abc name",
            deviceComment: "x",
            iso8601Date: ""
        )
        #expect(ok == false)
        if case .testFailed = vm.step {} else {
            Issue.record("expected .testFailed after bad import")
        }
    }

    @Test @MainActor func vmResetClearsEverything() async {
        let (vm, ks, cs, _) = await makeVM()
        vm.host = "box.local"
        vm.user = "alan"
        vm.advanceFromServerDetails()
        vm.pickKeyChoice(.generate)
        await vm.generateKey()
        await vm.confirmPublicKeyAdded()

        await vm.reset()
        #expect(vm.step == .serverDetails)
        #expect(vm.host == "")
        #expect(vm.user == "")
        #expect(vm.keyBundle == nil)
        #expect(try! await ks.load() == nil)
        #expect(try! await cs.load() == nil)
    }
}
