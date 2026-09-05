import Testing
import Foundation
import ScarfCore
@testable import scarf

/// GW-E2b — `servers.json` (`ServerRegistry`).
///
/// Before the conversion, `load()` answered ANY read failure with
/// `entries = []` and `save()` published that empty list over the file with
/// a bare `Data.write(.atomic)` — the `projects.json` destroy shape, on the
/// one file holding every server the user configured, and entirely outside
/// the transport layer (so the E1 scanner could never see it).
///
/// Real temp directories through the real `LocalTransport`, W1 style: the
/// bug lives in what the writer BELIEVES about the file, so an always-honest
/// fake transport proves nothing. Mode-0000 cases self-skip under root.
@MainActor
@Suite struct ServerRegistryGuardedWriteTests {

    private static var runningAsRoot: Bool { getuid() == 0 }

    private static func makeScratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-e2b-servers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func cleanUp(_ base: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: base.path
        )
        try? FileManager.default.removeItem(at: base)
    }

    private static func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private static func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// A real, valid `servers.json` written by an earlier Scarf run.
    private static func seedRegistry(at url: URL, name: String = "prod") throws -> Data {
        let registry = ServerRegistry(storeURL: url)
        registry.addServer(displayName: name, config: SSHConfig(host: "\(name).example"))
        let data = try #require(bytes(url))
        return data
    }

    // MARK: - Absent

    @Test func absentFileStartsFreshAndSavesNormally() throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let url = base.appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("servers.json")

        let registry = ServerRegistry(storeURL: url)
        #expect(registry.entries.isEmpty)
        #expect(registry.storeDamage == nil)

        registry.addServer(displayName: "prod", config: SSHConfig(host: "prod.example"))
        #expect(registry.storeDamage == nil)
        // Parent directory is created by the guarded write, as the old
        // hand-rolled `createDirectory` did.
        let data = try #require(Self.bytes(url))
        #expect(!data.isEmpty)

        // And it round-trips.
        let reloaded = ServerRegistry(storeURL: url)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.first?.displayName == "prod")
        #expect(reloaded.storeDamage == nil)
    }

    // MARK: - Unreadable

    /// The bug this closes: one unreadable load used to zero `entries`, and
    /// the very next add published that near-empty list over the user's
    /// whole server list.
    @Test func unreadableLoadDoesNotZeroTheFileAndBlocksTheNextSave() throws {
        try #require(!Self.runningAsRoot)
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let url = base.appendingPathComponent("servers.json")
        let original = try Self.seedRegistry(at: url)

        try Self.chmod(url, 0o000)
        let registry = ServerRegistry(storeURL: url)
        let damage = try #require(registry.storeDamage)
        #expect(damage.path == url.path)
        #expect(damage.refusedSave == false)

        registry.addServer(displayName: "staging", config: SSHConfig(host: "staging.example"))
        // The edit is live in memory…
        #expect(registry.entries.contains { $0.displayName == "staging" })
        // …and the refusal is surfaced, not swallowed.
        #expect(registry.storeDamage?.refusedSave == true)

        try Self.chmod(url, 0o600)
        #expect(Self.bytes(url) == original, "servers.json must be byte-identical")
    }

    /// Scarf never writes a zero-length `servers.json`, so zero bytes is
    /// somebody else's truncation — damage, not an empty registry.
    @Test func zeroByteFileIsDamageAndIsNeverOverwritten() throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let url = base.appendingPathComponent("servers.json")
        try Data().write(to: url)

        let registry = ServerRegistry(storeURL: url)
        #expect(registry.entries.isEmpty)
        #expect(registry.storeDamage != nil)

        registry.addServer(displayName: "prod", config: SSHConfig(host: "prod.example"))
        #expect(registry.storeDamage?.refusedSave == true)
        #expect(Self.bytes(url)?.isEmpty == true, "the truncated file is left exactly as found")
    }

    /// `servers.json` REFUSES; it does not quarantine-and-rebuild. The rows
    /// are the user's connections and exist nowhere else, so undecodable
    /// bytes are copied aside for the human and writes stay refused.
    @Test func undecodableBytesAreQuarantinedAndWritesStayRefused() throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let url = base.appendingPathComponent("servers.json")
        let garbage = Data("{ this is not a server list".utf8)
        try garbage.write(to: url)

        let registry = ServerRegistry(storeURL: url)
        let damage = try #require(registry.storeDamage)
        let copy = try #require(damage.quarantinePath)
        #expect(Self.bytes(URL(fileURLWithPath: copy)) == garbage)

        registry.addServer(displayName: "prod", config: SSHConfig(host: "prod.example"))
        #expect(registry.storeDamage?.refusedSave == true)
        #expect(Self.bytes(url) == garbage, "the live file is left for a human to fix")
    }

    // MARK: - Backup

    @Test func aSaveKeepsAOneDeepBackupOfTheBytesItReplaces() throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let url = base.appendingPathComponent("servers.json")
        let original = try Self.seedRegistry(at: url)

        let registry = ServerRegistry(storeURL: url)
        registry.addServer(displayName: "staging", config: SSHConfig(host: "staging.example"))

        let backup = try #require(Self.bytes(url.appendingPathExtension("bak")))
        #expect(backup == original)
        #expect(Self.bytes(url) != original)
        #expect(registry.storeDamage == nil)
    }

    // MARK: - Healthy path

    @Test func healthyRoundTripPreservesEntriesAndTheDefaultFlag() throws {
        let base = try Self.makeScratch()
        defer { Self.cleanUp(base) }
        let url = base.appendingPathComponent("servers.json")

        let registry = ServerRegistry(storeURL: url)
        let first = registry.addServer(displayName: "prod", config: SSHConfig(host: "prod.example", user: "alan", port: 2222))
        registry.addServer(displayName: "staging", config: SSHConfig(host: "staging.example"))
        registry.setDefaultServer(first.id)

        let reloaded = ServerRegistry(storeURL: url)
        #expect(reloaded.entries.map(\.displayName) == ["prod", "staging"])
        #expect(reloaded.defaultServerID == first.id)
        #expect(reloaded.storeDamage == nil)
        if case .ssh(let config) = try #require(reloaded.entries.first).kind {
            #expect(config.user == "alan")
            #expect(config.port == 2222)
        } else {
            Issue.record("expected an SSH entry")
        }
    }
}
