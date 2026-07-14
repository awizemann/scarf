import Foundation
#if canImport(os)
import os
#endif

/// One model actually installed/loaded on a local inference server —
/// a row in the model picker's "Local" section (T3).
public struct LocalModelInfo: Sendable, Identifiable, Hashable {
    /// The exact string the UI writes to `model.default` — an Ollama tag
    /// (`llama3:8b`) or an OpenAI-compatible model id, verbatim.
    public var id: String { modelID }
    public let modelID: String
    /// Display name; today always the id verbatim (both endpoint shapes
    /// use the id as the human name).
    public let name: String
    /// Optional one-line human subtitle for the picker row — parameter
    /// size / quantization / on-disk size where the endpoint reports
    /// them ("8B · Q4_K_M · 4.6 GB"). Nil when the endpoint has nothing
    /// beyond the id (the OpenAI `/v1/models` shape).
    public let detail: String?
    /// Model's context window in tokens, where the server reports one.
    /// Ollama: the `<arch>.context_length` GGUF metadata from
    /// `POST /api/show` (the model's REAL serving ceiling — Ollama loads
    /// at this value, and Hermes's runtime check measures it). OpenAI
    /// `/v1/models` carries no context metadata → nil, never a fake
    /// number. Nil means UNKNOWN, not unlimited — the picker renders
    /// "context unknown" and stays permissive.
    public let contextLength: Int?
    /// Whether this model can natively see images, from the `capabilities`
    /// array in Ollama's `POST /api/show` response (`["completion",
    /// "tools","vision"]` on Ollama ≥ 0.29 — verified live against 0.31.2).
    /// `.yes` when the array lists `"vision"`, `.no` when the array is
    /// present and omits it, `.unknown` when the daemon is too old to
    /// report `capabilities` at all (or on any parse/transport failure).
    /// Same three-state contract as `ModelCatalogService.VisionCapability`
    /// so the composer heads-up (t-31img) can fall back to this signal for
    /// local models that models.dev never mirrors. OpenAI-compatible
    /// listings carry no capability metadata → always `.unknown`.
    public let visionCapability: ModelCatalogService.VisionCapability

    public init(
        modelID: String,
        name: String,
        detail: String? = nil,
        contextLength: Int? = nil,
        visionCapability: ModelCatalogService.VisionCapability = .unknown
    ) {
        self.modelID = modelID
        self.name = name
        self.detail = detail
        self.contextLength = contextLength
        self.visionCapability = visionCapability
    }
}

/// The two per-model signals one `POST /api/show` response carries that the
/// picker and composer consume: the GGUF context ceiling and native vision
/// support. Bundled so the batched probe parses each segment once.
public struct OllamaShowMetadata: Sendable, Equatable {
    public let contextLength: Int?
    public let visionCapability: ModelCatalogService.VisionCapability

    public init(contextLength: Int?, visionCapability: ModelCatalogService.VisionCapability) {
        self.contextLength = contextLength
        self.visionCapability = visionCapability
    }
}

/// Pure Hermes context-window floor gate for the picker's Local section.
///
/// Hermes hard-requires `MINIMUM_CONTEXT_LENGTH = 64_000` tokens
/// (agent/model_metadata.py:185, v0.17.0) — enforced at session/new AND
/// session/set_model (both reject with ACP -32603), and AGAIN at runtime
/// against what the server actually loaded (`ollama_runtime_context_too_
/// small`, agent/conversation_loop.py:927-933). Dogfood round 2 proved
/// the `model.context_length` override is a TRAP for models whose real
/// GGUF ceiling is below the floor: preflight passes, the runtime check
/// halts the turn instead of answering. So a model with a KNOWN context
/// below the floor is effectively unusable — the picker must block it,
/// not warn.
public enum LocalModelContextGate {
    /// Hermes's hard minimum (model_metadata.py MINIMUM_CONTEXT_LENGTH).
    public static let hermesMinimumContextTokens = 64_000

    /// Picker verdict for one model's (possibly unknown) context window.
    public enum Verdict: Sendable, Equatable {
        /// Known context at or above the floor — selectable.
        case allowed
        /// Known context below the floor — blocked (the override path is
        /// a runtime trap, see the type comment).
        case blocked
        /// No context metadata — selectable; Hermes's own preflight is
        /// the backstop. Blocking on ignorance would strand every
        /// OpenAI-compatible endpoint (their listing has no context).
        case unknown
    }

    public static func verdict(contextLength: Int?) -> Verdict {
        guard let ctx = contextLength, ctx > 0 else { return .unknown }
        return ctx >= hermesMinimumContextTokens ? .allowed : .blocked
    }

    /// Compact token count for row subtitles — same convention as the
    /// remote catalog's `HermesModelInfo.contextDisplay` (decimal
    /// thousands: 32768 → "32K", 131072 → "131K", 1_000_000 → "1M").
    public static func compactTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M" }
        if tokens >= 1_000 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }
}

/// Distinguishable outcomes of one enumeration probe, so T3 can render
/// "Ollama isn't running on \<server\>" vs "No models installed (run
/// `ollama pull …`)" instead of collapsing everything into an empty list.
public enum LocalModelListing: Sendable, Equatable {
    /// Server reachable and reported at least one model.
    case models([LocalModelInfo])
    /// Server reachable, valid response, zero models installed/loaded.
    case reachableEmpty
    /// The probe never got a valid HTTP response: daemon down, host
    /// unreachable, HTTP error status (`curl -f`), or `curl` missing on
    /// the host. `detail` carries curl's stderr / the transport error
    /// for logging — not user-facing copy.
    case unreachable(detail: String)
    /// Got response bytes but they don't parse as the expected JSON
    /// shape (wrong service on that port, HTML error page, …).
    case parseFailure(detail: String)
    /// No usable base URL: none supplied, descriptor has no default, or
    /// the value failed the strict scheme://host[:port][/path] check
    /// (which is also the shell-injection gate — see
    /// `LocalModelEnumerator.validatedBaseURL`).
    case invalidBaseURL
    /// The descriptor's `enumerationHint` is `.none` — free-form model
    /// entry only, nothing to probe.
    case notEnumerable
}

/// Lists the models actually installed/loaded on the HERMES HOST for a
/// local provider descriptor — Ollama via `GET <host>/api/tags`, every
/// OpenAI-compatible server (LM Studio, vLLM, llama.cpp, custom) via
/// `GET <base>/v1/models`.
///
/// **All probes run on the host the window is bound to**, via
/// `curl` through the context's `ServerTransport` (the same pattern
/// `HermesConfigReader` uses) — never a local `URLSession`. A remote
/// server's Ollama is only reachable from that server: its base URL is
/// `127.0.0.1` *as seen from the host*.
///
/// Parsing is pure and separated from transport I/O
/// (`parseOllamaTags` / `parseOpenAIModels`) so tests need no network.
///
/// **Security.** The base URL is user-influenced and — on SSH transports —
/// ends up inside a remote shell command. Defense in depth:
/// 1. `validatedBaseURL` rejects anything outside a strict
///    scheme://host[:port][/path] character allowlist (no `$`, backticks,
///    quotes, spaces, parens, `;`, `&`, `|`), so `$(…)` never reaches a
///    transport at all.
/// 2. The URL travels as its own argv element through
///    `transport.runProcess`, whose SSH implementation escapes `$`,
///    backticks, and quotes per-argument (`SSHTransport.remotePathArg`);
///    the local implementation spawns argv directly with no shell.
public enum LocalModelEnumerator {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "LocalModelEnumerator")
    #endif

    /// curl's own budget per probe. Short so the picker never hangs on a
    /// down daemon; the transport-level timeout below is a superset that
    /// also covers SSH connection setup.
    static let curlMaxTimeSeconds = 3
    static let transportTimeoutSeconds: TimeInterval = 10

    // MARK: - Entry point

    /// Probe the host the context is bound to and list the models its
    /// local inference server actually serves. Blocking transport I/O
    /// runs on a detached task — safe to call from the MainActor (same
    /// rationale as `ModelCatalogService.loadModelsAsync`, issue #59).
    ///
    /// - Parameters:
    ///   - descriptor: which local provider to probe (`enumerationHint`
    ///     picks the endpoint shape).
    ///   - baseURL: the user's explicit base URL, if any. Wins over the
    ///     descriptor's `defaultBaseURL`; blank/nil falls back to it.
    ///   - context: the server the window is bound to. All I/O goes
    ///     through its transport, so remote hosts probe *their own*
    ///     loopback, not this Mac's.
    public static func listModels(
        for descriptor: LocalModelProvider,
        baseURL: String?,
        context: ServerContext
    ) async -> LocalModelListing {
        await Task.detached {
            listModels(for: descriptor, baseURL: baseURL, transport: context.makeTransport())
        }.value
    }

    /// Synchronous core, split out so tests can inject a fake transport.
    /// Does blocking transport I/O — call off the MainActor.
    static func listModels(
        for descriptor: LocalModelProvider,
        baseURL: String?,
        transport: any ServerTransport
    ) -> LocalModelListing {
        guard descriptor.enumerationHint != .none else { return .notEnumerable }
        guard let endpoint = endpointURL(
            for: descriptor.enumerationHint,
            baseURL: baseURL,
            descriptorDefault: descriptor.defaultBaseURL
        ) else {
            return .invalidBaseURL
        }

        let result: ProcessResult
        do {
            result = try transport.runProcess(
                executable: curlExecutable(isRemote: transport.isRemote),
                // -s: no progress noise. -S: still print the error line
                // on failure so `unreachable` carries a reason. -f: HTTP
                // >= 400 becomes exit 22 instead of parse garbage.
                args: ["-sSf", "--max-time", "\(curlMaxTimeSeconds)", endpoint],
                stdin: nil,
                timeout: transportTimeoutSeconds
            )
        } catch {
            #if canImport(os)
            logger.info("probe transport error for \(descriptor.providerID, privacy: .public): \(String(describing: error), privacy: .public)")
            #endif
            return .unreachable(detail: String(describing: error))
        }

        guard result.exitCode == 0 else {
            // Daemon down (curl exit 7/28), HTTP error (-f → 22), or
            // curl missing on the host (shell exit 127 / spawn failure).
            let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "curl exited \(result.exitCode)" : stderr
            #if canImport(os)
            logger.info("probe unreachable for \(descriptor.providerID, privacy: .public): \(detail, privacy: .public)")
            #endif
            return .unreachable(detail: detail)
        }

        let parsed: [LocalModelInfo]?
        switch descriptor.enumerationHint {
        case .ollamaTags: parsed = parseOllamaTags(result.stdout)
        case .openAIModels: parsed = parseOpenAIModels(result.stdout)
        case .none: return .notEnumerable // unreachable; guarded above
        }
        guard var models = parsed else {
            let head = String(result.stdoutString.prefix(200))
            #if canImport(os)
            logger.info("probe parse failure for \(descriptor.providerID, privacy: .public)")
            #endif
            return .parseFailure(detail: head)
        }
        // Ollama can report each model's REAL context window (its GGUF
        // metadata ceiling) AND its native vision support via /api/show —
        // one extra batched probe so the picker can gate the Hermes 64K
        // floor before selection and badge vision-capable models. OpenAI-
        // compatible listings carry neither: those models keep
        // contextLength nil and visionCapability .unknown, never faked.
        if descriptor.enumerationHint == .ollamaTags, !models.isEmpty {
            let metadata = fetchOllamaShowMetadata(
                modelNames: models.map(\.modelID),
                probedTagsEndpoint: endpoint,
                transport: transport
            )
            if !metadata.isEmpty {
                models = models.map {
                    LocalModelInfo(
                        modelID: $0.modelID,
                        name: $0.name,
                        detail: $0.detail,
                        contextLength: metadata[$0.modelID]?.contextLength,
                        visionCapability: metadata[$0.modelID]?.visionCapability ?? .unknown
                    )
                }
            }
        }
        return models.isEmpty ? .reachableEmpty : .models(models)
    }

    // MARK: - Ollama context windows (batched /api/show)

    /// One `POST /api/show {"model":"<name>"}` per model, but batched
    /// into a SINGLE curl process (curl's `--next` per-URL option
    /// segments) → a single transport invocation. **Why batch, why this
    /// shape:** each transport call is a full round-trip (SSH connection
    /// reuse notwithstanding), so per-row lazy fetches would make the
    /// picker's gate verdicts pop in one by one; and unlike an `sh -c`
    /// loop, `--next` keeps every model name a plain argv element — no
    /// shell command string is ever built from daemon-supplied data, the
    /// exact same discipline the tags probe pins (`urlTravelsAsItsOwn
    /// ArgvElement`). Defense in depth on top: names that fail
    /// `validatedOllamaModelName`'s character allowlist are simply not
    /// probed (context stays nil → "context unknown", still listed).
    ///
    /// Response correlation uses an ASCII Record Separator (0x1E) written
    /// after EVERY transfer (`-w`, emitted for failed transfers too —
    /// verified live, and `-f` is deliberately absent so an HTTP error
    /// yields a JSON error body + separator instead of aborting): 0x1E
    /// cannot appear in valid JSON output (control chars must be escaped)
    /// nor in an allowlisted model name echoed back in an error message,
    /// so segment count == probe count or the whole batch is discarded —
    /// contexts degrade to unknown, never misattribute.
    ///
    /// Best-effort by design: ANY failure (transport error, segment
    /// mismatch, malformed JSON) returns partial/empty metadata and the
    /// listing itself is untouched.
    static func fetchOllamaShowMetadata(
        modelNames: [String],
        probedTagsEndpoint: String,
        transport: any ServerTransport
    ) -> [String: OllamaShowMetadata] {
        // /api/tags → /api/show on the same validated base.
        guard probedTagsEndpoint.hasSuffix("/api/tags") else { return [:] }
        let showEndpoint = String(probedTagsEndpoint.dropLast("/api/tags".count)) + "/api/show"
        guard let batch = showBatchArguments(showEndpoint: showEndpoint, modelNames: modelNames) else {
            return [:]
        }
        let result: ProcessResult
        do {
            result = try transport.runProcess(
                executable: curlExecutable(isRemote: transport.isRemote),
                args: batch.args,
                stdin: nil,
                // The batch is N sequential same-host transfers, each
                // under curl's own --max-time; pad the transport budget
                // accordingly (a hung daemon still can't exceed it).
                timeout: min(30, transportTimeoutSeconds + TimeInterval(batch.probedNames.count))
            )
        } catch {
            #if canImport(os)
            logger.info("show batch transport error: \(String(describing: error), privacy: .public)")
            #endif
            return [:]
        }
        // Exit code deliberately ignored: without -f a mid-batch network
        // death still leaves N' well-formed segments — the count guard
        // in parseShowBatch decides whether they're trustworthy.
        return parseShowBatch(result.stdout, probedNames: batch.probedNames)
    }

    // MARK: - Single active-model vision probe (composer heads-up)

    /// Native vision support for ONE Ollama model — the cheap path the
    /// composer heads-up (t-31img) takes for a local model that models.dev
    /// never mirrors. The picker's batched enumeration is the wrong seam:
    /// the heads-up fires whenever an image is attached, with no picker
    /// open, so this issues a SINGLE `POST /api/show` for just the active
    /// model and memoizes the answer per (show-endpoint, model).
    ///
    /// Only confident verdicts (`.yes`/`.no`) are cached: a `.unknown` from
    /// a momentarily-down daemon must re-probe once the daemon is back,
    /// whereas capability for a fixed model never flips within a run. The
    /// refresh only runs when an attachment appears (not per keystroke), so
    /// the re-probe cost on `.unknown` is a single call, not a hot loop.
    ///
    /// `baseURL` is the configured `model.base_url` (with its `/v1` suffix);
    /// `descriptorDefault` is Ollama's default endpoint, used when the
    /// config carries no explicit base. Returns `.unknown` on any failure
    /// — the invariant the composer relies on to stay silent.
    public static func ollamaVisionCapability(
        modelID: String,
        baseURL: String?,
        descriptorDefault: String?,
        transport: any ServerTransport
    ) -> ModelCatalogService.VisionCapability {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validatedOllamaModelName(model) else { return .unknown }
        guard let tagsEndpoint = endpointURL(
            for: .ollamaTags, baseURL: baseURL, descriptorDefault: descriptorDefault
        ), tagsEndpoint.hasSuffix("/api/tags") else { return .unknown }
        let showEndpoint = String(tagsEndpoint.dropLast("/api/tags".count)) + "/api/show"

        let cacheKey = "\(showEndpoint)|\(model)"
        visionCacheLock.lock()
        let cached = visionCache[cacheKey]
        visionCacheLock.unlock()
        if let cached { return cached }

        let result: ProcessResult
        do {
            result = try transport.runProcess(
                executable: curlExecutable(isRemote: transport.isRemote),
                // Same discipline as the batch: model name is a plain argv
                // element inside a `-d` body, the allowlist above guarantees
                // it needs no JSON escaping, and no `-f` so an HTTP error
                // still returns a parseable body (→ .unknown, never a warn).
                args: [
                    "-sS", "--max-time", "\(curlMaxTimeSeconds)",
                    "-d", "{\"model\":\"\(model)\"}",
                    showEndpoint,
                ],
                stdin: nil,
                timeout: transportTimeoutSeconds
            )
        } catch {
            #if canImport(os)
            logger.info("vision probe transport error: \(String(describing: error), privacy: .public)")
            #endif
            return .unknown
        }
        guard result.exitCode == 0 else { return .unknown }
        let capability = parseOllamaShowVision(result.stdout)
        // Cache only confident answers (see the doc comment).
        if capability != .unknown {
            visionCacheLock.lock()
            visionCache[cacheKey] = capability
            visionCacheLock.unlock()
        }
        return capability
    }

    /// Memoized single-model vision verdicts, keyed (show-endpoint, model).
    /// `nonisolated(unsafe)` + lock matches the `ModelCatalogService`
    /// vision-cache pattern under the package's Swift 5 language mode.
    private static let visionCacheLock = NSLock()
    nonisolated(unsafe) private static var visionCache: [String: ModelCatalogService.VisionCapability] = [:]

    /// ASCII Record Separator — the per-transfer `-w` marker. Cannot
    /// occur in valid JSON output (control characters must be escaped in
    /// JSON strings) or in an allowlisted model name, so splitting on it
    /// is injection-proof.
    static let showRecordSeparator: UInt8 = 0x1E

    /// Pure argv builder for the batched /api/show probe. Returns nil
    /// when no model name survives the allowlist. `probedNames` is the
    /// allowlist-surviving subset IN ORDER — the correlation key for
    /// `parseShowBatch`.
    ///
    /// Every flag is repeated per `--next` segment: curl resets
    /// non-global options at each --next boundary, and repeating the
    /// global ones (`-s`) is harmless.
    static func showBatchArguments(
        showEndpoint: String,
        modelNames: [String]
    ) -> (args: [String], probedNames: [String])? {
        let names = modelNames.filter(validatedOllamaModelName)
        guard !names.isEmpty else { return nil }
        var args: [String] = []
        for (i, name) in names.enumerated() {
            if i > 0 { args.append("--next") }
            args += [
                "-sS",
                "--max-time", "\(curlMaxTimeSeconds)",
                // The allowlist guarantees the name needs no JSON
                // escaping (no quotes/backslashes/control chars), so the
                // interpolation below is exact.
                "-d", "{\"model\":\"\(name)\"}",
                "-w", String(UnicodeScalar(showRecordSeparator)),
                showEndpoint,
            ]
        }
        return (args, names)
    }

    /// Character allowlist for an Ollama model name that will travel
    /// toward a transport (same discipline as `validatedBaseURL`).
    /// Covers every legal Ollama reference shape — `llama3.1:8b`,
    /// `hf.co/user/repo:Q4_K_M`, digest pins (`name@sha256:…`) — and
    /// nothing any shell or JSON encoder treats as active. Names come
    /// from the daemon's own /api/tags response but are treated as
    /// untrusted anyway; a failing name is skipped, not sanitized.
    static func validatedOllamaModelName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 256 else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_:/@")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Split the batch output on the record separator and pair segments
    /// with `probedNames` positionally. A count mismatch (mid-batch
    /// abort, or a hostile injection attempt inflating the count)
    /// discards the WHOLE batch — degrading to unknown is always safe,
    /// misattributing a context to the wrong model never is.
    static func parseShowBatch(_ data: Data, probedNames: [String]) -> [String: OllamaShowMetadata] {
        var segments = data.split(separator: showRecordSeparator, omittingEmptySubsequences: false)
        // The final separator leaves one trailing empty segment.
        if segments.last?.isEmpty == true { segments.removeLast() }
        guard segments.count == probedNames.count else { return [:] }
        var metadata: [String: OllamaShowMetadata] = [:]
        for (segment, name) in zip(segments, probedNames) {
            let bytes = Data(segment)
            metadata[name] = OllamaShowMetadata(
                contextLength: parseOllamaShowContext(bytes),
                visionCapability: parseOllamaShowVision(bytes)
            )
        }
        return metadata
    }

    /// Native vision support from one `POST /api/show` response's top-level
    /// `capabilities` array (Ollama ≥ 0.29: `["completion","tools","vision"]`
    /// — verified live against 0.31.2, which lists `vision` only for
    /// multimodal models like `llama3.2-vision`/`llava`). Three-state:
    /// `.yes` when the array is present and contains `"vision"`, `.no` when
    /// present and omits it, `.unknown` when the key is absent (daemon too
    /// old to report capabilities), non-array, or the body doesn't parse
    /// (error bodies, empty data). `.unknown` NEVER warns downstream — that
    /// preserves the no-false-warning invariant for pre-0.29 Ollama, LM
    /// Studio, and custom endpoints.
    static func parseOllamaShowVision(_ data: Data) -> ModelCatalogService.VisionCapability {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let caps = root["capabilities"] as? [Any] else { return .unknown }
        let strings = caps.compactMap { $0 as? String }
        return strings.contains("vision") ? .yes : .no
    }

    /// Extract the context window from one `POST /api/show` response:
    /// `model_info` carries a `<arch>.context_length` key
    /// (`{"general.architecture":"qwen2", "qwen2.context_length":32768}`
    /// — verified live against Ollama). Prefer the key named by
    /// `general.architecture`; fall back to the first (sorted) key with
    /// the `.context_length` suffix so unknown/future architectures
    /// still resolve. Nil for anything else — error bodies
    /// (`{"error":"model not found"}`), missing model_info, non-numeric
    /// or non-positive values.
    static func parseOllamaShowContext(_ data: Data) -> Int? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let info = root["model_info"] as? [String: Any] else { return nil }
        func positiveInt(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, !(n is Bool) else { return nil }
            let ctx = n.intValue
            return ctx > 0 ? ctx : nil
        }
        if let arch = info["general.architecture"] as? String,
           let ctx = positiveInt(info["\(arch).context_length"]) {
            return ctx
        }
        for key in info.keys.sorted() where key.hasSuffix(".context_length") {
            if let ctx = positiveInt(info[key]) { return ctx }
        }
        return nil
    }

    // MARK: - URL resolution (pure)

    /// Resolve the effective probe endpoint: explicit base URL if
    /// non-blank, else the descriptor's default; validate it; then map
    /// the hint onto its path. `/api/tags` is NOT under the `/v1`
    /// OpenAI-compat suffix that configured base URLs carry, so
    /// `.ollamaTags` strips a trailing `/v1` first. Nil means no usable
    /// URL (→ `.invalidBaseURL`).
    static func endpointURL(
        for hint: LocalModelProvider.EnumerationHint,
        baseURL: String?,
        descriptorDefault: String?
    ) -> String? {
        guard hint != .none else { return nil }
        let explicit = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = explicit.isEmpty ? (descriptorDefault ?? "") : explicit
        guard var base = validatedBaseURL(candidate) else { return nil }

        switch hint {
        case .ollamaTags:
            if base.lowercased().hasSuffix("/v1") {
                base = trimTrailingSlashes(String(base.dropLast(3)))
                // A URL that was ONLY the /v1 path (degenerate) still has
                // its host — validatedBaseURL guarantees scheme://host.
            }
            return base + "/api/tags"
        case .openAIModels:
            if base.lowercased().hasSuffix("/v1") {
                return base + "/models"
            }
            return base + "/v1/models"
        case .none:
            return nil
        }
    }

    /// Strict shape + character gate for a user-influenced base URL that
    /// will travel toward a shell. Accepts only
    /// `http(s)://host[:port][/path]` where every character is in a
    /// URL-safe allowlist — no `$`, backticks, quotes, whitespace,
    /// parens, `;`, `&`, `|`, no userinfo/query/fragment. Returns the
    /// trimmed URL with trailing slashes stripped, or nil.
    static func validatedBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Character allowlist FIRST: everything a scheme://host:port/path
        // legitimately needs (incl. IPv6 brackets + percent-escapes) and
        // nothing any shell treats as active.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_~:/%[]")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        // Then structural validation.
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil,
              comps.query == nil, comps.fragment == nil
        else { return nil }
        return trimTrailingSlashes(trimmed)
    }

    private static func trimTrailingSlashes(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// Remote transports run argv through the remote login shell, so a
    /// bare `curl` resolves via PATH; `LocalTransport` spawns the
    /// executable path directly (no PATH lookup), so use the absolute
    /// path every macOS ships.
    static func curlExecutable(isRemote: Bool) -> String {
        isRemote ? "curl" : "/usr/bin/curl"
    }

    // MARK: - Parsers (pure)

    /// Ollama `GET /api/tags` shape:
    /// `{"models":[{"name":"llama3:8b","size":…,"details":{"parameter_size":"8B","quantization_level":"Q4_K_M"},…}]}`
    /// Nil on malformed/off-shape JSON; `[]` when `models` is empty.
    static func parseOllamaTags(_ data: Data) -> [LocalModelInfo]? {
        struct Response: Decodable {
            struct Model: Decodable {
                struct Details: Decodable {
                    let parameter_size: String?
                    let quantization_level: String?
                }
                let name: String
                let size: Int64?
                let details: Details?
            }
            let models: [Model]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.models.map { m in
            var parts: [String] = []
            if let p = m.details?.parameter_size, !p.isEmpty { parts.append(p) }
            if let q = m.details?.quantization_level, !q.isEmpty { parts.append(q) }
            if let s = m.size, s > 0 { parts.append(formatBytes(s)) }
            return LocalModelInfo(
                modelID: m.name,
                name: m.name,
                detail: parts.isEmpty ? nil : parts.joined(separator: " · ")
            )
        }
    }

    /// OpenAI-compatible `GET /v1/models` shape:
    /// `{"data":[{"id":"…","object":"model",…}]}`
    /// Nil on malformed/off-shape JSON; `[]` when `data` is empty.
    /// No detail line — the shape carries nothing human beyond the id.
    static func parseOpenAIModels(_ data: Data) -> [LocalModelInfo]? {
        struct Response: Decodable {
            struct Model: Decodable {
                let id: String
            }
            let data: [Model]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.data.map { LocalModelInfo(modelID: $0.id, name: $0.id, detail: nil) }
    }

    /// Deterministic (locale-independent) byte formatting for the row
    /// subtitle — deliberately not `ByteCountFormatter`, whose output
    /// varies with locale and would make the detail strings untestable.
    static func formatBytes(_ bytes: Int64) -> String {
        let gb = 1_073_741_824.0
        let mb = 1_048_576.0
        let b = Double(bytes)
        if b >= gb { return String(format: "%.1f GB", b / gb) }
        if b >= mb { return String(format: "%.0f MB", b / mb) }
        return "\(bytes) B"
    }
}
