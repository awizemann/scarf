import Foundation
import ScarfCore

@Observable
final class MCPServerEditorViewModel {
    struct KeyValueRow: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    let context: ServerContext
    private let fileService: HermesFileService
    let server: HermesMCPServer

    var envDraft: [KeyValueRow]
    var headersDraft: [KeyValueRow]
    var includeDraft: String
    var excludeDraft: String
    var resourcesEnabled: Bool
    var promptsEnabled: Bool
    var timeoutDraft: String
    var connectTimeoutDraft: String
    /// v0.14 — supports_parallel_tool_calls toggle. Three states:
    /// nil = "use Hermes default" (no key written), true = opt in,
    /// false = opt out explicitly. Bound to a tri-state Picker in the
    /// editor under the v0.14 capability gate.
    var parallelToolCallsDraft: Bool?
    /// v0.15 — mTLS client-certificate config (HTTP / SSE only). Empty string
    /// means "key absent" (writer drops the scalar).
    var clientCertDraft: String
    var clientKeyDraft: String
    /// SSL-verify is one Hermes key (`ssl_verify`) holding a bool OR a
    /// CA-bundle path, but the UI splits it into two INDEPENDENT controls so
    /// toggling verification off can't clobber a typed CA path. `sslVerifyPeer`
    /// is the on/off toggle; `sslCAPathDraft` is the optional custom CA path
    /// (only meaningful when verify is on). They resolve to a single
    /// `ssl_verify` value at save (see `resolvedSSLVerify`).
    var sslVerifyPeer: Bool
    var sslCAPathDraft: String
    /// v0.20.4 — identity_header drafts (HTTP / SSE only). `identityHeaderEnabled`
    /// toggles the block on/off in the UI; the name/valueFrom/value drafts are
    /// only meaningful (and only written) while it's on.
    var identityHeaderEnabled: Bool
    var identityHeaderNameDraft: String
    var identityHeaderValueFromDraft: MCPIdentityHeader.ValueSource
    var identityHeaderValueDraft: String
    /// v0.20.4 — strict_redirect_headers (HTTP / SSE only). `nil` = key
    /// absent = Hermes default (`false`).
    var strictRedirectHeadersDraft: Bool?
    /// v0.21.1 — `oauth.flow`. Empty string means "leave the key absent",
    /// which is how Hermes's own default (browser) is expressed; the picker
    /// only ever offers "" / "browser" / "device".
    var oauthFlowDraft: String
    /// v0.20.4 — cwd (stdio only). Empty string = key absent.
    var cwdDraft: String
    var showSecrets: Bool = false
    var isSaving: Bool = false
    var saveError: String?

    init(server: HermesMCPServer, context: ServerContext = .local) {
        self.server = server
        self.context = context
        self.fileService = HermesFileService(context: context)
        self.envDraft = server.env.keys.sorted().map { KeyValueRow(key: $0, value: server.env[$0] ?? "") }
        self.headersDraft = server.headers.keys.sorted().map { KeyValueRow(key: $0, value: server.headers[$0] ?? "") }
        self.includeDraft = server.toolsInclude.joined(separator: ", ")
        self.excludeDraft = server.toolsExclude.joined(separator: ", ")
        self.resourcesEnabled = server.resourcesEnabled
        self.promptsEnabled = server.promptsEnabled
        self.timeoutDraft = server.timeout.map { String($0) } ?? ""
        self.connectTimeoutDraft = server.connectTimeout.map { String($0) } ?? ""
        self.parallelToolCallsDraft = server.supportsParallelToolCalls
        self.clientCertDraft = server.clientCert ?? ""
        self.clientKeyDraft = server.clientKey ?? ""
        // Hydrate the split SSL-verify controls from the single stored value.
        // The scalar is bool-OR-path, and the bool half is BOOLISH, not just
        // `false`: PyYAML resolves bare `no` / `off` to False and `0` is a
        // falsy int, all of which reach httpx as `verify=False`
        // (`tools/mcp_tool_transport.py:410` at v2026.9.7 passes
        // `config.get("ssl_verify", True)` straight through). Reading only
        // `"false"` rendered `ssl_verify: no` as "Verify TLS peer" ON with
        // `no` sitting in the CA-path field, and the next save quoted it into
        // a CA bundle literally named `no` — the exact downgrade the writer's
        // bare-bool rule exists to prevent.
        //   nil/empty      → verify on, no custom CA
        //   boolish false  → verify off
        //   boolish true   → verify on, no custom CA
        //   <path>         → verify on, custom CA bundle
        let storedVerify = (server.sslVerify ?? "").trimmingCharacters(in: .whitespaces)
        switch Self.boolishSSLVerify(storedVerify) {
        case .some(false):
            self.sslVerifyPeer = false
            self.sslCAPathDraft = ""
        case .some(true):
            self.sslVerifyPeer = true
            self.sslCAPathDraft = ""
        case nil:
            self.sslVerifyPeer = true
            self.sslCAPathDraft = storedVerify  // "" for plain default-on
        }
        self.identityHeaderEnabled = server.identityHeader != nil
        self.identityHeaderNameDraft = server.identityHeader?.name ?? ""
        self.identityHeaderValueFromDraft = server.identityHeader?.valueFrom ?? .static
        self.identityHeaderValueDraft = server.identityHeader?.value ?? ""
        self.strictRedirectHeadersDraft = server.strictRedirectHeaders
        self.oauthFlowDraft = server.oauthFlow ?? ""
        self.cwdDraft = server.cwd ?? ""
    }

    /// The boolish half of the bool-or-path `ssl_verify` scalar, or `nil`
    /// when the value is a CA-bundle path (or absent). Mirrors PyYAML's bool
    /// resolution plus the `0`/`1` ints, which is what actually reaches
    /// httpx's `verify=`; anything else is a path.
    static func boolishSSLVerify(_ raw: String) -> Bool? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        // Verified against PyYAML: bare `y` / `n` are NOT bools (they stay
        // strings), so they are paths here, same as Hermes sees them.
        if ["true", "yes", "on", "1"].contains(value) { return true }
        if ["false", "no", "off", "0"].contains(value) { return false }
        return nil
    }

    /// Collapse the two SSL-verify controls back into the single
    /// `ssl_verify` value Hermes expects. `nil` drops the key (default on).
    /// Verify off → "false". Verify on + a CA path → the path. Verify on +
    /// no path → nil (Hermes default true). A CA path is ignored when
    /// verification is off (you can't pin a CA while not verifying).
    var resolvedSSLVerify: String? {
        if !sslVerifyPeer { return "false" }
        let path = sslCAPathDraft.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    func appendEnvRow() {
        envDraft.append(KeyValueRow(key: "", value: ""))
    }

    func removeEnvRow(id: UUID) {
        envDraft.removeAll { $0.id == id }
    }

    func appendHeaderRow() {
        headersDraft.append(KeyValueRow(key: "", value: ""))
    }

    func removeHeaderRow(id: UUID) {
        headersDraft.removeAll { $0.id == id }
    }

    /// The first key two rows share after trimming, or `nil` when they are
    /// all distinct.
    ///
    /// `appendEnvRow` / `appendHeaderRow` add a BLANK row and nothing has
    /// ever checked the result, so two rows keyed `" API_KEY"` and
    /// `"API_KEY"` — or simply the same name typed twice — trimmed to the
    /// same string and `Dictionary(uniqueKeysWithValues:)` hit its
    /// precondition failure, which TRAPS the whole app on Save. Last-wins
    /// would not be better: the user cannot see which row won.
    static func duplicateKey(in rows: [KeyValueRow]) -> String? {
        var seen = Set<String>()
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if !seen.insert(key).inserted { return key }
        }
        return nil
    }

    func save(completion: @escaping (Bool) -> Void) {
        isSaving = true
        saveError = nil

        // Surfaced as a validation error through the same `saveError` the
        // write-failure path uses, BEFORE anything touches config.yaml.
        if let duplicate = Self.duplicateKey(in: envDraft) {
            isSaving = false
            saveError = "Two environment rows use the key “\(duplicate)”. Rename or remove one, then save."
            completion(false)
            return
        }
        if let duplicate = Self.duplicateKey(in: headersDraft) {
            isSaving = false
            saveError = "Two header rows use the key “\(duplicate)”. Rename or remove one, then save."
            completion(false)
            return
        }

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the guards
        // above are the user-visible answer, and this is the belt that keeps
        // a future caller from trapping the process on a collision.
        let envMap = Dictionary(
            envDraft
                .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        let headerMap = Dictionary(
            headersDraft
                .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        let include = includeDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let exclude = excludeDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let timeoutValue = Int(timeoutDraft.trimmingCharacters(in: .whitespaces))
        let connectValue = Int(connectTimeoutDraft.trimmingCharacters(in: .whitespaces))
        let parallelDraft = parallelToolCallsDraft
        let originalParallel = server.supportsParallelToolCalls
        // v0.15 — mTLS drafts. Resolve empty strings to nil so an untouched /
        // cleared field drops the YAML key. Only HTTP/SSE servers surface the
        // TLS section, so non-stdio transports gate the writes below.
        let certValue: String? = clientCertDraft.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : clientCertDraft.trimmingCharacters(in: .whitespaces)
        let keyValue: String? = clientKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : clientKeyDraft.trimmingCharacters(in: .whitespaces)
        let verifyValue: String? = resolvedSSLVerify
        let originalCert = server.clientCert
        let originalKey = server.clientKey
        let originalVerify = server.sslVerify
        // v0.20.4 drafts. Scarf writes an identity_header only in the shapes
        // Hermes's own `_resolve_identity_header` accepts — a blank `name`,
        // or `value_from: static` with a blank `value`, are both "warn and
        // ignore" cases there, so writing one would put a header in the
        // user's config that never gets sent AND that Scarf's own reader
        // drops on the next load. Refusing beats round-tripping garbage.
        // (`profile` mode needs no value: Hermes substitutes the active
        // profile name at connect time.)
        let trimmedIdentityName = identityHeaderNameDraft.trimmingCharacters(in: .whitespaces)
        let identityHeaderIsResolvable = identityHeaderEnabled
            && !trimmedIdentityName.isEmpty
            && (identityHeaderValueFromDraft == .profile
                || !identityHeaderValueDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        let identityHeaderValue: MCPIdentityHeader? = identityHeaderIsResolvable
            ? MCPIdentityHeader(name: trimmedIdentityName, valueFrom: identityHeaderValueFromDraft, value: identityHeaderValueDraft)
            : nil
        let originalIdentityHeader = server.identityHeader
        let strictRedirectValue = strictRedirectHeadersDraft
        let originalStrictRedirect = server.strictRedirectHeaders
        let trimmedOAuthFlow = oauthFlowDraft.trimmingCharacters(in: .whitespaces)
        let oauthFlowValue: String? = trimmedOAuthFlow.isEmpty ? nil : trimmedOAuthFlow
        let originalOAuthFlow = server.oauthFlow
        let trimmedCwd = cwdDraft.trimmingCharacters(in: .whitespaces)
        let cwdValue: String? = trimmedCwd.isEmpty ? nil : trimmedCwd
        let originalCwd = server.cwd

        let service = fileService
        let transport = server.transport
        let name = server.name
        let resources = resourcesEnabled
        let prompts = promptsEnabled

        Task.detached {
            // Compute success as an immutable so the MainActor.run closure
            // captures a value, not a mutable var. Swift 6 rejects
            // var-captures across concurrent closures as data races.
            let success: Bool = {
                var ok = true
                switch transport {
                case .stdio:
                    if !service.setMCPServerEnv(name: name, env: envMap) { ok = false }
                case .http:
                    if !service.setMCPServerHeaders(name: name, headers: headerMap) { ok = false }
                case .sse:
                    // SSE servers carry headers exactly like .http does.
                    // There is no SSE-only scalar to write: `sse_read_timeout`
                    // is a literal 300.0 on every supported Hermes, so Scarf
                    // neither offers it nor touches it (see the note in
                    // `HermesMCPServer`).
                    if !service.setMCPServerHeaders(name: name, headers: headerMap) { ok = false }
                }
                if !service.updateMCPToolFilters(
                    name: name,
                    include: include,
                    exclude: exclude,
                    resources: resources,
                    prompts: prompts
                ) { ok = false }
                if !service.setMCPServerTimeouts(name: name, timeout: timeoutValue, connectTimeout: connectValue) {
                    ok = false
                }
                // v0.14 — only write the parallel-tool-calls scalar when
                // the user touched the field. Skipping a no-op write
                // keeps the YAML diff small and avoids churning the
                // file when the toggle wasn't surfaced (pre-v0.14 hosts
                // hide the row entirely, so parallelDraft == originalParallel
                // there as well).
                if parallelDraft != originalParallel {
                    if !service.setMCPServerParallelToolCalls(name: name, enabled: parallelDraft) {
                        ok = false
                    }
                }
                // v0.15 — mTLS scalars. Only HTTP/SSE servers expose the TLS
                // section in the editor; for stdio servers the drafts stay at
                // their initial (absent) values, so the != checks are no-ops.
                // Each write is gated on a delta to keep the YAML diff minimal.
                if transport != .stdio {
                    if certValue != originalCert {
                        if !service.setMCPServerClientCert(name: name, path: certValue) { ok = false }
                    }
                    if keyValue != originalKey {
                        if !service.setMCPServerClientKey(name: name, path: keyValue) { ok = false }
                    }
                    if verifyValue != originalVerify {
                        if !service.setMCPServerSSLVerify(name: name, value: verifyValue) { ok = false }
                    }
                    if identityHeaderValue != originalIdentityHeader {
                        if !service.setMCPServerIdentityHeader(name: name, header: identityHeaderValue) { ok = false }
                    }
                    if strictRedirectValue != originalStrictRedirect {
                        if !service.setMCPServerStrictRedirectHeaders(name: name, value: strictRedirectValue) { ok = false }
                    }
                    // v0.21.1 — oauth.flow. Delta-gated like every scalar
                    // above, which also means a pre-v0.21.1 host (where the
                    // row is hidden, so the draft equals the loaded value)
                    // never writes the key at all.
                    if oauthFlowValue != originalOAuthFlow {
                        if !service.setMCPServerOAuthFlow(name: name, flow: oauthFlowValue) { ok = false }
                    }
                } else if cwdValue != originalCwd {
                    // v0.20.4 — cwd is stdio-only.
                    if !service.setMCPServerCwd(name: name, path: cwdValue) { ok = false }
                }
                return ok
            }()
            await MainActor.run {
                self.isSaving = false
                if !success {
                    self.saveError = "One or more fields could not be written. Check \(self.context.paths.configYAML)."
                }
                completion(success)
            }
        }
    }

    func clearOAuthToken(completion: @escaping (Bool) -> Void) {
        let service = fileService
        let name = server.name
        Task.detached {
            let ok = service.deleteMCPOAuthToken(name: name)
            await MainActor.run { completion(ok) }
        }
    }
}
