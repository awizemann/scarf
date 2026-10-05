#if canImport(Citadel)

import Testing
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import ScarfCore
@testable import ScarfIOS

/// Fixture host keys and the fingerprints `ssh-keygen -lf` printed for them
/// (OpenSSH 10, 2026-10-05). The fingerprint tests assert byte equality.
private enum Fixture {
    static let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPHisR86W34hZJuj3Z/poMhJQusTooFhknIfbY9XBooZ fixture"
    static let fpA = "SHA256:7pQADuqpNeURqWMJJhhUJ/ep8NUPEJGjGFkbbsRDEi8"
    static let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHxU2hiaDasWga5VxKTEAx/503DvY3L2xp/Sx92ldzwm fixture2"
    static let fpB = "SHA256:I1B9XLVNDHjq1490sYa+svUVmDnc8xaLKYwYnOb1lng"
    static let keyECDSA = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBmIc+lh8UNHWNYYeHvSyyk96KpYKiM7i0ItC+pS50s22oO0Ea4gQ7dtGEi38QawWhWfV4PyCqi2Kujjb29ra3E= e"
    static let fpECDSA = "SHA256:ZqTYMFfB+E7nRdnUbO0Xy3rq19Oh02Rb+/O5ulc2aFs"

    static let endpoint = HostKeyEndpoint(host: "hermes.example", port: nil)
}

/// A store over an in-memory backing (no UserDefaults suite, so nothing
/// lands in `~/Library/Preferences`).
private final class ScratchStore {
    let defaults = InMemoryHostKeyPinBacking()
    let store: HostKeyPinStore

    init() { store = HostKeyPinStore(backing: defaults) }
}

@Suite struct HostKeyFingerprintTests {

    @Test func ed25519FingerprintMatchesSSHKeygen() throws {
        #expect(try HostKeyFingerprint.sha256Fingerprint(openSSHKey: Fixture.keyA) == Fixture.fpA)
        #expect(try HostKeyFingerprint.sha256Fingerprint(openSSHKey: Fixture.keyB) == Fixture.fpB)
    }

    @Test func ecdsaFingerprintMatchesSSHKeygen() throws {
        #expect(try HostKeyFingerprint.sha256Fingerprint(openSSHKey: Fixture.keyECDSA) == Fixture.fpECDSA)
    }

    /// The validator fingerprints NIOSSH's re-encoding of the key, not the
    /// text a user pasted — it must come out identical.
    @Test func nioRoundTripKeepsTheFingerprint() throws {
        let parsed = try NIOSSHPublicKey(openSSHPublicKey: Fixture.keyA)
        let line = String(openSSHPublicKey: parsed)
        #expect(try HostKeyFingerprint.sha256Fingerprint(openSSHKey: line) == Fixture.fpA)
    }

    @Test func storedLineDropsTheComment() throws {
        let key = try HostKeyFingerprint(openSSHKey: Fixture.keyA)
        #expect(key.openSSHKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPHisR86W34hZJuj3Z/poMhJQusTooFhknIfbY9XBooZ")
        #expect(key.algorithm == "ssh-ed25519")
    }

    @Test func garbageIsRejected() {
        #expect(throws: HostKeyFormatError.self) { try HostKeyFingerprint(openSSHKey: "ssh-ed25519") }
        #expect(throws: HostKeyFormatError.self) { try HostKeyFingerprint(openSSHKey: "ssh-ed25519 !!!notbase64") }
    }

    @Test func endpointNormalization() {
        #expect(HostKeyEndpoint(host: " Hermes.Example ", port: nil) == HostKeyEndpoint(host: "hermes.example", port: 22))
        #expect(HostKeyEndpoint(host: "h", port: 22).storageKey == "h")
        #expect(HostKeyEndpoint(host: "h", port: 2222).storageKey == "[h]:2222")
        #expect(HostKeyEndpoint(host: "h", port: 2222).displayName == "h:2222")
        let config = IOSServerConfig(host: "Box.local", port: 2200, displayName: "Box")
        #expect(config.hostKeyEndpoint == HostKeyEndpoint(host: "box.local", port: 2200))
    }

    @Test func mismatchMessageNamesBothFingerprints() {
        let error = HostKeyMismatchError(
            endpoint: HostKeyEndpoint(host: "box", port: 2222),
            expectedFingerprint: Fixture.fpA, presentedFingerprint: Fixture.fpB)
        let text = error.localizedDescription
        #expect(text.contains("box:2222"))
        #expect(text.contains(Fixture.fpA))
        #expect(text.contains(Fixture.fpB))
        #expect(text.contains("Server identity changed"))
    }
}

@Suite struct HostKeyPinStoreTests {

    @Test func firstConnectPinsSilently() throws {
        let scratch = ScratchStore(); let store = scratch.store
        let result = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        guard case .pinnedOnFirstUse(let pinned) = result else {
            Issue.record("expected a first-use pin, got \(result)"); return
        }
        #expect(pinned.fingerprint == Fixture.fpA)
        let record = try #require(store.record(for: Fixture.endpoint))
        #expect(record.pinned.fingerprint == Fixture.fpA)
        #expect(record.rejected == nil)
    }

    @Test func sameKeyIsAccepted() throws {
        let scratch = ScratchStore(); let store = scratch.store
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        // A different comment is the same key.
        let again = try store.evaluate(
            presentedOpenSSHKey: Fixture.keyA.replacingOccurrences(of: "fixture", with: "other"),
            for: Fixture.endpoint)
        #expect(again == .matched)
    }

    @Test func differentKeyIsRefusedWithBothFingerprints() throws {
        let scratch = ScratchStore(); let store = scratch.store
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        let result = try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: Fixture.endpoint)
        #expect(result == .mismatch(HostKeyMismatchError(
            endpoint: Fixture.endpoint, expectedFingerprint: Fixture.fpA, presentedFingerprint: Fixture.fpB)))
        // The pin is untouched; the presented key waits for a decision.
        let record = try #require(store.record(for: Fixture.endpoint))
        #expect(record.pinned.fingerprint == Fixture.fpA)
        #expect(record.rejected?.fingerprint == Fixture.fpB)
        // Still refused on the next attempt — a mismatch never self-heals.
        #expect(try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: Fixture.endpoint) != .matched)
    }

    @Test func retrustReplacesThePin() throws {
        let scratch = ScratchStore(); let store = scratch.store
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: Fixture.endpoint)

        // Only the exact key the user was shown can be trusted.
        #expect(store.trustRejectedKey(for: Fixture.endpoint, expectedFingerprint: Fixture.fpECDSA) == false)
        #expect(store.record(for: Fixture.endpoint)?.pinned.fingerprint == Fixture.fpA)

        #expect(store.trustRejectedKey(for: Fixture.endpoint, expectedFingerprint: Fixture.fpB))
        let record = try #require(store.record(for: Fixture.endpoint))
        #expect(record.pinned.fingerprint == Fixture.fpB)
        #expect(record.rejected == nil)
        #expect(try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: Fixture.endpoint) == .matched)
        // ...and the OLD key is now the stranger.
        #expect(try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
            == .mismatch(HostKeyMismatchError(
                endpoint: Fixture.endpoint, expectedFingerprint: Fixture.fpB, presentedFingerprint: Fixture.fpA)))
    }

    @Test func retrustWithoutARejectionDoesNothing() throws {
        let scratch = ScratchStore(); let store = scratch.store
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        #expect(store.trustRejectedKey(for: Fixture.endpoint, expectedFingerprint: Fixture.fpA) == false)
        #expect(store.trustRejectedKey(for: HostKeyEndpoint(host: "nope", port: nil), expectedFingerprint: Fixture.fpA) == false)
    }

    @Test func returningToThePinnedKeyClearsTheRejection() throws {
        let scratch = ScratchStore(); let store = scratch.store
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: Fixture.endpoint)
        #expect(try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint) == .matched)
        #expect(store.record(for: Fixture.endpoint)?.rejected == nil)
    }

    @Test func forgettingAServerClearsItsPin() throws {
        let scratch = ScratchStore(); let store = scratch.store
        let other = HostKeyEndpoint(host: "other.example", port: nil)
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: other)

        // RootModel.forget prunes to the endpoints of the servers that remain.
        store.prune(keeping: [other])
        #expect(store.record(for: Fixture.endpoint) == nil)
        #expect(store.record(for: other) != nil)
        // The forgotten endpoint pins afresh — any key, no prompt.
        guard case .pinnedOnFirstUse(let repinned) = try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: Fixture.endpoint) else {
            Issue.record("a forgotten endpoint must pin afresh"); return
        }
        #expect(repinned.fingerprint == Fixture.fpB)

        store.remove(other)
        #expect(store.record(for: other) == nil)
        store.removeAll()
        #expect(store.allRecords().isEmpty)
    }

    @Test func twoEntriesForOneHostShareAPin() throws {
        let scratch = ScratchStore(); let store = scratch.store
        let alice = IOSServerConfig(host: "box", user: "alice", displayName: "A")
        let bob = IOSServerConfig(host: "BOX", user: "bob", port: 22, displayName: "B")
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: alice.hostKeyEndpoint)
        #expect(try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: bob.hostKeyEndpoint) == .matched)
        // Forgetting alice keeps the pin while bob still uses the host.
        store.prune(keeping: [bob.hostKeyEndpoint])
        #expect(store.record(for: alice.hostKeyEndpoint) != nil)
    }

    @Test func hostOrPortChangeResetsThePin() throws {
        let scratch = ScratchStore(); let store = scratch.store
        let before = IOSServerConfig(host: "box", port: 22, displayName: "Box")
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: before.hostKeyEndpoint)

        // Re-onboarded at a new port: a different endpoint, so the first
        // connect there pins whatever it sees instead of refusing.
        var movedPort = before
        movedPort.port = 2222
        if case .pinnedOnFirstUse = try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: movedPort.hostKeyEndpoint) {} else {
            Issue.record("a new port must start a fresh pin")
        }
        var movedHost = before
        movedHost.host = "newbox"
        if case .pinnedOnFirstUse = try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: movedHost.hostKeyEndpoint) {} else {
            Issue.record("a new host must start a fresh pin")
        }
        // The old endpoint's pin goes when the list no longer uses it.
        store.prune(keeping: [movedHost.hostKeyEndpoint])
        #expect(store.record(for: before.hostKeyEndpoint) == nil)
        #expect(store.record(for: movedPort.hostKeyEndpoint) == nil)
        #expect(store.record(for: movedHost.hostKeyEndpoint)?.pinned.fingerprint == Fixture.fpB)
    }

    @Test func persistsAcrossStoreInstances() throws {
        let scratch = ScratchStore()
        let first = scratch.store
        _ = try first.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        _ = try first.evaluate(presentedOpenSSHKey: Fixture.keyB, for: Fixture.endpoint)
        let written = try #require(first.record(for: Fixture.endpoint))

        // A fresh instance (an app relaunch) reads the same record back.
        let second = HostKeyPinStore(backing: scratch.defaults)
        #expect(second.record(for: Fixture.endpoint) == written)

        // The stored shape: one JSON object keyed by the known_hosts spelling.
        let data = try #require(scratch.defaults.data(forKey: HostKeyPinStore.defaultDefaultsKey))
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw.keys.sorted() == ["hermes.example"])
    }

    /// The production backing: a real UserDefaults round trip. Uses a unique
    /// key in the test runner's own standard domain (removed afterwards)
    /// rather than a suite, which would leave a plist behind.
    @Test func userDefaultsBackingRoundTrips() throws {
        let key = "scarf-hostkey-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let first = HostKeyPinStore(defaults: .standard, key: key)
        _ = try first.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        let second = HostKeyPinStore(defaults: .standard, key: key)
        #expect(second.record(for: Fixture.endpoint)?.pinned.fingerprint == Fixture.fpA)
        second.removeAll()
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    /// The fix for the B-then-C race: the user is shown key B and confirms
    /// it, but by then the server has presented C. Trusting the captured B
    /// must not pin C (or B): the pin stays on A and C waits for review.
    @Test func retrustOfASupersededKeyIsRefused() throws {
        let scratch = ScratchStore(); let store = scratch.store
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint)
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: Fixture.endpoint)
        let shownToUser = try #require(store.record(for: Fixture.endpoint)?.rejected?.fingerprint)
        #expect(shownToUser == Fixture.fpB)

        // While the dialog is open, a connect sees a third key.
        let third = try store.evaluate(presentedOpenSSHKey: Fixture.keyECDSA, for: Fixture.endpoint)
        #expect(third == .mismatch(HostKeyMismatchError(
            endpoint: Fixture.endpoint, expectedFingerprint: Fixture.fpA, presentedFingerprint: Fixture.fpECDSA)))

        #expect(store.trustRejectedKey(for: Fixture.endpoint, expectedFingerprint: shownToUser) == false)
        let record = try #require(store.record(for: Fixture.endpoint))
        #expect(record.pinned.fingerprint == Fixture.fpA)
        #expect(record.rejected?.fingerprint == Fixture.fpECDSA)
        // Neither B nor C connects.
        #expect(try store.evaluate(presentedOpenSSHKey: Fixture.keyB, for: Fixture.endpoint) != .matched)
        #expect(try store.evaluate(presentedOpenSSHKey: Fixture.keyECDSA, for: Fixture.endpoint) != .matched)
        // Only after the user reviews and confirms C itself does C pin.
        #expect(store.trustRejectedKey(for: Fixture.endpoint, expectedFingerprint: Fixture.fpECDSA))
        #expect(try store.evaluate(presentedOpenSSHKey: Fixture.keyECDSA, for: Fixture.endpoint) == .matched)
    }

    /// One damaged record must not take the others with it, and the
    /// original bytes are kept under a backup key before the rewrite.
    @Test func damagedRecordIsDroppedAloneAndBackedUp() throws {
        let scratch = ScratchStore(); let store = scratch.store; let defaults = scratch.defaults
        let good = HostKeyEndpoint(host: "good.example", port: nil)
        _ = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: good)
        let stored = try #require(defaults.data(forKey: HostKeyPinStore.defaultDefaultsKey))
        var raw = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        raw["bad.example"] = ["endpoint": "nonsense", "pinned": 42]
        let damaged = try JSONSerialization.data(withJSONObject: raw)
        defaults.set(damaged, forKey: HostKeyPinStore.defaultDefaultsKey)

        #expect(store.record(for: good)?.pinned.fingerprint == Fixture.fpA)
        #expect(store.record(for: HostKeyEndpoint(host: "bad.example", port: nil)) == nil)

        let backups = defaults.allKeys.filter { $0.hasPrefix(store.corruptBackupKeyPrefix) }
        #expect(backups.count == 1)
        let backupKey = try #require(backups.first)
        #expect(defaults.data(forKey: backupKey) == damaged)
        // The live key was rewritten without the bad entry, so later reads
        // don't back it up again.
        _ = store.allRecords()
        #expect(defaults.allKeys.filter { $0.hasPrefix(store.corruptBackupKeyPrefix) }.count == 1)
    }

    @Test func unreadableBlobStartsFreshButIsKept() throws {
        let scratch = ScratchStore(); let store = scratch.store; let defaults = scratch.defaults
        let junk = Data("not json".utf8)
        defaults.set(junk, forKey: HostKeyPinStore.defaultDefaultsKey)
        #expect(store.record(for: Fixture.endpoint) == nil)
        let backups = defaults.allKeys.filter { $0.hasPrefix(store.corruptBackupKeyPrefix) }
        #expect(backups.count == 1)
        let backupKey = try #require(backups.first)
        #expect(defaults.data(forKey: backupKey) == junk)
        if case .pinnedOnFirstUse = try store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: Fixture.endpoint) {} else {
            Issue.record("expected a fresh pin")
        }
    }

    /// Two connects racing the very first key exchange: exactly one key wins
    /// the pin and every other answer is consistent with it.
    @Test func concurrentFirstConnectsPinExactlyOnce() async throws {
        let scratch = ScratchStore(); let store = scratch.store
        let keys = [Fixture.keyA, Fixture.keyB]
        let results = await withTaskGroup(of: HostKeyEvaluation?.self) { group in
            for i in 0..<200 {
                let key = keys[i % 2]
                group.addTask { try? store.evaluate(presentedOpenSSHKey: key, for: Fixture.endpoint) }
            }
            var all: [HostKeyEvaluation] = []
            for await r in group { if let r { all.append(r) } }
            return all
        }
        #expect(results.count == 200)
        let firstUse = results.filter { if case .pinnedOnFirstUse = $0 { return true }; return false }
        #expect(firstUse.count == 1)
        let winner = try #require(store.record(for: Fixture.endpoint)).pinned.fingerprint
        for r in results {
            if case .mismatch(let e) = r { #expect(e.expectedFingerprint == winner) }
        }
        #expect(results.filter { $0 == .matched }.count == 99)
    }

    @Test func concurrentEndpointsDoNotLoseWrites() async throws {
        let scratch = ScratchStore(); let store = scratch.store
        await withTaskGroup(of: Void.self) { group in
            for port in 1000..<1100 {
                group.addTask {
                    _ = try? store.evaluate(presentedOpenSSHKey: Fixture.keyA, for: HostKeyEndpoint(host: "h", port: port))
                }
            }
        }
        #expect(store.allRecords().count == 100)
    }
}

/// The NIOSSH delegate itself, driven with a real event-loop promise.
@Suite struct PinnedHostKeyValidatorTests {

    private func validate(_ validator: PinnedHostKeyValidator, _ line: String) async -> Result<Void, Error> {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let promise = loop.makePromise(of: Void.self)
        let key = try! NIOSSHPublicKey(openSSHPublicKey: line)
        loop.execute { validator.validateHostKey(hostKey: key, validationCompletePromise: promise) }
        do {
            try await promise.futureResult.get()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @Test func pinsThenAcceptsThenRefuses() async throws {
        let scratch = ScratchStore(); let store = scratch.store
        let recorder = HostKeyRejectionRecorder()
        let validator = PinnedHostKeyValidator(endpoint: Fixture.endpoint, store: store, recorder: recorder)

        guard case .success = await validate(validator, Fixture.keyA) else {
            Issue.record("first connect must succeed"); return
        }
        #expect(store.record(for: Fixture.endpoint)?.pinned.fingerprint == Fixture.fpA)
        guard case .success = await validate(validator, Fixture.keyA) else {
            Issue.record("pinned key must succeed"); return
        }

        let refused = await validate(validator, Fixture.keyB)
        guard case .failure(let error) = refused else {
            Issue.record("a changed key must be refused"); return
        }
        let mismatch = try #require(error as? HostKeyMismatchError)
        #expect(mismatch.expectedFingerprint == Fixture.fpA)
        #expect(mismatch.presentedFingerprint == Fixture.fpB)
        #expect(mismatch.endpoint == Fixture.endpoint)
        #expect(recorder.mismatch == mismatch)
    }

    @Test func findUnwrapsAnUnderlyingMismatch() {
        let mismatch = HostKeyMismatchError(
            endpoint: Fixture.endpoint, expectedFingerprint: Fixture.fpA, presentedFingerprint: Fixture.fpB)
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: mismatch])
        #expect(HostKeyMismatchError.find(in: mismatch) == mismatch)
        #expect(HostKeyMismatchError.find(in: wrapped) == mismatch)
        #expect(HostKeyMismatchError.find(in: CancellationError()) == nil)
    }

    @Test func connectionTestErrorNamesTheFingerprints() {
        let mismatch = HostKeyMismatchError(
            endpoint: Fixture.endpoint, expectedFingerprint: Fixture.fpA, presentedFingerprint: Fixture.fpB)
        let mapped = CitadelSSHService.classifyConnectError(mismatch, host: "ignored")
        guard case .hostKeyMismatch(let host, let detail) = mapped else {
            Issue.record("expected .hostKeyMismatch, got \(mapped)"); return
        }
        #expect(host == "hermes.example")
        #expect(detail.contains("different host key"))
    }
}

#endif
