import Testing
import Foundation
@testable import ScarfCore

/// H3 — every `--json` surface added this cycle must be parsed from STDOUT
/// ALONE.
///
/// The three parsers slice their payload out of the buffer ("first `[` …
/// last `]`", or the brace pair) so a leading INFO line cannot break them.
/// That slice is only safe on a single stream: Scarf's combined runner
/// concatenates stderr AFTER stdout, so one warning line containing a
/// bracket or brace extends the slice past the end of the payload and the
/// decode fails outright. For `skills search` the failure is invisible — it
/// silently falls back to the table parser, which has no `#` column to key
/// off and returns nothing.
///
/// Hermes really does write to both streams here: `skills search` logs
/// registry warnings through `logging` (stderr) while printing the array on
/// stdout, and `computer-use permissions status --json` carries cua-driver's
/// own stderr chatter.
@Suite("JSON surfaces parse stdout only")
struct HermesJSONStreamPurityTests {

    /// A stderr line that ends in `]` — a skipped-registry warning is the
    /// realistic shape.
    static let noisyStderr = """
    WARNING hermes.skills: registry 'lobehub' unreachable [skipped]
    """

    static let searchStdout = """
    [{"name": "honcho", "identifier": "github:plastic-labs/honcho", \
    "source": "github", "trust_level": "community", \
    "description": "Memory provider for chat-scoped facts."}]
    """

    // MARK: - The slice really is stream-sensitive

    @Test func sliceOverTheConcatenatedStreamsLosesEveryRow() {
        // Baseline: stdout alone parses.
        #expect(HermesSkillsHubParser.parseSearchJSON(Self.searchStdout)?.count == 1)
        // Concatenated, the "last `]`" is the one in `[skipped]`.
        let merged = Self.searchStdout + "\n" + Self.noisyStderr
        #expect(HermesSkillsHubParser.parseSearchJSON(merged) == nil)
    }

    @Test func computerUseSliceOverTheConcatenatedStreamsFails() {
        let stdout = """
        {"platform": "darwin", "can_grant": true, "ready": true, "checks": []}
        """
        #expect(HermesComputerUseStatus.parse(stdout) != nil)
        let merged = stdout + "\nWARNING cua-driver: probe timed out {retry}\n"
        #expect(HermesComputerUseStatus.parse(merged) == nil)
    }

    // MARK: - The production path feeds the parser stdout alone

    @MainActor
    @Test func hubSearchParsesTheJSONDespiteAWarningOnStderr() async throws {
        let transport = SplitStreamTransport(
            stdout: Self.searchStdout, stderr: Self.noisyStderr, exitCode: 0)
        let vm = SkillsViewModel(context: .local, transport: transport)
        // v0.21.1 host: `skills search --json` is asked for (v0.17+ floor).
        vm.capabilities = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        vm.hubSource = "github"   // source-specific → the CLI path, not the filter
        vm.hubQuery = "honcho"
        vm.searchHub()
        try await Self.settle(vm)
        #expect(vm.hubResults.count == 1)
        #expect(vm.hubResults.first?.identifier == "github:plastic-labs/honcho")
        // The argv really did carry --json (otherwise this passes for the
        // wrong reason via the table parser).
        #expect(transport.lastArgs.contains("--json"))
    }

    /// M2 — the query is user text and goes after `--`, or a query that
    /// starts with `-` exits 2 as an unknown flag.
    @MainActor
    @Test func hubSearchEndsOptionsBeforeTheQuery() async throws {
        let transport = SplitStreamTransport(stdout: "[]", stderr: "", exitCode: 0)
        let vm = SkillsViewModel(context: .local, transport: transport)
        vm.capabilities = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        vm.hubSource = "github"
        vm.hubQuery = "--json"
        vm.searchHub()
        try await Self.settle(vm)
        #expect(Array(transport.lastArgs.suffix(2)) == ["--", "--json"])
        // The real `--json` flag is still before the marker.
        #expect(transport.lastArgs.firstIndex(of: "--json")! < transport.lastArgs.count - 1)
    }

    /// Wait for the detached hub fetch to commit, bounded.
    private static func settle(_ vm: SkillsViewModel) async throws {
        for _ in 0..<200 {
            if await !vm.isHubLoading { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("hub search never finished")
    }
}

/// Test double whose `runProcess` answers with distinct stdout / stderr.
final class SplitStreamTransport: ServerTransport, @unchecked Sendable {
    let contextID: ServerID = UUID()
    let isRemote: Bool = false
    private let out: String
    private let err: String
    private let code: Int32
    private(set) var lastArgs: [String] = []

    init(stdout: String, stderr: String, exitCode: Int32) {
        self.out = stdout
        self.err = stderr
        self.code = exitCode
    }

    func readFile(_ path: String) throws -> Data { throw TransportError.other(message: "N/A") }
    func unguardedWriteFile(_ path: String, data: Data) throws { throw TransportError.other(message: "N/A") }
    func fileExists(_ path: String) -> Bool { false }
    func stat(_ path: String) -> FileStat? { nil }
    func listDirectory(_ path: String) throws -> [String] { [] }
    func createDirectory(_ path: String) throws {}
    func removeFile(_ path: String) throws {}
    func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
        lastArgs = args
        return ProcessResult(exitCode: code, stdout: Data(out.utf8), stderr: Data(err.utf8))
    }
    #if !os(iOS)
    func makeProcess(executable: String, args: [String]) -> Process { Process() }
    #endif
    func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { AsyncStream { $0.finish() } }
}
