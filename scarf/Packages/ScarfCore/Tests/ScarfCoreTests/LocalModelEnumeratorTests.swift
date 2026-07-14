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

    /// Verbatim-shaped subset of Ollama's `POST /api/show` response
    /// (captured live from qwen2.5:14b — model_info keys are
    /// `<arch>.`-prefixed, the context ceiling under
    /// `<general.architecture>.context_length`).
    static let ollamaShowQwenJSON = Data("""
    {"details":{"family":"qwen2","parameter_size":"14.8B","quantization_level":"Q4_K_M"},
     "model_info":{"general.architecture":"qwen2","general.parameter_count":14770033664,
                   "qwen2.attention.head_count":40,"qwen2.context_length":32768,
                   "qwen2.embedding_length":5120},
     "capabilities":["completion","tools"]}
    """.utf8)

    static let ollamaShowLlamaJSON = Data("""
    {"model_info":{"general.architecture":"llama","llama.context_length":131072,
                   "llama.rope.dimension_count":128}}
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

    // MARK: - parseOllamaShowContext (/api/show shapes)

    @Test func showContextResolvesViaGeneralArchitecture() {
        #expect(LocalModelEnumerator.parseOllamaShowContext(Self.ollamaShowQwenJSON) == 32768)
        #expect(LocalModelEnumerator.parseOllamaShowContext(Self.ollamaShowLlamaJSON) == 131072)
    }

    @Test func showContextFallsBackToSuffixMatchForUnknownArchKeys() {
        // A future/unknown architecture that doesn't advertise
        // general.architecture (or names it differently) must still
        // resolve via the `.context_length` suffix.
        let noArch = Data(#"{"model_info":{"newarch.context_length":65536,"newarch.embedding_length":4096}}"#.utf8)
        #expect(LocalModelEnumerator.parseOllamaShowContext(noArch) == 65536)
        // general.architecture present but its keyed entry missing —
        // suffix fallback still finds the real key.
        let mismatch = Data(#"{"model_info":{"general.architecture":"gemma3","other.context_length":8192}}"#.utf8)
        #expect(LocalModelEnumerator.parseOllamaShowContext(mismatch) == 8192)
    }

    @Test func showContextRejectsOffShapeAndNonPositiveValues() {
        // Ollama's 404 error body (model deleted between tags and show).
        #expect(LocalModelEnumerator.parseOllamaShowContext(Data(#"{"error":"model 'x' not found"}"#.utf8)) == nil)
        // No model_info at all.
        #expect(LocalModelEnumerator.parseOllamaShowContext(Data(#"{"details":{"family":"llama"}}"#.utf8)) == nil)
        // model_info present, no context key.
        #expect(LocalModelEnumerator.parseOllamaShowContext(Data(#"{"model_info":{"general.architecture":"llama"}}"#.utf8)) == nil)
        // Malformed / empty.
        #expect(LocalModelEnumerator.parseOllamaShowContext(Data("not json".utf8)) == nil)
        #expect(LocalModelEnumerator.parseOllamaShowContext(Data()) == nil)
        // Wrong value types / non-positive numbers never become a gate input.
        #expect(LocalModelEnumerator.parseOllamaShowContext(Data(#"{"model_info":{"llama.context_length":"131072"}}"#.utf8)) == nil)
        #expect(LocalModelEnumerator.parseOllamaShowContext(Data(#"{"model_info":{"llama.context_length":true}}"#.utf8)) == nil)
        #expect(LocalModelEnumerator.parseOllamaShowContext(Data(#"{"model_info":{"llama.context_length":0}}"#.utf8)) == nil)
        #expect(LocalModelEnumerator.parseOllamaShowContext(Data(#"{"model_info":{"llama.context_length":-1}}"#.utf8)) == nil)
    }

    // MARK: - parseOllamaShowVision (/api/show capabilities shapes)

    @Test func showVisionIsYesWhenCapabilitiesListVision() {
        // Ollama ≥ 0.29 shape for a multimodal model (llama3.2-vision /
        // llava): top-level `capabilities` includes "vision".
        let vision = Data(#"{"capabilities":["completion","vision"]}"#.utf8)
        #expect(LocalModelEnumerator.parseOllamaShowVision(vision) == .yes)
        // Order-independent, extra caps ignored.
        let visionTools = Data(#"{"capabilities":["completion","tools","vision","insert"]}"#.utf8)
        #expect(LocalModelEnumerator.parseOllamaShowVision(visionTools) == .yes)
    }

    @Test func showVisionIsNoWhenCapabilitiesPresentButOmitVision() {
        // The exact live shape for llama3.1:8b / qwen2.5:14b on 0.31.2 —
        // capabilities present, no "vision". A CONFIDENT non-vision verdict
        // (this is what makes the composer heads-up finally fire locally).
        let textOnly = Data(#"{"capabilities":["completion","tools"]}"#.utf8)
        #expect(LocalModelEnumerator.parseOllamaShowVision(textOnly) == .no)
        #expect(LocalModelEnumerator.parseOllamaShowVision(Data(#"{"capabilities":["completion"]}"#.utf8)) == .no)
        // Empty array is still a present-but-no-vision statement.
        #expect(LocalModelEnumerator.parseOllamaShowVision(Data(#"{"capabilities":[]}"#.utf8)) == .no)
        // The qwen fixture carries capabilities without vision.
        #expect(LocalModelEnumerator.parseOllamaShowVision(Self.ollamaShowQwenJSON) == .no)
    }

    @Test func showVisionIsUnknownWhenCapabilitiesKeyAbsentOrUnreadable() {
        // Pre-0.29 Ollama omits `capabilities` entirely — MUST degrade to
        // .unknown (never a false .no), preserving the no-false-warning
        // invariant for old daemons, LM Studio, and custom endpoints.
        #expect(LocalModelEnumerator.parseOllamaShowVision(Self.ollamaShowLlamaJSON) == .unknown)
        #expect(LocalModelEnumerator.parseOllamaShowVision(Data(#"{"model_info":{"general.architecture":"llama"}}"#.utf8)) == .unknown)
        // Error body (model deleted between tags and show).
        #expect(LocalModelEnumerator.parseOllamaShowVision(Data(#"{"error":"model 'x' not found"}"#.utf8)) == .unknown)
        // Wrong type for capabilities, malformed, empty.
        #expect(LocalModelEnumerator.parseOllamaShowVision(Data(#"{"capabilities":"vision"}"#.utf8)) == .unknown)
        #expect(LocalModelEnumerator.parseOllamaShowVision(Data("not json".utf8)) == .unknown)
        #expect(LocalModelEnumerator.parseOllamaShowVision(Data()) == .unknown)
    }

    // MARK: - Model-name allowlist (the show-batch injection gate)

    @Test func modelNameAllowlistAcceptsEveryLegalOllamaShape() {
        for name in [
            "llama3.1:8b", "qwen2.5:14b", "llama3:latest",
            "hf.co/user/repo:Q4_K_M",
            "model@sha256:24a0a8c65a4f0a9e4b8e7f3a",
            "registry.example.com/team/model:tag",
        ] {
            #expect(LocalModelEnumerator.validatedOllamaModelName(name), "rejected legal name: \(name)")
        }
    }

    @Test func modelNameAllowlistRejectsShellAndJSONActiveNames() {
        for name in [
            "", "a b", "a\tb",
            "evil$(reboot):latest", "`id`:8b", "a;rm -rf ~", "a|cat", "a&b",
            "a'b", "a\"b", "a\\b",
            "a\u{1E}b", // the record separator itself
            String(repeating: "x", count: 257),
        ] {
            #expect(!LocalModelEnumerator.validatedOllamaModelName(name), "accepted hostile name: \(name)")
        }
    }

    // MARK: - Show batch argv (the batching/quoting pin)

    @Test func showBatchArgumentsPinTheExactArgvShape() throws {
        let batch = try #require(LocalModelEnumerator.showBatchArguments(
            showEndpoint: "http://127.0.0.1:11434/api/show",
            modelNames: ["llama3.1:8b", "qwen2.5:14b"]
        ))
        let rs = String(UnicodeScalar(LocalModelEnumerator.showRecordSeparator))
        #expect(batch.probedNames == ["llama3.1:8b", "qwen2.5:14b"])
        #expect(batch.args == [
            "-sS", "--max-time", "3",
            "-d", #"{"model":"llama3.1:8b"}"#,
            "-w", rs,
            "http://127.0.0.1:11434/api/show",
            "--next",
            "-sS", "--max-time", "3",
            "-d", #"{"model":"qwen2.5:14b"}"#,
            "-w", rs,
            "http://127.0.0.1:11434/api/show",
        ])
        // The batch is plain argv — never an `sh -c` command string, and
        // deliberately no `-f` (an HTTP error must yield its JSON error
        // body + separator so response↔name correlation survives).
        #expect(!batch.args.contains("-c"))
        #expect(!batch.args.contains("sh"))
        #expect(!batch.args.contains("-f"))
        #expect(!batch.args.contains("-sSf"))
    }

    @Test func hostileModelNameNeverReachesTheTransportBatch() throws {
        // The load-bearing pin: a daemon-supplied hostile name is
        // dropped from the batch entirely — no argv element carries it.
        let batch = try #require(LocalModelEnumerator.showBatchArguments(
            showEndpoint: "http://127.0.0.1:11434/api/show",
            modelNames: ["good:8b", "evil$(touch /tmp/pwned):latest", "bad`id`:1b"]
        ))
        #expect(batch.probedNames == ["good:8b"])
        #expect(!batch.args.contains { $0.contains("pwned") || $0.contains("`") || $0.contains("$(") })
        // All-hostile input → no batch at all.
        #expect(LocalModelEnumerator.showBatchArguments(
            showEndpoint: "http://127.0.0.1:11434/api/show",
            modelNames: ["evil$(reboot)"]
        ) == nil)
    }

    // MARK: - Show batch response correlation

    private static func rsJoined(_ segments: [Data]) -> Data {
        var out = Data()
        for s in segments {
            out.append(s)
            out.append(LocalModelEnumerator.showRecordSeparator)
        }
        return out
    }

    @Test func showBatchSegmentsPairPositionallyWithProbedNames() {
        let data = Self.rsJoined([Self.ollamaShowLlamaJSON, Self.ollamaShowQwenJSON])
        let meta = LocalModelEnumerator.parseShowBatch(data, probedNames: ["llama3.1:8b", "qwen2.5:14b"])
        #expect(meta.mapValues(\.contextLength) == ["llama3.1:8b": 131072, "qwen2.5:14b": 32768])
        // Vision rides the same segments: llama's fixture has no
        // `capabilities` key (→ .unknown), qwen's lists ["completion",
        // "tools"] without "vision" (→ .no).
        #expect(meta["llama3.1:8b"]?.visionCapability == .unknown)
        #expect(meta["qwen2.5:14b"]?.visionCapability == .no)
    }

    @Test func failedTransferYieldsNoContextForThatModelOnly() {
        // Mid-batch 404 (model deleted between /api/tags and /api/show):
        // no -f, so the error body + separator keep the count intact.
        let data = Self.rsJoined([
            Self.ollamaShowLlamaJSON,
            Data(#"{"error":"model 'gone:1b' not found"}"#.utf8),
            Self.ollamaShowQwenJSON,
        ])
        let meta = LocalModelEnumerator.parseShowBatch(
            data, probedNames: ["llama3.1:8b", "gone:1b", "qwen2.5:14b"])
        #expect(meta["llama3.1:8b"]?.contextLength == 131072)
        #expect(meta["qwen2.5:14b"]?.contextLength == 32768)
        // The error body correlates to gone:1b positionally: no context,
        // no vision signal — never misattributed to a neighbor.
        #expect(meta["gone:1b"]?.contextLength == nil)
        #expect(meta["gone:1b"]?.visionCapability == .unknown)
    }

    @Test func segmentCountMismatchDiscardsTheWholeBatch() {
        // Misattribution safety: an aborted batch (or an injection
        // attempt inflating the separator count) must degrade to
        // "unknown" for EVERY model — never shift contexts onto the
        // wrong names.
        let short = Self.rsJoined([Self.ollamaShowLlamaJSON])
        #expect(LocalModelEnumerator.parseShowBatch(short, probedNames: ["a", "b"]).isEmpty)
        var inflated = Self.rsJoined([Self.ollamaShowLlamaJSON, Self.ollamaShowQwenJSON])
        inflated.append(LocalModelEnumerator.showRecordSeparator) // stray extra RS
        #expect(LocalModelEnumerator.parseShowBatch(inflated, probedNames: ["a", "b"]).isEmpty)
        #expect(LocalModelEnumerator.parseShowBatch(Data(), probedNames: ["a"]).isEmpty)
    }

    // MARK: - Context enumeration end-to-end (transport seam)

    /// Tags listing for the context tests — one model above the Hermes
    /// floor, one below.
    static let ollamaTwoModelTagsJSON = Data("""
    {"models":[{"name":"llama3.1:8b","size":4920753328},
               {"name":"qwen2.5:14b","size":8988124069}]}
    """.utf8)

    @Test func ollamaListingCarriesContextsFromOneBatchedShowCall() throws {
        let showBatch = Self.rsJoined([Self.ollamaShowLlamaJSON, Self.ollamaShowQwenJSON])
        let transport = RecordingTransport(results: [
            .success(ProcessResult(exitCode: 0, stdout: Self.ollamaTwoModelTagsJSON, stderr: Data())),
            .success(ProcessResult(exitCode: 0, stdout: showBatch, stderr: Data())),
        ])
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("ollama"), baseURL: nil, transport: transport
        )
        guard case .models(let models) = outcome else {
            Issue.record("expected .models, got \(outcome)")
            return
        }
        #expect(models.map(\.contextLength) == [131072, 32768])
        // Exactly TWO transport round-trips: /api/tags, then ONE batched
        // /api/show — never one call per model.
        #expect(transport.calls.count == 2)
        let batchCall = try #require(transport.calls.last)
        #expect(batchCall.args.last == "http://127.0.0.1:11434/api/show")
        #expect(batchCall.args.contains("--next"))
        #expect(batchCall.args.contains(#"{"model":"llama3.1:8b"}"#))
        #expect(batchCall.args.contains(#"{"model":"qwen2.5:14b"}"#))
    }

    @Test func hostileTagFromTheDaemonIsListedButNeverProbed() throws {
        // Even the daemon's own /api/tags payload is untrusted: a
        // hostile name is still LISTED (the user may need to see it)
        // but excluded from the show batch, context unknown.
        let tags = Data(#"{"models":[{"name":"evil$(touch /tmp/pwned):latest"},{"name":"good:8b"}]}"#.utf8)
        let show = Self.rsJoined([Self.ollamaShowLlamaJSON])
        let transport = RecordingTransport(results: [
            .success(ProcessResult(exitCode: 0, stdout: tags, stderr: Data())),
            .success(ProcessResult(exitCode: 0, stdout: show, stderr: Data())),
        ])
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("ollama"), baseURL: nil, transport: transport
        )
        guard case .models(let models) = outcome else {
            Issue.record("expected .models, got \(outcome)")
            return
        }
        #expect(models.map(\.modelID) == ["evil$(touch /tmp/pwned):latest", "good:8b"])
        #expect(models.map(\.contextLength) == [nil, 131072])
        let batchCall = try #require(transport.calls.last)
        #expect(!batchCall.args.contains { $0.contains("pwned") })
    }

    @Test func showBatchFailureDegradesToUnknownContextsNotAnError() {
        // A dead second call must never break the listing itself.
        let transport = RecordingTransport(results: [
            .success(ProcessResult(exitCode: 0, stdout: Self.ollamaTwoModelTagsJSON, stderr: Data())),
            .failure(TransportError.other(message: "connection reset")),
        ])
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("ollama"), baseURL: nil, transport: transport
        )
        guard case .models(let models) = outcome else {
            Issue.record("expected .models, got \(outcome)")
            return
        }
        #expect(models.map(\.modelID) == ["llama3.1:8b", "qwen2.5:14b"])
        #expect(models.allSatisfy { $0.contextLength == nil })
    }

    @Test func openAICompatibleListingsNeverFakeAContext() {
        // /v1/models carries no context metadata — exactly ONE transport
        // call, every context nil (unknown), no invented numbers.
        let transport = RecordingTransport(result: ProcessResult(
            exitCode: 0, stdout: Self.openAIModelsJSON, stderr: Data()
        ))
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("lmstudio"), baseURL: nil, transport: transport
        )
        guard case .models(let models) = outcome else {
            Issue.record("expected .models, got \(outcome)")
            return
        }
        #expect(models.allSatisfy { $0.contextLength == nil })
        // No capability metadata on the OpenAI-compat shape → all unknown.
        #expect(models.allSatisfy { $0.visionCapability == .unknown })
        #expect(transport.calls.count == 1)
    }

    // MARK: - Vision capability end-to-end + single-model probe

    /// A show batch mixing all three vision states: a vision model, a
    /// text-only model (capabilities without "vision"), and a pre-0.29
    /// model whose response omits `capabilities` entirely.
    static let ollamaShowVisionJSON = Data("""
    {"model_info":{"general.architecture":"mllama","mllama.context_length":131072},
     "capabilities":["completion","vision"]}
    """.utf8)

    @Test func ollamaListingCarriesVisionCapabilityFromTheSameShowCall() {
        let tags = Data("""
        {"models":[{"name":"llama3.2-vision:11b"},{"name":"qwen2.5:14b"},{"name":"llama3.1:8b"}]}
        """.utf8)
        let showBatch = Self.rsJoined([
            Self.ollamaShowVisionJSON,  // vision → .yes
            Self.ollamaShowQwenJSON,    // capabilities, no vision → .no
            Self.ollamaShowLlamaJSON,   // no capabilities key → .unknown
        ])
        let transport = RecordingTransport(results: [
            .success(ProcessResult(exitCode: 0, stdout: tags, stderr: Data())),
            .success(ProcessResult(exitCode: 0, stdout: showBatch, stderr: Data())),
        ])
        let outcome = LocalModelEnumerator.listModels(
            for: Self.descriptor("ollama"), baseURL: nil, transport: transport
        )
        guard case .models(let models) = outcome else {
            Issue.record("expected .models, got \(outcome)")
            return
        }
        #expect(models.map(\.visionCapability) == [.yes, .no, .unknown])
        // Still exactly TWO round-trips — vision rides the existing batch.
        #expect(transport.calls.count == 2)
    }

    @Test func singleVisionProbeReturnsConfidentVerdictHitsShowAndCaches() throws {
        let transport = RecordingTransport(result: ProcessResult(
            exitCode: 0,
            stdout: Data(#"{"capabilities":["completion","vision"]}"#.utf8),
            stderr: Data()
        ))
        let cap = LocalModelEnumerator.ollamaVisionCapability(
            modelID: "vprobe-yes:1b",
            baseURL: "http://127.0.0.1:11434/v1",  // /v1 must be stripped for /api/show
            descriptorDefault: nil,
            transport: transport
        )
        #expect(cap == .yes)
        #expect(transport.calls.count == 1)
        let call = try #require(transport.calls.first)
        #expect(call.args.last == "http://127.0.0.1:11434/api/show")
        #expect(call.args.contains(#"{"model":"vprobe-yes:1b"}"#))
        // Single probe: no batching, no -f (an HTTP error must parse to a body).
        #expect(!call.args.contains("--next"))
        #expect(!call.args.contains("-f"))
        // Confident answers memoize — a second call must NOT touch transport.
        let poisoned = RecordingTransport(error: TransportError.other(message: "must not be called"))
        let cached = LocalModelEnumerator.ollamaVisionCapability(
            modelID: "vprobe-yes:1b",
            baseURL: "http://127.0.0.1:11434/v1",
            descriptorDefault: nil,
            transport: poisoned
        )
        #expect(cached == .yes)
        #expect(poisoned.calls.isEmpty)
    }

    @Test func singleVisionProbeConfidentNoForTextOnlyLocalModel() {
        // The bug this task fixes: llama3.1:8b-shape response, confident .no.
        let transport = RecordingTransport(result: ProcessResult(
            exitCode: 0,
            stdout: Data(#"{"capabilities":["completion","tools"]}"#.utf8),
            stderr: Data()
        ))
        let cap = LocalModelEnumerator.ollamaVisionCapability(
            modelID: "vprobe-no:8b", baseURL: nil,
            descriptorDefault: "http://127.0.0.1:11434/v1", transport: transport
        )
        #expect(cap == .no)
    }

    @Test func singleVisionProbeStaysUnknownForOldDaemonAndIsNotCached() {
        // Pre-0.29 daemon: no `capabilities` → .unknown (no false warning).
        // Unknown is NOT cached, so a later daemon upgrade re-probes: the
        // second call (now reporting vision) must be honored, not stuck.
        let stale = RecordingTransport(result: ProcessResult(
            exitCode: 0, stdout: Data(#"{"model_info":{"general.architecture":"llama"}}"#.utf8), stderr: Data()
        ))
        let first = LocalModelEnumerator.ollamaVisionCapability(
            modelID: "vprobe-upgrade:8b", baseURL: "http://127.0.0.1:11434/v1",
            descriptorDefault: nil, transport: stale
        )
        #expect(first == .unknown)
        let upgraded = RecordingTransport(result: ProcessResult(
            exitCode: 0, stdout: Data(#"{"capabilities":["completion","vision"]}"#.utf8), stderr: Data()
        ))
        let second = LocalModelEnumerator.ollamaVisionCapability(
            modelID: "vprobe-upgrade:8b", baseURL: "http://127.0.0.1:11434/v1",
            descriptorDefault: nil, transport: upgraded
        )
        #expect(second == .yes)
        #expect(upgraded.calls.count == 1)  // re-probed, not served from cache
    }

    @Test func singleVisionProbeIsUnknownOnTransportFailureOrBadName() {
        // Daemon down → .unknown, never a warn.
        let dead = RecordingTransport(error: TransportError.other(message: "connection refused"))
        #expect(LocalModelEnumerator.ollamaVisionCapability(
            modelID: "whatever:8b", baseURL: "http://127.0.0.1:11434/v1",
            descriptorDefault: nil, transport: dead
        ) == .unknown)
        // Hostile/invalid model name is never probed (injection gate).
        let unused = RecordingTransport(result: ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()))
        #expect(LocalModelEnumerator.ollamaVisionCapability(
            modelID: "evil$(reboot):latest", baseURL: "http://127.0.0.1:11434/v1",
            descriptorDefault: nil, transport: unused
        ) == .unknown)
        #expect(unused.calls.isEmpty)
    }

    /// The end-to-end intent of t-d25e68cc: the enumerator's local vision
    /// verdict, fed into the composer's pure hint decision, warns exactly
    /// when a local model is CONFIRMED non-vision — and stays silent for an
    /// old daemon that can't report capabilities (the no-false-warning
    /// invariant that kept t-31img silent for local models before this).
    @Test func localVisionVerdictDrivesTheComposerHint() {
        // Confirmed text-only Ollama model (llama3.1:8b shape) → warn.
        let textOnly = LocalModelEnumerator.ollamaVisionCapability(
            modelID: "vprobe-compose-no:8b", baseURL: "http://127.0.0.1:11434/v1",
            descriptorDefault: nil,
            transport: RecordingTransport(result: ProcessResult(
                exitCode: 0, stdout: Data(#"{"capabilities":["completion","tools"]}"#.utf8), stderr: Data()))
        )
        #expect(textOnly == .no)
        #expect(RichChatViewModel.shouldShowNonVisionImageHint(attachmentCount: 1, capability: textOnly))
        // Pre-0.29 daemon → unknown → NO warn (no false positive).
        let oldDaemon = LocalModelEnumerator.ollamaVisionCapability(
            modelID: "vprobe-compose-unknown:8b", baseURL: "http://127.0.0.1:11434/v1",
            descriptorDefault: nil,
            transport: RecordingTransport(result: ProcessResult(
                exitCode: 0, stdout: Data(#"{"model_info":{}}"#.utf8), stderr: Data()))
        )
        #expect(oldDaemon == .unknown)
        #expect(!RichChatViewModel.shouldShowNonVisionImageHint(attachmentCount: 1, capability: oldDaemon))
    }

    // MARK: - Context floor gate (pure)

    @Test func verdictGatesOnTheHermesMinimum() {
        #expect(LocalModelContextGate.hermesMinimumContextTokens == 64_000)
        #expect(LocalModelContextGate.verdict(contextLength: 131_072) == .allowed)
        #expect(LocalModelContextGate.verdict(contextLength: 64_000) == .allowed)
        #expect(LocalModelContextGate.verdict(contextLength: 63_999) == .blocked)
        #expect(LocalModelContextGate.verdict(contextLength: 32_768) == .blocked)
        #expect(LocalModelContextGate.verdict(contextLength: 8_192) == .blocked)
        // Unknown is permissive — Hermes's own preflight is the
        // backstop; blocking on ignorance would strand every
        // OpenAI-compatible endpoint.
        #expect(LocalModelContextGate.verdict(contextLength: nil) == .unknown)
        #expect(LocalModelContextGate.verdict(contextLength: 0) == .unknown)
        #expect(LocalModelContextGate.verdict(contextLength: -1) == .unknown)
    }

    @Test func compactTokensMatchesTheCatalogConvention() {
        // Same convention as HermesModelInfo.contextDisplay (decimal K/M).
        #expect(LocalModelContextGate.compactTokens(32_768) == "32K")
        #expect(LocalModelContextGate.compactTokens(131_072) == "131K")
        #expect(LocalModelContextGate.compactTokens(8_192) == "8K")
        #expect(LocalModelContextGate.compactTokens(64_000) == "64K")
        #expect(LocalModelContextGate.compactTokens(1_048_576) == "1M")
        #expect(LocalModelContextGate.compactTokens(500) == "500")
    }
}

// MARK: - Recording fake transport

/// Minimal `ServerTransport` double for the runProcess seam — records
/// every call and replays canned `ProcessResult`s (or throws). The
/// scripted form replays results in call order (tags probe, then the
/// batched /api/show), sticking on the last entry if over-called. Same
/// pattern as M5's `ScriptedTransport`; file I/O is deliberately N/A.
private final class RecordingTransport: ServerTransport, @unchecked Sendable {
    struct Call {
        let executable: String
        let args: [String]
        let timeout: TimeInterval?
    }

    let contextID: ServerID = UUID()
    let isRemote: Bool
    private let script: [Result<ProcessResult, Error>]
    private(set) var calls: [Call] = []

    init(results: [Result<ProcessResult, Error>], isRemote: Bool = true) {
        precondition(!results.isEmpty)
        self.script = results
        self.isRemote = isRemote
    }

    convenience init(result: ProcessResult, isRemote: Bool = true) {
        self.init(results: [.success(result)], isRemote: isRemote)
    }

    convenience init(error: Error, isRemote: Bool = true) {
        self.init(results: [.failure(error)], isRemote: isRemote)
    }

    func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
        calls.append(Call(executable: executable, args: args, timeout: timeout))
        return try script[min(calls.count - 1, script.count - 1)].get()
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
