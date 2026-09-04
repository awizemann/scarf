import Testing
import Foundation
@testable import ScarfCore

/// P2 (t-7d05e066), the transport half.
///
/// Every test here is about an answer that was WRONG BUT STABLE — the
/// worst shape a change-detector can have, because the surface above it
/// short-circuits on it forever and looks healthy while doing so.
@Suite struct StatAllFramingTests {

    private let marker = SSHTransport.statAllMarker

    private func line(_ index: Int, _ stat: String) -> String {
        "\(marker)\(index) \(stat)"
    }

    @Test("a well-formed reply maps every path to its own stat")
    func alignedReplyParses() throws {
        let paths = ["/a", "/b", "/c"]
        let stdout = [
            line(1, "10 1700000000 regular file"),
            line(2, "- - -"),
            line(3, "4096 1700000001 directory")
        ].joined(separator: "\n") + "\n"
        let parsed = try #require(SSHTransport.parseStatAllReply(stdout, paths: paths))
        #expect(parsed["/a"]?.size == 10)
        // The placeholder is ABSENT, not a zero-byte file.
        #expect(parsed["/b"] == nil)
        #expect(parsed["/c"]?.isDirectory == true)
    }

    /// The H1 bug, exactly: a remote `.profile` that echoes one line used
    /// to shift every signature by one position, and the resulting map was
    /// self-consistent from tick to tick — so the cockpit compared two
    /// equally-wrong signatures and never reloaded again.
    @Test("a stray stdout line does not shift the mapping")
    func strayLineDoesNotMisattribute() throws {
        let paths = ["/a", "/b"]
        let stdout = [
            "Welcome to Ubuntu 24.04!",
            line(1, "10 1700000000 regular file"),
            "You have mail.",
            line(2, "20 1700000005 regular file")
        ].joined(separator: "\n") + "\n"
        let parsed = try #require(SSHTransport.parseStatAllReply(stdout, paths: paths))
        #expect(parsed["/a"]?.size == 10)
        #expect(parsed["/b"]?.size == 20)
    }

    @Test("a short reply is refused outright, not read as absent files")
    func shortReplyIsUntrusted() {
        let paths = ["/a", "/b", "/c"]
        let stdout = line(1, "10 1700000000 regular file") + "\n"
        // nil, NOT a one-entry map: /b and /c are unknown, not missing.
        #expect(SSHTransport.parseStatAllReply(stdout, paths: paths) == nil)
    }

    @Test("an empty reply is refused")
    func emptyReplyIsUntrusted() {
        #expect(SSHTransport.parseStatAllReply("", paths: ["/a"]) == nil)
    }

    @Test("a duplicated or out-of-range index refuses the whole reply")
    func brokenFramingIsUntrusted() {
        let paths = ["/a", "/b"]
        let duplicated = [
            line(1, "10 1700000000 regular file"),
            line(1, "20 1700000000 regular file")
        ].joined(separator: "\n")
        #expect(SSHTransport.parseStatAllReply(duplicated, paths: paths) == nil)
        let outOfRange = line(9, "10 1700000000 regular file")
        #expect(SSHTransport.parseStatAllReply(outOfRange, paths: paths) == nil)
    }

    /// DI M6. A path containing a newline cannot be framed back out of a
    /// line-oriented reply at all, so it is refused before the round-trip
    /// rather than misattributed into somebody else's signature.
    @Test("a path containing a newline is refused without a round-trip")
    func newlinePathsAreRefused() {
        let transport = SSHTransport(
            contextID: ServerID(),
            config: SSHConfig(host: "example.invalid", user: "nobody"),
            displayName: "test"
        )
        // No SSH is attempted: the guard precedes the command.
        #expect(transport.statAll(["/ok", "/evil\npath"]) == nil)
        #expect(transport.statAll(["/evil\rpath"]) == nil)
    }

    @Test("the local default never refuses — it has nothing to line up")
    func localDefaultIsAlwaysTrusted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-statall-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stats = try #require(LocalTransport().statAll([dir.path + "/nope"]))
        #expect(stats.isEmpty)
    }
}

/// DI H6/H7: the poller's blob fallback used to REPLACE the per-path
/// baseline map, and an empty reply skipped the sleep.
@Suite struct WatchBaselineMergeTests {

    @Test("a blob fallback keeps the per-path baselines it says nothing about")
    func blobFallbackDoesNotWipeBaselines() {
        let store = WatchBaselineStore()
        _ = store.apply(["/a": "100:10", "/b": "100:20"])
        // One misaligned reply. `apply` here would forget /a and /b.
        _ = store.merge(["\u{0}blob": "garbage"])
        #expect(store.signature(for: "/a") == "100:10")
        #expect(store.signature(for: "/b") == "100:20")
    }

    /// The consequence of the wipe, and the reason this is a data bug
    /// rather than a tidiness one: after re-alignment the change that
    /// landed during the misaligned window must still be reported.
    @Test("a change during the blob window is reported when alignment returns")
    func changeAcrossTheBlobWindowIsNotSwallowed() {
        let store = WatchBaselineStore()
        _ = store.apply(["/a": "100:10"])
        _ = store.merge(["\u{0}blob": "garbage"])
        // The file changed while we could only see the blob.
        #expect(store.apply(["/a": "101:12"]) == true)
    }

    @Test("a changed blob is itself a change")
    func blobDeltaIsReported() {
        let store = WatchBaselineStore()
        #expect(store.merge(["\u{0}blob": "one"]) == false)
        #expect(store.merge(["\u{0}blob": "one"]) == false)
        #expect(store.merge(["\u{0}blob": "two"]) == true)
    }

    @Test("returning to per-path alignment drops the blob key")
    func alignmentClearsTheBlob() {
        let store = WatchBaselineStore()
        _ = store.merge(["\u{0}blob": "one"])
        _ = store.apply(["/a": "100:10"])
        #expect(store.signature(for: "\u{0}blob") == nil)
    }
}

/// PERF M3 / DI M7: a corrupt sidecar re-quarantined on every watcher
/// tick cost `listDirectory` + two round-trips per existing copy, forever,
/// and the copies were never pruned.
@Suite(.serialized) struct QuarantineMemoTests {

    private func tempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// A transport that counts the calls the dedup scan makes.
    private final class CountingTransport: ServerTransport, @unchecked Sendable {
        let inner = LocalTransport()
        var listCount = 0
        var readCount = 0
        var statCount = 0

        var contextID: ServerID { inner.contextID }
        var isRemote: Bool { false }
        func readFile(_ path: String) throws -> Data {
            readCount += 1
            return try inner.readFile(path)
        }
        func writeFile(_ path: String, data: Data) throws { try inner.writeFile(path, data: data) }
        func fileExists(_ path: String) -> Bool { inner.fileExists(path) }
        func stat(_ path: String) -> FileStat? {
            statCount += 1
            return inner.stat(path)
        }
        func listDirectory(_ path: String) throws -> [String] {
            listCount += 1
            return try inner.listDirectory(path)
        }
        func createDirectory(_ path: String) throws { try inner.createDirectory(path) }
        func removeFile(_ path: String) throws { try inner.removeFile(path) }
        func runProcess(
            executable: String, args: [String], stdin: Data?, timeout: TimeInterval?
        ) throws -> ProcessResult {
            throw TransportError.other(message: "unused")
        }
        #if !os(iOS)
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        #endif
        func streamLines(
            executable: String, args: [String]
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            throw TransportError.other(message: "unused")
        }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
            AsyncStream { $0.finish() }
        }
    }

    @Test("re-quarantining the same bytes costs no transport work after the first pass")
    func memoSkipsTheDedupScan() throws {
        QuarantineMemo.shared.reset()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/grants.json"
        let bytes = Data("{ not json".utf8)
        try bytes.write(to: URL(fileURLWithPath: path))

        let transport = CountingTransport()
        let first = GuardedJSONStore.quarantine(
            data: bytes, path: path, transport: transport, label: "grants.json"
        )
        #expect(first != nil)
        let listsAfterFirst = transport.listCount
        let readsAfterFirst = transport.readCount

        // What the watcher tick does, several times a second, while the
        // file stays corrupt.
        for _ in 0..<20 {
            #expect(
                GuardedJSONStore.quarantine(
                    data: bytes, path: path, transport: transport, label: "grants.json"
                ) == first
            )
        }
        #expect(transport.listCount == listsAfterFirst, "the dedup scan ran again")
        #expect(transport.readCount == readsAfterFirst, "the quarantine copies were re-read")
    }

    /// The memo must not answer for bytes it has never seen — otherwise a
    /// SECOND, different corruption would be silently filed under the
    /// first one's copy and its bytes would exist nowhere.
    @Test("different bytes still get their own quarantine copy")
    func differentBytesAreNotMemoized() throws {
        QuarantineMemo.shared.reset()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/grants.json"
        let transport = CountingTransport()
        let first = GuardedJSONStore.quarantine(
            data: Data("first".utf8), path: path, transport: transport, label: "grants.json"
        )
        let second = GuardedJSONStore.quarantine(
            data: Data("second and different".utf8), path: path,
            transport: transport, label: "grants.json"
        )
        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
    }

    @Test("quarantine copies are pruned to the newest few")
    func quarantineCopiesArePruned() throws {
        QuarantineMemo.shared.reset()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/grants.json"
        let transport = CountingTransport()
        // Ten distinct corruptions of the same file.
        for i in 0..<10 {
            _ = GuardedJSONStore.quarantine(
                data: Data("corruption number \(i)".utf8), path: path,
                transport: transport, label: "grants.json"
            )
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("grants.json.corrupt-") }
        #expect(remaining.count == GuardedJSONStore.quarantineKeepCount)
    }

    /// The invalidation edge that matters most: the memo must never hand
    /// back a path this process itself deleted.
    @Test("pruning forgets the memo entries it deletes")
    func pruningForgetsWhatItRemoves() throws {
        QuarantineMemo.shared.reset()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/grants.json"
        let transport = CountingTransport()
        let oldest = Data("the very first corruption".utf8)
        let firstCopy = try #require(GuardedJSONStore.quarantine(
            data: oldest, path: path, transport: transport, label: "grants.json"
        ))
        for i in 0..<10 {
            _ = GuardedJSONStore.quarantine(
                data: Data("corruption number \(i)".utf8), path: path,
                transport: transport, label: "grants.json"
            )
        }
        #expect(FileManager.default.fileExists(atPath: firstCopy) == false)
        #expect(QuarantineMemo.shared.copy(forPath: path, bytes: oldest) != firstCopy)
    }
}
