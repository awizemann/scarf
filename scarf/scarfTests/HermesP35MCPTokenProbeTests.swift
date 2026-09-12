import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P35 (LOW) — `loadMCPServers` answered "does this server have an OAuth
/// token?" with up to two `fileExists` probes PER SERVER, i.e. up to 2N
/// serialized SSH round trips inside one load. One directory listing answers
/// the whole roster.
@Suite("P35 — one listing, not 2N exists probes")
struct HermesP35MCPTokenProbeTests {

    /// Decorates a real transport, counting the two calls under test.
    final class CountingTransport: ServerTransport, @unchecked Sendable {
        private let inner: any ServerTransport
        private let lock = NSLock()
        private var _exists = 0
        private var _lists = 0
        var existsCalls: Int { lock.lock(); defer { lock.unlock() }; return _exists }
        var listCalls: Int { lock.lock(); defer { lock.unlock() }; return _lists }

        init(_ inner: any ServerTransport) { self.inner = inner }

        var contextID: ServerID { inner.contextID }
        var isRemote: Bool { inner.isRemote }
        func readFile(_ path: String) throws -> Data { try inner.readFile(path) }
        func unguardedWriteFile(_ path: String, data: Data) throws {
            try inner.unguardedWriteFile(path, data: data)
        }
        func fileExists(_ path: String) -> Bool {
            lock.lock(); _exists += 1; lock.unlock()
            return inner.fileExists(path)
        }
        func stat(_ path: String) -> FileStat? { inner.stat(path) }
        func statAll(_ paths: [String]) -> [String: FileStat]? { inner.statAll(paths) }
        func listDirectory(_ path: String) throws -> [String] {
            lock.lock(); _lists += 1; lock.unlock()
            return try inner.listDirectory(path)
        }
        func createDirectory(_ path: String) throws { try inner.createDirectory(path) }
        func removeFile(_ path: String) throws { try inner.removeFile(path) }
        func runProcess(
            executable: String, args: [String], stdin: Data?, timeout: TimeInterval
        ) throws -> ProcessResult {
            try inner.runProcess(executable: executable, args: args, stdin: stdin, timeout: timeout)
        }
        func makeProcess(executable: String, args: [String]) -> Process {
            inner.makeProcess(executable: executable, args: args)
        }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
            inner.watchPaths(paths)
        }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            try await inner.streamScript(script, timeout: timeout)
        }
        func makeProcess(executable: String, args: [String], cwd: String?) -> Process {
            inner.makeProcess(executable: executable, args: args, cwd: cwd)
        }
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            inner.streamLines(executable: executable, args: args)
        }
    }

    /// Five servers, each with a name that needs sanitizing so the OLD code
    /// probed BOTH spellings: 10 `fileExists` calls before the fix, 1 listing
    /// after it.
    @Test func fiveServersCostOneListingAndNoExistsProbes() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p35-mcp-\(UUID().uuidString)")
        let tokens = home.appendingPathComponent("mcp-tokens")
        try FileManager.default.createDirectory(at: tokens, withIntermediateDirectories: true)

        let names = ["github.com", "gitlab.com", "linear.app", "notion.so", "sentry.io"]
        let yaml = "mcp_servers:\n" + names.map {
            "  \"\($0)\":\n    url: https://\($0)/mcp\n    transport: http\n"
        }.joined()
        try yaml.write(to: home.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        // One server HAS a token, under Hermes's sanitized spelling.
        try "{}".write(to: tokens.appendingPathComponent("github_com.json"),
                       atomically: true, encoding: .utf8)

        let context = ServerContext.local(home: home)
        let counting = CountingTransport(context.makeTransport())
        let servers = HermesFileService(context: context, transport: counting).loadMCPServers()

        #expect(servers.count == 5, "premise: all five servers parsed")
        #expect(counting.listCalls == 1, "expected exactly one `mcp-tokens/` listing")
        #expect(counting.existsCalls == 0,
                "loadMCPServers still probes per server — \(counting.existsCalls) `fileExists` calls for 5 servers")
        // …and the answer is still right, sanitized spelling and all.
        #expect(servers.first { $0.name == "github.com" }?.hasOAuthToken == true)
        #expect(servers.filter(\.hasOAuthToken).count == 1)
    }

    /// An absent `mcp-tokens/` directory is "nobody has a token", not a crash
    /// and not "everybody" — the same answer the per-path probe gave.
    @Test func anAbsentTokensDirectoryMeansNoTokens() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p35-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "mcp_servers:\n  \"github.com\":\n    url: https://github.com/mcp\n    transport: http\n"
            .write(to: home.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let context = ServerContext.local(home: home)
        let servers = HermesFileService(context: context).loadMCPServers()
        // `try #require`, not `#expect(count) ` + a bare subscript: an index
        // after a FAILED count expectation traps, and a trap in one Swift
        // Testing test takes the whole `scarfTests` host down with it. The
        // `#require` throws out of this one test instead.
        #expect(servers.count == 1)
        let server = try #require(servers.first)
        #expect(server.hasOAuthToken == false)
    }
}
