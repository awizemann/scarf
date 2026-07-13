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

    public init(modelID: String, name: String, detail: String? = nil) {
        self.modelID = modelID
        self.name = name
        self.detail = detail
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
        guard let models = parsed else {
            let head = String(result.stdoutString.prefix(200))
            #if canImport(os)
            logger.info("probe parse failure for \(descriptor.providerID, privacy: .public)")
            #endif
            return .parseFailure(detail: head)
        }
        return models.isEmpty ? .reachableEmpty : .models(models)
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
