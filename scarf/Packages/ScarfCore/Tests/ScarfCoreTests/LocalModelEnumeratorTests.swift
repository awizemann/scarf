import Testing
import Foundation
@testable import ScarfCore

/// T2 — enumeration of models actually installed on the Hermes host.
/// Pure parse + URL-resolution coverage needs no network; the transport
/// seam is exercised with a recording fake `ServerTransport` (same
/// pattern as M5's `ScriptedTransport`), so the outcome mapping —
/// reachable / reachable-empty / unreachable / parse-failure — is
/// pinned without a live daemon. The shell-safety tests are the
/// load-bearing ones: a base URL is user-influenced and travels toward
/// a remote shell, so `$(…)` must never reach the transport.
@Suite struct LocalModelEnumeratorTests {

    // MARK: - Fixtures

    /// Verbatim shape of Ollama's `GET /api/tags` (v0.5-era fields the
    /// parser relies on; extra keys ignored).
    static let ollamaTagsJSON = Data("""
    {"models":[
      {"name":"llama3:8b","model":"llama3:8b","modified_at":"2026-06-01T10:00:00Z",
       "size":4920753328,
       "details":{"parent_model":"","format":"gguf","family":"llama",
                  "parameter_size":"8B","quantization_level":"Q4_K_M"}},
      {"name":"qwen3:0.6b","size":522653767,
       "details":{"parameter_size":"751.63M","quantization_level":"Q4_K_M"}}
    ]}
    """.utf8)

    static let openAIModelsJSON = Data("""
    {"object":"list","data":[
      {"id":"qwen2.5-7b-instruct","object":"model","owned_by":"organization_owner"},
      {"id":"text-embedding-nomic-embed-text-v1.5","object":"model","owned_by":"organization_owner"}
    ]}
    """.utf8)

    static func descriptor(_ id: String) -> LocalModelProvider {
        LocalModelProvider.descriptor(for: id)!
    }

    // MARK: - parseOllamaTags

    @Test func ollamaTagsParseCarriesIDAndHumanDetail() throws {
        let models = try #require(LocalModelEnumerator.parseOllamaTags(Self.ollamaTagsJSON))
        #expect(models.count == 2)
        // The id is the tag verbatim — it's what T3 writes to model.default.
        #expect(models[0].modelID == "llama3:8b")
        #expect(models[0].name == "llama3:8b")
        // Subtitle: param size · quant · on-disk size (deterministic format).
        #expect(models[0].detail == "8B · Q4_K_M · 4.6 GB")
        #expect(models[1].modelID == "qwen3:0.6b")
        #expect(models[1].detail == "751.63M · Q4_K_M · 498 MB")
    }

    @Test func ollamaTagsParseToleratesMissingDetails() throws {
        let json = Data(#"{"models":[{"name":"tiny:latest"}]}"#.utf8)
        let models = try #require(LocalModelEnumerator.parseOllamaTags(json))
        #expect(models == [LocalModelInfo(modelID: "tiny:latest", name: "tiny:latest", detail: nil)])
    }

    @Test func ollamaTagsEmptyModelsArrayParsesToEmpty() throws {
        // Empty is a VALID response (daemon up, nothing pulled) — it must
        // parse, so listModels can distinguish reachableEmpty from failure.
        let models = try #require(LocalModelEnumerator.parseOllamaTags(Data(#"{"models":[]}"#.utf8)))
        #expect(models.isEmpty)
    }

    @Test func ollamaTagsMalformedAndOffShapeJSONFailParse() {
        #expect(LocalModelEnumerator.parseOllamaTags(Data("not json".utf8)) == nil)
        #expect(LocalModelEnumerator.parseOllamaTags(Data()) == nil)
        // Valid JSON, wrong shape (an HTML-ish error or another service).
        #expect(LocalModelEnumerator.parseOllamaTags(Data(#"{"error":"nope"}"#.utf8)) == nil)
        // The OpenAI shape must NOT satisfy the Ollama parser.
        #expect(LocalModelEnumerator.parseOllamaTags(Self.openAIModelsJSON) == nil)
    }

    // MARK: - parseOpenAIModels

    @Test func openAIModelsParseCarriesIDs() throws {
        let models = try #require(LocalModelEnumerator.parseOpenAIModels(Self.openAIModelsJSON))
        #expect(models.map(\.modelID) == [
            "qwen2.5-7b-instruct",
            "text-embedding-nomic-embed-text-v1.5",
        ])
        // The /v1/models shape has nothing human beyond the id.
        #expect(models.allSatisfy { $0.detail == nil })
    }

    @Test func openAIModelsEmptyDataParsesToEmpty() throws {
        let models = try #require(LocalModelEnumerator.parseOpenAIModels(Data(#"{"object":"list","data":[]}"#.utf8)))
        #expect(models.isEmpty)
    }

    @Test func openAIModelsMalformedAndOffShapeJSONFailParse() {
        #expect(LocalModelEnumerator.parseOpenAIModels(Data("<html>502</html>".utf8)) == nil)
        #expect(LocalModelEnumerator.parseOpenAIModels(Data()) == nil)
        // The Ollama shape must NOT satisfy the OpenAI parser.
        #expect(LocalModelEnumerator.parseOpenAIModels(Self.ollamaTagsJSON) == nil)
    }

    // MARK: - URL resolution

    @Test func ollamaTagsEndpointStripsTheV1Suffix() {
        // config.yaml base URLs carry the /v1 OpenAI-compat suffix, but
        // /api/tags lives at the server root — NOT under /v1.
        #expect(LocalModelEnumerator.endpointURL(
            for: .ollamaTags, baseURL: "http://127.0.0.1:11434/v1", descriptorDefault: nil
        ) == "http://127.0.0.1:11434/api/tags")
        // Trailing slash after /v1 also stripped.
        #expect(LocalModelEnumerator.endpointURL(
            for: .ollamaTags, baseURL: "http://127.0.0.1:11434/v1/", descriptorDefault: nil
        ) == "http://127.0.0.1:11434/api/tags")
        // No /v1 in the base → nothing to strip.
        #expect(LocalModelEnumerator.endpointURL(
            for: .ollamaTags, baseURL: "http://192.168.1.5:11434", descriptorDefault: nil
        ) == "http://192.168.1.5:11434/api/tags")
    }

    @Test func openAIEndpointAppendsModelsUnderV1() {
        // Base already ends in /v1 (the conventional config form).
        #expect(LocalModelEnumerator.endpointURL(
            for: .openAIModels, baseURL: "http://127.0.0.1:1234/v1", descriptorDefault: nil
        ) == "http://127.0.0.1:1234/v1/models")
        // Bare host:port → the /v1 prefix is supplied.
        #expect(LocalModelEnumerator.endpointURL(
            for: .openAIModels, baseURL: "http://127.0.0.1:8000", descriptorDefault: nil
        ) == "http://127.0.0.1:8000/v1/models")
    }

    @Test func explicitBaseURLBeatsDescriptorDefault() {
        #expect(LocalModelEnumerator.endpointURL(
            for: .ollamaTags,
            baseURL: "http://gpu-box.local:11434/v1",
            descriptorDefault: "http://127.0.0.1:11434/v1"
        ) == "http://gpu-box.local:11434/api/tags")
        // Blank/whitespace explicit value falls back to the default.
        #expect(LocalModelEnumerator.endpointURL(
            for: .ollamaTags,
            baseURL: "   ",
            descriptorDefault: "http://127.0.0.1:11434/v1"
        ) == "http://127.0.0.1:11434/api/tags")
        #expect(LocalModelEnumerator.endpointURL(
            for: .ollamaTags,
            baseURL: nil,
            descriptorDefault: "http://127.0.0.1:11434/v1"
        ) == "http://127.0.0.1:11434/api/tags")
    }

    @Test func noURLAnywhereResolvesToNil() {
        // vLLM/llamacpp have no runtime default — no URL means no probe.
        #expect(LocalModelEnumerator.endpointURL(
            for: .openAIModels, baseURL: nil, descriptorDefault: nil
        ) == nil)
        #expect(LocalModelEnumerator.endpointURL(
            for: .none, baseURL: "http://127.0.0.1:8000/v1", descriptorDefault: nil
        ) == nil)
    }

    // MARK: - Shell-safety gate (the load-bearing tests)

    @Test func baseURLWithCommandSubstitutionIsRejected() {
        // A base URL travels toward a remote shell. `$(…)`, backticks,
        // quotes, semicolons, whitespace — none may survive validation.
        let hostile = [
            "http://127.0.0.1:11434/v1$(touch /tmp/pwned)",
            "http://$(hostname):11434/v1",
            "http://127.0.0.1:11434/`id`",
            "http://127.0.0.1:11434/v1; rm -rf ~",
            "http://127.0.0.1:11434/v1 --output /tmp/x",
            "http://127.0.0.1:11434/v1'",
            "http://127.0.0.1:11434/v1\"",
            "http://127.0.0.1:11434/v1&",
            "http://127.0.0.1:11434/v1|cat",
            "http://user:pass@127.0.0.1:11434/v1",
            "http://127.0.0.1:11434/v1?x=$(id)",
            "file:///etc/passwd",
            "ftp://127.0.0.1/v1",
            "127.0.0.1:11434/v1", // schemeless
        ]
        for url in hostile {
            #expect(LocalModelEnumerator.validatedBaseURL(url) == nil, "accepted hostile URL: \(url)")
        }
    }

    @Test func legitimateBaseURLShapesAreAccepted() {
        #expect(LocalModelEnumerator.validatedBaseURL("http://127.0.0.1:11434/v1") == "http://127.0.0.1:11434/v1")
        #expect(LocalModelEnumerator.validatedBaseURL("https://gpu-box.tail1234.ts.net:8000/v1") == "https://gpu-box.tail1234.ts.net:8000/v1")
        #expect(LocalModelEnumerator.validatedBaseURL("http://[::1]:11434/v1") == "http://[::1]:11434/v1")
        // Trimmed + trailing slashes stripped.
        #expect(LocalModelEnumerator.validatedBaseURL("  http://localhost:1234/v1/  ") == "http://localhost:1234/v1")
    }

    @Test func hostileBaseURLNeverReachesTheTransport() {
        // End-to-end pin for the injection gate: listModels with a
        // hostile URL must return .invalidBaseURL WITHOUT invoking the
        // transport at all.
        let transport = RecordingTransport(result: ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()))
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("ollama"),
            baseURL: "http://127.0.0.1:11434/v1$(reboot)",
            transport: transport
        )
        #expect(outcome == .invalidBaseURL)
        #expect(transport.calls.isEmpty, "hostile URL reached the transport: \(transport.calls)")
    }

    @Test func urlTravelsAsItsOwnArgvElement() throws {
        // The URL must be a single argv element handed to runProcess —
        // never embedded in a `sh -c` command string this service builds.
        let transport = RecordingTransport(result: ProcessResult(
            exitCode: 0, stdout: Self.ollamaTagsJSON, stderr: Data()
        ))
        _ = LocalModelEnumerator.listModels(
            for: Self.descriptor("ollama"), baseURL: nil, transport: transport
        )
        let call = try #require(transport.calls.first)
        #expect(call.args.last == "http://127.0.0.1:11434/api/tags")
        #expect(!call.executable.contains("sh"))
        #expect(!call.args.contains("-c"))
        // `-f` is load-bearing: without it an HTTP >= 400 (daemon up, wrong
        // path) returns exit 0 with an error body and gets misread as a parse
        // failure instead of unreachable. Pin the whole flag bundle so a
        // regression that drops `-f`/`-S` can't slip through silently.
        #expect(call.args.contains("-sSf"))
    }

    // MARK: - Outcome mapping via the transport seam

    @Test func reachableWithModelsYieldsModels() {
        let transport = RecordingTransport(result: ProcessResult(
            exitCode: 0, stdout: Self.ollamaTagsJSON, stderr: Data()
        ))
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("ollama"), baseURL: nil, transport: transport
        )
        guard case .models(let models) = outcome else {
            Issue.record("expected .models, got \(outcome)")
            return
        }
        #expect(models.map(\.modelID) == ["llama3:8b", "qwen3:0.6b"])
    }

    @Test func reachableEmptyIsDistinctFromUnreachable() {
        // Daemon up, zero models pulled — T3 renders "run ollama pull",
        // NOT "Ollama isn't running".
        let transport = RecordingTransport(result: ProcessResult(
            exitCode: 0, stdout: Data(#"{"models":[]}"#.utf8), stderr: Data()
        ))
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("ollama"), baseURL: nil, transport: transport
        )
        #expect(outcome == .reachableEmpty)
    }

    @Test func daemonDownYieldsUnreachableWithCurlStderr() {
        // curl exit 7 = connection refused; -S puts the reason on stderr.
        let transport = RecordingTransport(result: ProcessResult(
            exitCode: 7, stdout: Data(),
            stderr: Data("curl: (7) Failed to connect to 127.0.0.1 port 11434".utf8)
        ))
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("ollama"), baseURL: nil, transport: transport
        )
        #expect(outcome == .unreachable(detail: "curl: (7) Failed to connect to 127.0.0.1 port 11434"))
    }

    @Test func curlMissingOnHostDegradesToUnreachable() {
        // Remote shell without curl: exit 127, "command not found".
        let missing = RecordingTransport(result: ProcessResult(
            exitCode: 127, stdout: Data(), stderr: Data("sh: curl: command not found".utf8)
        ))
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("lmstudio"), baseURL: nil, transport: missing
        )
        #expect(outcome == .unreachable(detail: "sh: curl: command not found"))

        // Local spawn failure: runProcess throws instead of exiting.
        let throwing = RecordingTransport(error: TransportError.other(message: "Failed to launch /usr/bin/curl"))
        let thrown = LocalModelEnumerator.listModels(
            for: Self.descriptor("lmstudio"), baseURL: nil, transport: throwing
        )
        guard case .unreachable = thrown else {
            Issue.record("expected .unreachable, got \(thrown)")
            return
        }
    }

    @Test func wrongServiceOnPortYieldsParseFailure() {
        let transport = RecordingTransport(result: ProcessResult(
            exitCode: 0, stdout: Data("<html>It works!</html>".utf8), stderr: Data()
        ))
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("lmstudio"), baseURL: nil, transport: transport
        )
        #expect(outcome == .parseFailure(detail: "<html>It works!</html>"))
    }

    @Test func missingBaseURLForDefaultlessProviderIsInvalidBaseURL() {
        // vLLM has no runtime default; without a user URL there is
        // nothing to probe — and the transport must not be touched.
        let transport = RecordingTransport(result: ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()))
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("vllm"), baseURL: nil, transport: transport
        )
        #expect(outcome == .invalidBaseURL)
        #expect(transport.calls.isEmpty)
    }

    @Test func noneHintIsNotEnumerableAndSkipsTheTransport() {
        // No table descriptor carries `.none` today, but the API accepts
        // any descriptor — a free-form-only provider must short-circuit
        // even when a base URL is available.
        let freeform = LocalModelProvider(
            providerID: "freeform",
            displayName: "Freeform",
            blurb: "",
            defaultBaseURL: "http://127.0.0.1:9999/v1",
            baseURLPlaceholder: "",
            baseURLRequired: false,
            enumerationHint: .none,
            credentialInstruction: ""
        )
        let transport = RecordingTransport(result: ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()))
        let outcome = LocalModelEnumerator.listModels(
            for: freeform, baseURL: nil, transport: transport
        )
        #expect(outcome == .notEnumerable)
        #expect(transport.calls.isEmpty)
    }

    @Test func probeUsesShortCurlTimeout() throws {
        // The picker must never hang: curl gets an explicit --max-time.
        let transport = RecordingTransport(result: ProcessResult(
            exitCode: 0, stdout: Self.openAIModelsJSON, stderr: Data()
        ))
        _ = LocalModelEnumerator.listModels(
            for: Self.descriptor("lmstudio"), baseURL: nil, transport: transport
        )
        let call = try #require(transport.calls.first)
        let maxTimeIdx = try #require(call.args.firstIndex(of: "--max-time"))
        let seconds = try #require(Int(call.args[maxTimeIdx + 1]))
        #expect(seconds <= 3)
        let timeout = try #require(call.timeout)
        #expect(timeout <= 15)
    }

    @Test func remoteTransportResolvesCurlViaPathLocalUsesAbsolutePath() {
        // SSH runProcess goes through the remote shell (PATH lookup);
        // LocalTransport spawns the path directly (no PATH lookup).
        #expect(LocalModelEnumerator.curlExecutable(isRemote: true) == "curl")
        #expect(LocalModelEnumerator.curlExecutable(isRemote: false) == "/usr/bin/curl")
    }

    // MARK: - formatBytes

    @Test func byteFormattingIsDeterministic() {
        #expect(LocalModelEnumerator.formatBytes(4_920_753_328) == "4.6 GB")
        #expect(LocalModelEnumerator.formatBytes(522_653_767) == "498 MB")
        #expect(LocalModelEnumerator.formatBytes(900) == "900 B")
    }
}

// MARK: - Recording fake transport

/// Minimal `ServerTransport` double for the runProcess seam — records
/// every call and replays a canned `ProcessResult` (or throws). Same
/// pattern as M5's `ScriptedTransport`; file I/O is deliberately N/A.
private final class RecordingTransport: ServerTransport, @unchecked Sendable {
    struct Call {
        let executable: String
        let args: [String]
        let timeout: TimeInterval?
    }

    let contextID: ServerID = UUID()
    let isRemote: Bool
    private let result: ProcessResult?
    private let error: Error?
    private(set) var calls: [Call] = []

    init(result: ProcessResult, isRemote: Bool = true) {
        self.result = result
        self.error = nil
        self.isRemote = isRemote
    }

    init(error: Error, isRemote: Bool = true) {
        self.result = nil
        self.error = error
        self.isRemote = isRemote
    }

    func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
        calls.append(Call(executable: executable, args: args, timeout: timeout))
        if let error { throw error }
        return result!
    }

    func readFile(_ path: String) throws -> Data { throw TransportError.other(message: "N/A") }
    func writeFile(_ path: String, data: Data) throws { throw TransportError.other(message: "N/A") }
    func fileExists(_ path: String) -> Bool { false }
    func stat(_ path: String) -> FileStat? { nil }
    func listDirectory(_ path: String) throws -> [String] { [] }
    func createDirectory(_ path: String) throws {}
    func removeFile(_ path: String) throws {}
    #if !os(iOS)
    func makeProcess(executable: String, args: [String]) -> Process { Process() }
    #endif
    func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
        AsyncStream { $0.finish() }
    }
}
