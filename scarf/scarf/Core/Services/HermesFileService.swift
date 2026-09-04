import Foundation
import ScarfCore
import os

struct HermesFileService: Sendable {

    nonisolated static let logger = Logger(subsystem: "com.scarf", category: "HermesFileService")

    let context: ServerContext
    let transport: any ServerTransport

    nonisolated init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    // MARK: - Config

    nonisolated func loadConfig() -> HermesConfig {
        // ScarfMon — when Full mode is on, log a window of stack
        // frames above this call so mystery callers (e.g. config
        // reads with no user action) can be identified by tailing
        //   `log stream --predicate 'subsystem == "com.scarf.mon"'`.
        // The window spans frames 1..8: SwiftUI / ObservableObject
        // body re-eval chains burn 4–6 frames before reaching the
        // user code, so dropping fewer than that hides the real
        // caller. Each frame is on its own line, prefixed with "#N",
        // so a single `log stream` line carries the full breadcrumb.
        // Symbol-only — no addresses, no PII. Backtrace alloc is
        // gated on isActive so it's free outside Full mode.
        if ScarfMon.isActive {
            let frames = Thread.callStackSymbols.prefix(10)
                .enumerated()
                .map { "#\($0.offset) \($0.element)" }
                .joined(separator: " | ")
            Self.perfLogger.debug("loadConfig stack: \(frames, privacy: .public)")
        }
        return ScarfMon.measure(.diskIO, "loadConfig") {
            guard let content = readFile(context.paths.configYAML) else { return .empty }
            return HermesConfig(yaml: content)
        }
    }

    private nonisolated static let perfLogger = Logger(subsystem: "com.scarf.mon", category: "HermesFileService")

    /// Error-surfacing config load. Used by Dashboard to show the user a
    /// specific reason when config.yaml can't be read on a remote host
    /// (permission denied, missing file, sqlite3 not installed, etc.)
    /// instead of silently falling back to `.empty`.
    nonisolated func loadConfigResult() -> Result<HermesConfig, Error> {
        readFileResult(context.paths.configYAML).map { HermesConfig(yaml: $0) }
    }

    /// Parsed YAML result bundle. Type alias into ScarfCore's canonical
    /// `ParsedYAML` so app-side callers keep their existing spelling.
    typealias ParsedYAML = ScarfCore.ParsedYAML

    /// Parse a subset of YAML into flat dotted paths. Delegates to the
    /// canonical ScarfCore implementation (`HermesYAML.parseNestedYAML`)
    /// — the config-mapping duplicate of this file drifted from
    /// `HermesConfig(yaml:)` once (v0.17/v0.18 keys were added only to
    /// ScarfCore, so Settings dropdowns saved values the Mac reader
    /// never round-tripped). Delegation removes the second copy so the
    /// two targets cannot diverge again.
    nonisolated static func parseNestedYAML(_ yaml: String) -> ParsedYAML {
        HermesYAML.parseNestedYAML(yaml)
    }

    /// Strip a single layer of surrounding single or double quotes from a YAML scalar.
    nonisolated static func stripYAMLQuotes(_ s: String) -> String {
        HermesYAML.stripYAMLQuotes(s)
    }

    // MARK: - Gateway State

    nonisolated func loadGatewayState() -> GatewayState? {
        guard let data = readFileData(context.paths.gatewayStateJSON) else { return nil }
        do {
            return try JSONDecoder().decode(GatewayState.self, from: data)
        } catch {
            Self.logger.warning("Failed to decode gateway state: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Error-surfacing gateway-state load. `.success(nil)` means the file
    /// doesn't exist yet (gateway hasn't written state — normal when Hermes
    /// is stopped). `.failure` means the file exists but couldn't be read
    /// (permission denied, connection down, JSON corruption).
    nonisolated func loadGatewayStateResult() -> Result<GatewayState?, Error> {
        // Distinguish "file doesn't exist yet" (normal, returns .success(nil))
        // from "file exists but we can't read or parse it" (error).
        if !transport.fileExists(context.paths.gatewayStateJSON) {
            return .success(nil)
        }
        switch readFileDataResult(context.paths.gatewayStateJSON) {
        case .success(let data):
            do {
                return .success(try JSONDecoder().decode(GatewayState.self, from: data))
            } catch {
                Self.logger.warning("Failed to decode gateway state: \(error.localizedDescription, privacy: .public)")
                return .failure(error)
            }
        case .failure(let err):
            return .failure(err)
        }
    }

    // MARK: - Memory

    nonisolated func loadMemoryProfiles() -> [String] {
        guard let entries = try? transport.listDirectory(context.paths.memoriesDir) else { return [] }
        return entries.filter { name in
            let path = context.paths.memoriesDir + "/" + name
            return transport.stat(path)?.isDirectory == true
        }.sorted()
    }

    nonisolated func loadMemory(profile: String = "") -> String {
        let path = memoryPath(profile: profile, file: "MEMORY.md")
        return readFile(path) ?? ""
    }

    nonisolated func loadUserProfile(profile: String = "") -> String {
        let path = memoryPath(profile: profile, file: "USER.md")
        return readFile(path) ?? ""
    }

    nonisolated func saveMemory(_ content: String, profile: String = "") {
        let path = memoryPath(profile: profile, file: "MEMORY.md")
        writeFile(path, content: content)
    }

    nonisolated func saveUserProfile(_ content: String, profile: String = "") {
        let path = memoryPath(profile: profile, file: "USER.md")
        writeFile(path, content: content)
    }

    nonisolated private func memoryPath(profile: String, file: String) -> String {
        if profile.isEmpty {
            return context.paths.memoriesDir + "/" + file
        }
        return context.paths.memoriesDir + "/" + profile + "/" + file
    }

    // MARK: - Cron

    nonisolated func loadCronJobs() -> [HermesCronJob] {
        loadCronJobsOutcome().jobs
    }

    /// Like `loadCronJobs()` but distinguishes "no jobs file / empty" from
    /// "file present but undecodable" so the Cron UI can warn about a
    /// corrupt `jobs.json` instead of silently showing an empty board. (t-aud09)
    nonisolated func loadCronJobsOutcome() -> (jobs: [HermesCronJob], decodeFailed: Bool) {
        ScarfMon.measure(.diskIO, "loadCronJobs") {
            guard let data = readFileData(context.paths.cronJobsJSON) else {
                return (jobs: [], decodeFailed: false)
            }
            do {
                let file = try JSONDecoder().decode(CronJobsFile.self, from: data)
                return (jobs: file.jobs, decodeFailed: false)
            } catch {
                Self.logger.warning("Failed to decode cron jobs: \(error.localizedDescription, privacy: .public)")
                return (jobs: [], decodeFailed: true)
            }
        }
    }

    /// Read the most-recent run output for a cron job. Hermes writes
    /// `~/.hermes/cron/output/<jobId>/<YYYY-MM-DD_HH-MM-SS>.md` per run
    /// (one file per execution); we resolve the per-job subdir, take
    /// the lexicographically-last filename (which is the newest given
    /// the timestamp prefix), and return its contents. Returns nil
    /// when the subdir is missing, empty, or the read fails — the cron
    /// detail surface treats nil as "no output yet."
    ///
    /// A legacy flat-file layout (`<dir>/<filename containing jobId>`)
    /// is checked as a fallback so older Hermes installs that used a
    /// non-nested layout still surface their last run.
    nonisolated func loadCronOutput(jobId: String) -> String? {
        let dir = context.paths.cronOutputDir
        let perJobDir = dir + "/" + jobId
        if let runs = try? transport.listDirectory(perJobDir),
           let latest = runs.sorted().last {
            if let content = readFile(perJobDir + "/" + latest) {
                return content
            }
        }
        // Legacy fallback: pre-subdir layouts had files like
        // `<jobId>-<timestamp>.log` directly under cronOutputDir. Keep
        // matching them so users on older Hermes versions still see
        // their tail.
        if let files = try? transport.listDirectory(dir),
           let matching = files.filter({ $0.contains(jobId) }).sorted().last {
            return readFile(dir + "/" + matching)
        }
        return nil
    }

    // MARK: - Skills

    /// Walks `~/.hermes/skills/<category>/<name>/`. v2.5 delegates to
    /// the shared ScarfCore `SkillsScanner` so iOS and Mac use byte-
    /// identical scan logic — including the v0.11 frontmatter parsing
    /// that populates `HermesSkill.allowedTools` / `relatedSkills` /
    /// `dependencies`.
    nonisolated func loadSkills() -> [HermesSkillCategory] {
        SkillsScanner.scan(context: context, transport: transport)
    }
    // (t-aud15) Removed dead `loadSkillContent`/`saveSkillContent`/
    // `isValidSkillPath` — zero callers; SkillsViewModel owns the live
    // copies of these in ScarfCore.

    // MARK: - MCP Servers

    nonisolated func loadMCPServers() -> [HermesMCPServer] {
        guard let yaml = readFile(context.paths.configYAML) else { return [] }
        let parsed = parseMCPServersBlock(yaml: yaml)
        return parsed.map { server in
            let tokenPath = context.paths.mcpTokensDir + "/" + server.name + ".json"
            let hasToken = transport.fileExists(tokenPath)
            guard hasToken != server.hasOAuthToken else { return server }
            return HermesMCPServer(
                name: server.name,
                transport: server.transport,
                command: server.command,
                args: server.args,
                url: server.url,
                auth: server.auth,
                env: server.env,
                headers: server.headers,
                timeout: server.timeout,
                connectTimeout: server.connectTimeout,
                enabled: server.enabled,
                toolsInclude: server.toolsInclude,
                toolsExclude: server.toolsExclude,
                resourcesEnabled: server.resourcesEnabled,
                promptsEnabled: server.promptsEnabled,
                hasOAuthToken: hasToken,
                sseReadTimeout: server.sseReadTimeout,
                supportsParallelToolCalls: server.supportsParallelToolCalls,
                clientCert: server.clientCert,
                clientKey: server.clientKey,
                sslVerify: server.sslVerify,
                identityHeader: server.identityHeader,
                strictRedirectHeaders: server.strictRedirectHeaders,
                cwd: server.cwd
            )
        }
    }

    /// Runs one `hermes mcp add` plan and reports what the CLI actually did.
    ///
    /// `cmd_mcp_add` **never exits nonzero** — every failure path is a bare
    /// `return` — so the outcome has to be read out of stdout. See
    /// `HermesMCPAdd` for the prompt-by-prompt derivation of each plan and
    /// for why the old blanket `"y\ny\ny\n"` wrote a literal `y` into
    /// `~/.hermes/.env` as an API key.
    nonisolated func runMCPAdd(_ plan: HermesMCPAdd.Plan, name: String) -> (outcome: HermesMCPAddOutcome, output: String) {
        let result = runHermesCLI(args: plan.arguments, timeout: 90, stdinInput: plan.stdin)
        // A nonzero exit only happens on an argparse rejection, and it is
        // still a not-saved outcome — parse either way so the CLI's own
        // message reaches the user.
        return (HermesMCPAdd.parseOutcome(result.output, name: name), result.output)
    }

    /// Reads the two pieces of host state that change which prompts
    /// `hermes mcp add` will ask, so the stdin plan can be built for the
    /// state the host is ACTUALLY in. See ``HermesMCPAdd/HostState`` for why
    /// guessing here mis-feeds a bearer token. (F9)
    ///
    /// `apiKeyAlreadyConfigured` is `nil` — a refusal, not a default — when
    /// we cannot read `.env` at all (a remote transport hiccup, an
    /// unreadable file); an *absent* file that we successfully determined is
    /// absent is a confident `false`.
    nonisolated func mcpAddHostState(
        name: String,
        overwriteConfirmed: Bool = false
    ) -> HermesMCPAdd.HostState {
        let exists = loadMCPServers().contains { $0.name == name }
        return HermesMCPAdd.HostState(
            serverNameExists: exists,
            overwriteConfirmed: overwriteConfirmed,
            apiKeyAlreadyConfigured: mcpAPIKeyAlreadyConfigured(name: name)
        )
    }

    /// Mirrors the CLI's `get_env_value(MCP_<NAME>_API_KEY)` resolution
    /// order: the process environment the child will inherit first, then
    /// `~/.hermes/.env`. Both are things Scarf can see — the child's
    /// `os.environ` is derived from the environment we hand it in
    /// `runHermesCLI`, so this is a determination, not an estimate.
    ///
    /// Returns `nil` when the `.env` read fails in a way we can't
    /// distinguish from "unreadable" on a remote host.
    nonisolated func mcpAPIKeyAlreadyConfigured(name: String) -> Bool? {
        let key = HermesMCPAdd.envKeyForServer(name)
        if !context.isRemote,
           let value = Self.enrichedEnvironment()[key], !value.isEmpty {
            return true
        }
        guard let envText = readFile(context.paths.envFile) else {
            // No `.env`: on a local host that is a confident "absent" — the
            // file genuinely isn't there and the CLI's `load_env()` returns
            // {}. On a remote host a nil read is ambiguous (missing file vs.
            // failed transport), so refuse rather than assume.
            return context.isRemote ? nil : false
        }
        for line in envText.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard trimmed.hasPrefix("\(key)=") || trimmed.hasPrefix("export \(key)=") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty { return true }
        }
        return false
    }

    /// Prefixes the CLI's output with a note when the plan deliberately
    /// withheld a token the user typed. The CLI reuses the `.env` key it
    /// already has and never prompts, so without this the typed token is
    /// silently discarded and the server keeps using the OLD credential —
    /// a failure the user would only find by testing the server. (F9)
    nonisolated static func annotate(_ output: String, plan: HermesMCPAdd.Plan, name: String) -> String {
        guard plan.discardedSuppliedToken else { return output }
        return tokenReusedNote(name: name) + "\n" + output
    }

    nonisolated static func tokenReusedNote(name: String) -> String {
        let key = HermesMCPAdd.envKeyForServer(name)
        return String(
            localized: "Note: \(key) is already set in ~/.hermes/.env, so Hermes reused it and ignored the token you entered. To replace the token, remove that line from .env and add the server again.",
            comment: "MCP add reused an existing API key instead of the typed one"
        )
    }

    /// Turns a `HermesMCPAdd.PlanError` into the `(exitCode, output)` shape
    /// the add call sites already handle, with a message the user can act
    /// on. Refusing beats feeding a misaligned stdin plan.
    nonisolated static func describe(_ error: Error, name: String) -> (exitCode: Int32, output: String) {
        switch error {
        case HermesMCPAdd.PlanError.serverAlreadyExists:
            return (1, String(
                localized: "A server named “\(name)” already exists. Adding it again would overwrite the existing entry — confirm the overwrite, or choose a different name.",
                comment: "MCP add refused because the server name is taken"
            ))
        case HermesMCPAdd.PlanError.apiKeyStateUnknown(let envKey):
            return (1, String(
                localized: "Couldn’t determine whether \(envKey) is already set on this host, so Scarf stopped rather than risk sending your token to the wrong prompt. Check that ~/.hermes/.env is readable and try again.",
                comment: "MCP add refused because the .env key state could not be read"
            ))
        default:
            return (1, "\(error)")
        }
    }

    /// Creates a stdio MCP server entry, passing the command's arguments
    /// **at add time** so the CLI's discovery probe launches the real
    /// server and the entry lands enabled.
    ///
    /// Scarf used to withhold the args deliberately and patch them into
    /// config.yaml afterwards. That guaranteed a probe failure (a bare
    /// `npx` with no server package), and the piped `y` then accepted
    /// "Save config anyway (you can test later)?", which writes
    /// `enabled: false`. There is no probe-skipping flag on `mcp add` at
    /// any shipped version — passing the args is the fix.
    @discardableResult
    nonisolated func addMCPServerStdio(
        name: String,
        command: String,
        args: [String],
        env: [String: String] = [:],
        overwriteConfirmed: Bool = false
    ) -> (exitCode: Int32, output: String) {
        let state = mcpAddHostState(name: name, overwriteConfirmed: overwriteConfirmed)
        do {
            let plan = try HermesMCPAdd.stdioPlan(
                name: name, command: command, args: args, env: env, state: state
            )
            let run = runMCPAdd(plan, name: name)
            return (run.outcome.isLive ? 0 : 1, run.output)
        } catch {
            return Self.describe(error, name: name)
        }
    }

    /// Creates an HTTP MCP server entry, answering only the prompts the
    /// chosen auth mode actually triggers.
    @discardableResult
    nonisolated func addMCPServerHTTP(
        name: String,
        url: String,
        auth: String?,
        apiKey: String = "",
        overwriteConfirmed: Bool = false
    ) -> (exitCode: Int32, output: String) {
        let mode: HermesMCPAddAuthMode
        switch auth?.lowercased() {
        case "oauth": mode = .oauth
        case "header": mode = apiKey.isEmpty ? .none : .header(token: apiKey)
        default: mode = .none
        }
        let state = mcpAddHostState(name: name, overwriteConfirmed: overwriteConfirmed)
        do {
            let plan = try HermesMCPAdd.urlPlan(name: name, url: url, auth: mode, state: state)
            let run = runMCPAdd(plan, name: name)
            return (run.outcome.isLive ? 0 : 1, Self.annotate(run.output, plan: plan, name: name))
        } catch {
            return Self.describe(error, name: name)
        }
    }

    /// Adds an SSE-transport MCP server. v0.13+ only — caller is responsible
    /// for capability-gating.
    ///
    /// Hermes v0.16 `mcp add` only understands `--url` (there is NO
    /// `--transport` / `--sse-read-timeout` flag — they'd be rejected at
    /// argparse time). So we create the entry with `hermes mcp add --url`
    /// (which produces a remote/HTTP-shaped block) and then write the
    /// `transport: sse` (+ optional `sse_read_timeout`) scalars into that
    /// server's YAML block via the same surgical patcher the rest of the
    /// MCP YAML surface uses. The `transport: sse` scalar is what the
    /// reader keys on to discriminate SSE from HTTP.
    @discardableResult
    nonisolated func addMCPServerSSE(
        name: String,
        url: String,
        sseReadTimeout: Int?,
        auth: String? = nil,
        apiKey: String = "",
        overwriteConfirmed: Bool = false
    ) -> (exitCode: Int32, output: String) {
        let mode: HermesMCPAddAuthMode
        switch auth?.lowercased() {
        case "oauth": mode = .oauth
        case "header": mode = apiKey.isEmpty ? .none : .header(token: apiKey)
        default: mode = .none
        }
        let state = mcpAddHostState(name: name, overwriteConfirmed: overwriteConfirmed)
        let run: (outcome: HermesMCPAddOutcome, output: String)
        var tokenWasDiscarded = false
        do {
            let plan = try HermesMCPAdd.urlPlan(name: name, url: url, auth: mode, state: state)
            run = runMCPAdd(plan, name: name)
            tokenWasDiscarded = plan.discardedSuppliedToken
        } catch {
            return Self.describe(error, name: name)
        }
        let addResult = (
            exitCode: Int32(run.outcome.isLive ? 0 : 1),
            output: tokenWasDiscarded ? Self.tokenReusedNote(name: name) + "\n" + run.output : run.output
        )
        guard addResult.exitCode == 0 else { return addResult }
        // Stamp the SSE transport discriminator (+ optional read timeout)
        // into the freshly-written entry's YAML block.
        _ = patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertScalar(key: "transport", value: "sse", in: &entryLines)
            if let timeout = sseReadTimeout {
                Self.replaceOrInsertScalar(key: "sse_read_timeout", value: String(timeout), in: &entryLines)
            }
        }
        return addResult
    }

    /// Updates the `sse_read_timeout` scalar in-place via the same surgical
    /// patcher used by `setMCPServerTimeouts`. Pass `nil` to remove the
    /// scalar entirely (Hermes default applies).
    @discardableResult
    nonisolated func setMCPServerSSETimeout(name: String, sseReadTimeout: Int?) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            if let timeout = sseReadTimeout {
                Self.replaceOrInsertScalar(key: "sse_read_timeout", value: String(timeout), in: &entryLines)
            } else {
                Self.removeScalar(key: "sse_read_timeout", in: &entryLines)
            }
        }
    }

    /// Updates the v0.14 `supports_parallel_tool_calls` scalar on an MCP
    /// server entry. Pass `nil` to drop the key (Hermes default applies);
    /// pass `true` / `false` to opt this server in or out explicitly.
    /// Caller is responsible for capability-gating —
    /// `HermesCapabilities.hasMCPParallelToolCalls`. Pre-v0.14 hosts
    /// silently ignore the key.
    @discardableResult
    nonisolated func setMCPServerParallelToolCalls(name: String, enabled: Bool?) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            if let value = enabled {
                Self.replaceOrInsertScalar(
                    key: "supports_parallel_tool_calls",
                    value: value ? "true" : "false",
                    in: &entryLines
                )
            } else {
                Self.removeScalar(key: "supports_parallel_tool_calls", in: &entryLines)
            }
        }
    }

    /// Updates the v0.15 `client_cert` scalar on an MCP server entry — the
    /// path to a combined-PEM file used for mTLS on HTTP / SSE transports.
    /// Pass `nil` or an empty string to drop the key. Caller is responsible
    /// for capability-gating — `HermesCapabilities.hasMCPClientCerts`.
    @discardableResult
    nonisolated func setMCPServerClientCert(name: String, path: String?) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            if let path, !path.trimmingCharacters(in: .whitespaces).isEmpty {
                Self.replaceOrInsertScalar(
                    key: "client_cert",
                    value: path.trimmingCharacters(in: .whitespaces),
                    in: &entryLines
                )
            } else {
                Self.removeScalar(key: "client_cert", in: &entryLines)
            }
        }
    }

    /// Updates the v0.15 `client_key` scalar — the private-key file path that
    /// pairs with a string `client_cert`. Pass `nil`/empty to drop the key.
    @discardableResult
    nonisolated func setMCPServerClientKey(name: String, path: String?) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            if let path, !path.trimmingCharacters(in: .whitespaces).isEmpty {
                Self.replaceOrInsertScalar(
                    key: "client_key",
                    value: path.trimmingCharacters(in: .whitespaces),
                    in: &entryLines
                )
            } else {
                Self.removeScalar(key: "client_key", in: &entryLines)
            }
        }
    }

    /// Updates the v0.15 `ssl_verify` scalar — either a bool string
    /// (`"true"` / `"false"`) or a CA-bundle file path. Pass `nil`/empty to
    /// drop the key (Hermes default `true` applies).
    @discardableResult
    nonisolated func setMCPServerSSLVerify(name: String, value: String?) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                Self.replaceOrInsertScalar(
                    key: "ssl_verify",
                    value: value.trimmingCharacters(in: .whitespaces),
                    in: &entryLines
                )
            } else {
                Self.removeScalar(key: "ssl_verify", in: &entryLines)
            }
        }
    }

    /// Updates the v0.20.4 `identity_header:` nested block — a fixed-shape
    /// `name` / `value_from` / `value` mapping, not a scalar, so it uses a
    /// dedicated sub-block writer rather than `replaceOrInsertScalar`. Pass
    /// `nil` to drop the block entirely. `value` is omitted from the
    /// written block when `valueFrom == .profile` (Hermes ignores it in
    /// that mode; matches the manifest's documented shape). Caller is
    /// responsible for capability-gating —
    /// `HermesCapabilities.hasMCPIdentityHeader`.
    @discardableResult
    nonisolated func setMCPServerIdentityHeader(name: String, header: MCPIdentityHeader?) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertIdentityHeader(header: header, in: &entryLines)
        }
    }

    /// Updates the v0.20.4 `strict_redirect_headers` bool scalar (HTTP/SSE
    /// only — Portable Agent Plugins v1 §7.2.1). Pass `nil` to drop the key
    /// (Hermes default `false` applies).
    @discardableResult
    nonisolated func setMCPServerStrictRedirectHeaders(name: String, value: Bool?) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            if let value {
                Self.replaceOrInsertScalar(
                    key: "strict_redirect_headers",
                    value: value ? "true" : "false",
                    in: &entryLines
                )
            } else {
                Self.removeScalar(key: "strict_redirect_headers", in: &entryLines)
            }
        }
    }

    /// Updates the v0.20.4 `cwd` scalar — working directory for stdio
    /// servers only (`StdioServerParameters.cwd`). Pass `nil`/empty to drop
    /// the key (Hermes uses its own process cwd).
    @discardableResult
    nonisolated func setMCPServerCwd(name: String, path: String?) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            if let path, !path.trimmingCharacters(in: .whitespaces).isEmpty {
                Self.replaceOrInsertScalar(
                    key: "cwd",
                    value: path.trimmingCharacters(in: .whitespaces),
                    in: &entryLines
                )
            } else {
                Self.removeScalar(key: "cwd", in: &entryLines)
            }
        }
    }

    /// Re-points an existing stdio server's `command` scalar.
    ///
    /// Creation still belongs to `hermes mcp add` — this is for the one
    /// case the CLI has no verb for: a bundled server binary whose PATH
    /// moved (the user dragged Scarf.app to a different folder), where
    /// remove-then-add would discard every tool filter and env the user
    /// set on the entry. Quoted through `yamlScalar` because an app can
    /// live at a path with a space or a colon in it.
    @discardableResult
    nonisolated func setMCPServerCommand(name: String, command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let value = Self.yamlScalar(trimmed)
        // This is the one patch that runs unattended on every launch, so it
        // states what it expects to find afterwards and lets the read-back
        // prove it — rather than reporting success because the write threw
        // no error it was in a position to see.
        return patchMCPServerField(
            name: name,
            expecting: ["    command: \(value)"]
        ) { entryLines in
            Self.replaceOrInsertScalar(key: "command", value: value, in: &entryLines)
        }
    }

    @discardableResult
    nonisolated func removeMCPServer(name: String) -> (exitCode: Int32, output: String) {
        runHermesCLI(args: ["mcp", "remove", name], timeout: 30)
    }

    nonisolated func testMCPServer(name: String) async -> MCPTestResult {
        let started = Date()
        let service = self
        let result = await Task.detached { () -> (Int32, String) in
            service.runHermesCLI(args: ["mcp", "test", name], timeout: 30)
        }.value
        let elapsed = Date().timeIntervalSince(started)
        let tools = Self.parseToolListFromTestOutput(result.1)
        // hermes mcp test exits 0 even when the inner connection fails — it
        // reports the failure on stdout instead. Look for explicit failure
        // markers so the UI doesn't show a green check on a broken server.
        let output = result.1
        return MCPTestResult(
            serverName: name,
            succeeded: result.0 == 0 && !Self.mcpTestReportsFailure(output),
            output: output,
            tools: tools,
            elapsed: elapsed
        )
    }

    /// Did `hermes mcp test` report a failure?
    ///
    /// `mcp test` exits 0 even when the inner connection fails — it reports
    /// on stdout — so the exit code alone can't decide. But every failure
    /// path goes through `hermes_cli/mcp_config.py::_error`, which prints
    /// `  ✗ {text}` (line 56, verified at tag `v2026.8.31`): the ✗ marker
    /// covers `Connection failed …`, `Server '…' not found …`, and every
    /// other error the command can emit.
    ///
    /// The three prose substrings this used to also match ("Connection
    /// failed", "No such file or directory", "Error:", all case-insensitive)
    /// were therefore redundant AND false-positive generators: on a healthy
    /// server the same output continues with one line per discovered tool,
    /// `    {tool_name:36s} {description}` — so a filesystem server with a
    /// tool documented "… returns Error: ENOENT / No such file or directory"
    /// turned a fully successful probe red. CLI prose is not a protocol; the
    /// ✗ marker is.
    nonisolated static func mcpTestReportsFailure(_ output: String) -> Bool {
        output.contains("✗")
    }

    nonisolated private static func parseToolListFromTestOutput(_ output: String) -> [String] {
        var tools: [String] = []
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let candidate = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            // Take only the identifier before any separator (":" or whitespace).
            let token = candidate.split(whereSeparator: { ":(".contains($0) || $0.isWhitespace }).first.map(String.init) ?? candidate
            if !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                tools.append(token)
            }
        }
        return tools
    }

    @discardableResult
    nonisolated func toggleMCPServerEnabled(name: String, enabled: Bool) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertScalar(key: "enabled", value: enabled ? "true" : "false", in: &entryLines)
        }
    }

    @discardableResult
    nonisolated func setMCPServerEnv(name: String, env: [String: String]) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertSubMap(header: "env", map: env, in: &entryLines)
        }
    }

    @discardableResult
    nonisolated func setMCPServerHeaders(name: String, headers: [String: String]) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertSubMap(header: "headers", map: headers, in: &entryLines)
        }
    }

    @discardableResult
    nonisolated func updateMCPToolFilters(name: String, include: [String], exclude: [String], resources: Bool, prompts: Bool) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertToolsBlock(include: include, exclude: exclude, resources: resources, prompts: prompts, in: &entryLines)
        }
    }

    @discardableResult
    nonisolated func setMCPServerTimeouts(name: String, timeout: Int?, connectTimeout: Int?) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            if let timeout {
                Self.replaceOrInsertScalar(key: "timeout", value: String(timeout), in: &entryLines)
            } else {
                Self.removeScalar(key: "timeout", in: &entryLines)
            }
            if let connectTimeout {
                Self.replaceOrInsertScalar(key: "connect_timeout", value: String(connectTimeout), in: &entryLines)
            } else {
                Self.removeScalar(key: "connect_timeout", in: &entryLines)
            }
        }
    }

    @discardableResult
    nonisolated func deleteMCPOAuthToken(name: String) -> Bool {
        let path = context.paths.mcpTokensDir + "/" + name + ".json"
        do {
            try transport.removeFile(path)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    nonisolated func restartGateway() -> (exitCode: Int32, output: String) {
        runHermesCLI(args: ["gateway", "restart"], timeout: 30)
    }

    // MARK: - MCP YAML: block extractor + parser

    private struct MCPBlockLocation {
        let prefix: [String]
        let block: [String]   // includes the "mcp_servers:" header line
        let suffix: [String]
    }

    nonisolated private func extractMCPBlock(yaml: String) -> MCPBlockLocation {
        let lines = yaml.components(separatedBy: "\n")
        var blockStart = -1
        var blockEnd = lines.count
        for (index, line) in lines.enumerated() {
            if blockStart < 0 {
                if line.hasPrefix("mcp_servers:") {
                    blockStart = index
                }
                continue
            }
            let trimmed = Self.trimYAMLLine(line)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // "Top level" means NO leading whitespace of any kind. Counting
            // spaces alone made a tab-indented line look top-level, which cut
            // the block short right before it — so the block handed to the
            // patcher ended above the very lines that made the file
            // unpatchable, and the tab check downstream never saw them.
            let isTopLevel = !(line.first.map { $0 == " " || $0 == "\t" } ?? false)
            if isTopLevel && trimmed.contains(":") {
                blockEnd = index
                break
            }
        }
        if blockStart < 0 {
            return MCPBlockLocation(prefix: lines, block: [], suffix: [])
        }
        // Trim trailing blank lines and comments from the block — they belong
        // to the file footer, not the mcp_servers section. Without this, when
        // mcp_servers is the last top-level key, the block would extend to EOF
        // and any inserted content (args, env, headers, tools) would land
        // after the trailing comments.
        while blockEnd > blockStart + 1 {
            let line = lines[blockEnd - 1]
            let trimmed = Self.trimYAMLLine(line)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                blockEnd -= 1
            } else {
                break
            }
        }
        return MCPBlockLocation(
            prefix: Array(lines[0..<blockStart]),
            block: Array(lines[blockStart..<blockEnd]),
            suffix: Array(lines[blockEnd..<lines.count])
        )
    }

    nonisolated fileprivate func parseMCPServersBlock(yaml: String) -> [HermesMCPServer] {
        let location = extractMCPBlock(yaml: yaml)
        guard location.block.count > 1 else { return [] }

        var servers: [HermesMCPServer] = []

        var currentName: String?
        var fields: [String: String] = [:]
        var argsList: [String] = []
        var envMap: [String: String] = [:]
        var headersMap: [String: String] = [:]
        var includeList: [String] = []
        var excludeList: [String] = []
        var resources = false
        var prompts = false
        var subSection: String?
        // v0.20.4 — identity_header is a small fixed-shape nested block
        // (name / value_from / value). Captured separately from `fields`
        // since it's not a flat scalar.
        var identityHeaderName: String?
        var identityHeaderValueFrom: String?
        var identityHeaderValue: String?

        func flush() {
            guard let name = currentName else { return }
            // 3-way transport discriminator: an explicit `transport: sse` scalar
            // wins (Hermes v0.13+ emits it for SSE servers); otherwise URL-bearing
            // entries fall back to .http (v0.12 shape) and command-bearing entries
            // to .stdio. This preserves byte-for-byte round-trip on existing files
            // — pre-v0.13 entries have no `transport:` key so they parse identically.
            let transport: MCPTransport = {
                if fields["transport"]?.lowercased() == "sse" { return .sse }
                if fields["url"] != nil { return .http }
                return .stdio
            }()
            let enabledStr = fields["enabled"]?.lowercased()
            let enabled = enabledStr != "false"
            let timeout = fields["timeout"].flatMap(Int.init)
            let connectTimeout = fields["connect_timeout"].flatMap(Int.init)
            let sseReadTimeout = fields["sse_read_timeout"].flatMap(Int.init)
            // v0.14 — supports_parallel_tool_calls is an optional bool;
            // absent means "use Hermes's default" and stays nil.
            let parallelStr = fields["supports_parallel_tool_calls"]?.lowercased()
            let parallel: Bool? = {
                guard let s = parallelStr else { return nil }
                if s == "true" { return true }
                if s == "false" { return false }
                return nil
            }()
            // v0.15 — mTLS client-certificate config. `client_cert` is normally
            // a scalar PEM-path string but Hermes also accepts an inline list
            // form `[cert, key, password]`; tolerate it by taking the first
            // element. `client_key` is always a scalar path. `ssl_verify` is a
            // bool-or-CA-path string kept verbatim (nil = key absent = default
            // true).
            let clientCert = fields["client_cert"].map { Self.firstListElementOrScalar($0) }
            let clientKey = fields["client_key"].map { Self.unquote($0) }
            let sslVerify = fields["ssl_verify"].map { Self.unquote($0) }
            // v0.20.4 — identity_header. Every rejection below mirrors a
            // `logger.warning(... "— ignoring")` branch of
            // `mcp_tool.py._resolve_identity_header`, so what Scarf shows
            // is what Hermes will actually send:
            //
            //   * missing/blank `name`             → dropped
            //   * `value_from` neither static nor  → dropped (NOT coerced to
            //     profile (typo, wrong type, …)      static: a typo'd source
            //                                        sends no header at all,
            //                                        and showing a static
            //                                        header would be a lie)
            //   * static (incl. the absent/empty   → dropped when `value` is
            //     `value_from` default) …            missing or blank
            //
            // `profile` mode ignores `value` entirely (Hermes substitutes
            // the active profile name at connect time). The raw YAML lines
            // are untouched in every case — this only affects what the model
            // exposes, not what patchMCPServerField preserves.
            let identityHeader: MCPIdentityHeader? = {
                guard let rawName = identityHeaderName else { return nil }
                let name = Self.unquote(rawName).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                // `(raw.get("value_from") or "static")`: absent OR empty ⇒ static.
                let rawSource = identityHeaderValueFrom
                    .map { Self.unquote($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                switch rawSource.isEmpty ? "static" : rawSource {
                case "profile":
                    return MCPIdentityHeader(name: name, valueFrom: .profile, value: "")
                case "static":
                    let value = identityHeaderValue.map { Self.unquote($0) } ?? ""
                    guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    return MCPIdentityHeader(name: name, valueFrom: .static, value: value)
                default:
                    return nil
                }
            }()
            // v0.20.4 — `strict_redirect_headers` is read by Hermes as
            // `bool(config.get("strict_redirect_headers"))`, i.e. Python
            // truthiness over the PyYAML-decoded scalar, not a strict
            // true/false match. So the YAML 1.1 boolean spellings
            // (`yes`/`on`/`y`) and any other non-empty scalar (`1`, a
            // stray string) are all truthy, while the false spellings,
            // `0`, and the null/empty forms are falsy. Key absent stays
            // nil — "unset", which Scarf's writer preserves as an absent
            // key rather than an explicit `false`.
            let strictRedirectHeaders: Bool? = {
                guard let raw = fields["strict_redirect_headers"] else { return nil }
                let s = Self.unquote(raw).trimmingCharacters(in: .whitespaces).lowercased()
                switch s {
                case "", "false", "no", "off", "n", "0", "null", "~":
                    return false
                default:
                    return true
                }
            }()
            let cwd = fields["cwd"].map { Self.unquote($0) }
            let server = HermesMCPServer(
                name: name,
                transport: transport,
                command: fields["command"].map { Self.unquote($0) },
                args: argsList,
                url: fields["url"].map { Self.unquote($0) },
                auth: fields["auth"].map { Self.unquote($0) },
                env: envMap,
                headers: headersMap,
                timeout: timeout,
                connectTimeout: connectTimeout,
                enabled: enabled,
                toolsInclude: includeList,
                toolsExclude: excludeList,
                resourcesEnabled: resources,
                promptsEnabled: prompts,
                hasOAuthToken: false,
                sseReadTimeout: sseReadTimeout,
                supportsParallelToolCalls: parallel,
                clientCert: clientCert,
                clientKey: clientKey,
                sslVerify: sslVerify,
                identityHeader: identityHeader,
                strictRedirectHeaders: strictRedirectHeaders,
                cwd: cwd
            )
            servers.append(server)

            currentName = nil
            fields = [:]
            argsList = []
            envMap = [:]
            headersMap = [:]
            includeList = []
            excludeList = []
            resources = false
            prompts = false
            subSection = nil
            identityHeaderName = nil
            identityHeaderValueFrom = nil
            identityHeaderValue = nil
        }

        /// `key: value` split shared by every scalar site below: trims CRLF,
        /// unquotes the key (a hand-edited `"command":` is the same key), and
        /// drops an unquoted trailing `# comment` from the value.
        func keyValue(_ trimmed: String) -> (key: String, value: String)? {
            guard let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
            let key = Self.unquote(
                String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let value = Self.stripInlineComment(
                String(trimmed[trimmed.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return (key, value)
        }

        for rawLine in location.block.dropFirst() {
            let trimmed = Self.trimYAMLLine(rawLine)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = rawLine.prefix(while: { $0 == " " }).count

            // A quoted entry key CONTAINS no space but is wrapped in quotes;
            // a quoted key with a space in it (`"my server":`) is a legal
            // entry name too, so the no-space test runs on the UNQUOTED name
            // — where it still does its real job of rejecting `key: value`
            // lines that happen to end in a colon.
            if indent == 2, trimmed.hasSuffix(":") {
                let candidate = Self.unquote(String(trimmed.dropLast()))
                let wasQuoted = candidate != String(trimmed.dropLast())
                if wasQuoted || !candidate.contains(" ") {
                    flush()
                    currentName = candidate
                    subSection = nil
                    continue
                }
            }

            guard currentName != nil else { continue }

            if indent == 4 {
                if trimmed.hasPrefix("- ") && subSection == "args" {
                    argsList.append(Self.unquote(Self.stripInlineComment(String(trimmed.dropFirst(2)))))
                    continue
                }
                subSection = nil
                if trimmed.hasSuffix(":") {
                    subSection = Self.unquote(String(trimmed.dropLast()))
                    continue
                }
                if let (key, value) = keyValue(trimmed) {
                    fields[key] = value
                }
                continue
            }

            if indent >= 6 {
                switch subSection {
                case "args":
                    if trimmed.hasPrefix("- ") {
                        argsList.append(Self.unquote(Self.stripInlineComment(String(trimmed.dropFirst(2)))))
                    }
                case "env":
                    if let (key, value) = keyValue(trimmed) {
                        envMap[key] = Self.unquote(value)
                    }
                case "headers":
                    if let (key, value) = keyValue(trimmed) {
                        headersMap[key] = Self.unquote(value)
                    }
                case "tools":
                    if trimmed == "include:" {
                        subSection = "tools.include"
                    } else if trimmed == "exclude:" {
                        subSection = "tools.exclude"
                    } else if trimmed.hasPrefix("resources:") {
                        resources = trimmed.lowercased().hasSuffix("true")
                    } else if trimmed.hasPrefix("prompts:") {
                        prompts = trimmed.lowercased().hasSuffix("true")
                    }
                case "tools.include":
                    if trimmed.hasPrefix("- ") {
                        includeList.append(Self.unquote(String(trimmed.dropFirst(2))))
                    }
                case "tools.exclude":
                    if trimmed.hasPrefix("- ") {
                        excludeList.append(Self.unquote(String(trimmed.dropFirst(2))))
                    }
                case "identity_header":
                    if let (key, value) = keyValue(trimmed) {
                        switch key {
                        case "name": identityHeaderName = value
                        case "value_from": identityHeaderValueFrom = value
                        case "value": identityHeaderValue = value
                        default: break
                        }
                    }
                default:
                    // Any other nested block (unknown v0.20.4+ keys, future
                    // additions) is intentionally NOT parsed into fields —
                    // it's still physically present in `location.block` /
                    // `entryLines` and survives untouched through
                    // patchMCPServerField's line-based mutators, which only
                    // ever touch the specific key they're asked to edit.
                    break
                }
            }
        }

        flush()
        return servers
    }

    // MARK: - MCP YAML: surgical patcher

    /// Surgically rewrite one `mcp_servers` entry, or refuse.
    ///
    /// **Fail-closed, because the blast radius is the whole file.** Every
    /// mutator below is line-based and assumes the exact shape Hermes writes:
    /// the entry header at indent 2, scalars at indent 4, nested blocks at 6
    /// or deeper, spaces only, no block scalars, no anchors. Handed anything
    /// else it used to guess — most damagingly by INSERTING a hardcoded
    /// 4-space line into an entry indented 3, which is not a mis-edit of one
    /// value but a YAML parse error for `config.yaml` as a whole: Hermes
    /// stops reading its own configuration, and the app that broke it is the
    /// one that runs this on every single launch. So an entry whose shape we
    /// don't recognise is left untouched and the patch reports failure.
    ///
    /// Three layers, in order:
    /// 1. `unpatchableReason` gates the entry BEFORE any mutation.
    /// 2. A timestamped backup of `config.yaml` is taken before this
    ///    process's first mutating patch.
    /// 3. The written file is re-verified by an INDEPENDENT structural
    ///    reader (`verifyPatchedConfig`), not by the same naive parser that
    ///    produced the edit, and a failure restores the original bytes.
    ///
    /// - Parameter expecting: exact lines that must appear in the patched
    ///   entry afterwards. The read-back proof for callers that know what
    ///   they wrote; an empty list still gets the structural verification.
    nonisolated private func patchMCPServerField(
        name: String,
        expecting: [String] = [],
        mutate: (inout [String]) -> Void
    ) -> Bool {
        guard let yaml = readFile(context.paths.configYAML) else { return false }
        let location = extractMCPBlock(yaml: yaml)
        guard !location.block.isEmpty else { return false }

        var block = location.block

        // Tabs are checked over the WHOLE block, before the entry is even
        // located. Indent is counted in SPACES everywhere here, so a
        // tab-indented line reads as indent 0 — which ends the entry early,
        // hides the keys below it, and leaves an insert landing in the
        // middle of somebody else's mapping. The entry-level gate below
        // cannot catch that: by then the tabbed lines have already been cut
        // out of the entry.
        if block.contains(where: { $0.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") }) {
            Self.logger.warning(
                "refusing to patch MCP server \(name, privacy: .public): tab indentation in the mcp_servers block"
            )
            return false
        }

        var entryStart = -1
        var entryEnd = block.count
        for (index, line) in block.enumerated() {
            let trimmed = Self.trimYAMLLine(line)
            let indent = line.prefix(while: { $0 == " " }).count
            if entryStart < 0 {
                // A quoted key is the same key: Hermes writes `name:` but a
                // hand-edited `"name":` is valid YAML for the same entry, and
                // failing to match it here made the registrar conclude the
                // server was absent and shell `hermes mcp add` on every
                // launch.
                if indent == 2, trimmed.hasSuffix(":"),
                   Self.unquote(String(trimmed.dropLast())) == name {
                    entryStart = index
                }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if indent <= 2 {
                entryEnd = index
                break
            }
        }
        guard entryStart >= 0 else { return false }

        // Trim trailing blank lines and comments off the entry so inserts land
        // immediately after the entry's last real key, not after intervening
        // comments that conceptually belong to the next entry (or the file
        // footer when this is the last entry in the block).
        while entryEnd > entryStart + 1 {
            let line = block[entryEnd - 1]
            let trimmed = Self.trimYAMLLine(line)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                entryEnd -= 1
            } else {
                break
            }
        }

        var entryLines = Array(block[entryStart..<entryEnd])

        if let reason = Self.unpatchableReason(entryLines: entryLines) {
            Self.logger.warning(
                "refusing to patch MCP server \(name, privacy: .public) in \(self.context.paths.configYAML, privacy: .public): \(reason, privacy: .public)"
            )
            return false
        }

        let namesBefore = Self.entryNames(inYAML: yaml)

        mutate(&entryLines)

        block.replaceSubrange(entryStart..<entryEnd, with: entryLines)

        var combined: [String] = []
        combined.append(contentsOf: location.prefix)
        combined.append(contentsOf: block)
        combined.append(contentsOf: location.suffix)
        let newYAML = combined.joined(separator: "\n")
        guard newYAML != yaml else { return true }

        backUpConfigOnceForThisLaunch(originalText: yaml)
        writeFile(context.paths.configYAML, content: newYAML)

        // Read the file BACK OFF DISK — the write goes through a transport
        // that logs and swallows its failures, so "we built a good string" is
        // not evidence that a good string landed.
        guard let written = readFile(context.paths.configYAML) else {
            Self.logger.error(
                "could not re-read \(self.context.paths.configYAML, privacy: .public) after patching \(name, privacy: .public); restoring"
            )
            writeFile(context.paths.configYAML, content: yaml)
            return false
        }
        if let reason = Self.verifyPatchedConfig(
            text: written, name: name, expecting: expecting, namesBefore: namesBefore
        ) {
            Self.logger.error(
                "patch of MCP server \(name, privacy: .public) failed verification (\(reason, privacy: .public)); restoring \(self.context.paths.configYAML, privacy: .public)"
            )
            writeFile(context.paths.configYAML, content: yaml)
            return false
        }
        return true
    }

    // MARK: - MCP YAML: fail-closed gate + independent verification

    /// Trailing `\r` is framing, not content. `.whitespaces` does NOT
    /// contain it, so every `hasSuffix(":")` / `== "\(name):"` test in this
    /// file silently failed on a CRLF `config.yaml` — the entry became
    /// invisible and the registrar re-ran a 90-second `hermes mcp add` on
    /// every launch, forever.
    nonisolated static func trimYAMLLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop an unquoted trailing `# comment` from a scalar value.
    ///
    /// YAML only starts a comment at a `#` that begins the value or follows
    /// whitespace, and never inside a quoted scalar — both exceptions matter
    /// here, since a `command:` path may legitimately contain a `#`.
    /// Without this, `command: /bin/x  # ours` parsed as the value
    /// `/bin/x  # ours`, which never equals the binary path, so the
    /// registrar re-pointed (rewriting a file Hermes watches) on every
    /// launch and never converged.
    nonisolated static func stripInlineComment(_ value: String) -> String {
        var inSingle = false
        var inDouble = false
        var previous: Character?
        for (offset, char) in value.enumerated() {
            switch char {
            case "'" where !inDouble: inSingle.toggle()
            case "\"" where !inSingle && previous != "\\": inDouble.toggle()
            case "#" where !inSingle && !inDouble:
                if offset == 0 || previous == " " || previous == "\t" {
                    return String(value.prefix(offset))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            default: break
            }
            previous = char
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the line-based mutators must not touch this entry, or `nil` when
    /// its shape is the one they were written for.
    ///
    /// Everything rejected here is legal YAML that Hermes reads fine; the
    /// point is not to judge the file but to know when we are out of our
    /// depth, and to leave a config we don't understand exactly as we found
    /// it rather than half-rewrite it.
    nonisolated static func unpatchableReason(entryLines: [String]) -> String? {
        guard let header = entryLines.first else { return "empty entry" }
        if header.contains("\t") { return "tab in the entry header's indentation" }
        guard header.prefix(while: { $0 == " " }).count == 2 else {
            return "entry header is not at indent 2"
        }
        let headerTrimmed = trimYAMLLine(header)
        guard headerTrimmed.hasSuffix(":") else {
            // `name: {command: x}` — a flow mapping holds the whole entry on
            // one line, and there are no key lines to rewrite.
            return "entry is a flow mapping or has content on the header line"
        }

        var sawFirstKey = false
        for line in entryLines.dropFirst() {
            let trimmed = trimYAMLLine(line)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
            if leading.contains("\t") { return "tab indentation" }
            let indent = leading.count
            // The entry's OWN keys must be at indent 4, which is the indent
            // every mutator writes. An entry whose keys start deeper is
            // consistent YAML that Hermes reads — and into which
            // `replaceOrInsertScalar`, finding no indent-4 key to replace,
            // would insert one, giving a single mapping two indentations and
            // the file a parse error.
            if !sawFirstKey {
                sawFirstKey = true
                guard indent == 4 else {
                    return "the entry's keys are at indent \(indent), not 4"
                }
            }
            // The mutators read indent 4 as "a key of this entry" and 6+ as
            // "inside a nested block". A 3- or 5-space entry is legal YAML
            // that they would both misread AND write back at the wrong
            // indent, mixing two indentations inside one mapping — the parse
            // error that takes the whole file down.
            guard indent == 4 || indent >= 6 else {
                return "unexpected indentation (\(indent) spaces)"
            }
            if trimmed.hasPrefix("- ") || trimmed == "-" { continue }
            if trimmed.hasPrefix("<<:") { return "merge key" }
            if trimmed.hasPrefix("&") || trimmed.hasPrefix("*") {
                return "anchor or alias"
            }
            guard let colon = trimmed.firstIndex(of: ":") else {
                return "line is not a key"
            }
            let value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("&") || value.hasPrefix("*") {
                return "anchor or alias"
            }
            // `key: |` / `key: >-` / `key: |2` — the lines that follow are
            // literal CONTENT whose indentation is part of the value, and
            // every mutator here would read them as keys.
            if let first = value.first, first == "|" || first == ">" {
                let rest = value.dropFirst()
                if rest.isEmpty || rest.allSatisfy({ "+-0123456789".contains($0) }) {
                    return "block scalar"
                }
            }
        }
        return nil
    }

    /// The `mcp_servers` entry names in a config, read by a walker that
    /// shares no code with `parseMCPServersBlock`.
    ///
    /// Deliberately independent: verifying a write by re-running the parser
    /// that produced it proves only that the parser is self-consistent. This
    /// answers the question that actually matters after a surgical edit —
    /// is the block still a block, and are all the servers still in it?
    nonisolated static func entryNames(inYAML yaml: String) -> [String] {
        var names: [String] = []
        var inBlock = false
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = trimYAMLLine(line)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if !inBlock {
                if indent == 0, trimmed.hasPrefix("mcp_servers:") { inBlock = true }
                continue
            }
            if indent == 0 { break }
            if indent == 2, trimmed.hasSuffix(":") {
                names.append(unquote(String(trimmed.dropLast())))
            }
        }
        return names
    }

    /// Why the file we just wrote is not acceptable, or `nil` when it is.
    /// A non-nil answer makes the caller restore the original bytes.
    nonisolated static func verifyPatchedConfig(
        text: String,
        name: String,
        expecting: [String],
        namesBefore: [String]
    ) -> String? {
        let namesAfter = entryNames(inYAML: text)
        guard namesAfter == namesBefore else {
            return "the server list changed (\(namesBefore) → \(namesAfter))"
        }
        guard namesAfter.contains(name) else { return "\(name) is no longer in the block" }

        // Re-cut the entry from the written text and re-run the shape gate:
        // a patch that produced something we could not patch AGAIN is a
        // patch that produced something we no longer understand.
        var entry: [String] = []
        var inEntry = false
        var inBlock = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = trimYAMLLine(line)
            let indent = line.prefix(while: { $0 == " " }).count
            if !inBlock {
                if indent == 0, trimmed.hasPrefix("mcp_servers:") { inBlock = true }
                continue
            }
            if inEntry {
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if indent <= 2 { break }
                entry.append(line)
                continue
            }
            if indent == 2, trimmed.hasSuffix(":"),
               unquote(String(trimmed.dropLast())) == name {
                inEntry = true
                entry.append(line)
            }
        }
        if let reason = unpatchableReason(entryLines: entry) {
            return "the patched entry is malformed: \(reason)"
        }
        // Compared trimmed: the indent is already proven by the shape gate,
        // and a CRLF config carries a `\r` the caller has no reason to know
        // about.
        let normalized = entry.map { trimYAMLLine($0) }
        for expected in expecting where !normalized.contains(trimYAMLLine(expected)) {
            return "expected line is missing: \(trimYAMLLine(expected))"
        }
        return nil
    }

    /// One timestamped copy of `config.yaml` per launch, taken before the
    /// first patch this process performs.
    ///
    /// Per launch rather than per patch: the point is a copy of what the
    /// user had before Scarf touched anything today, and a per-patch backup
    /// would overwrite that with a copy of Scarf's own second edit. Best
    /// effort — a backup we cannot write is not a reason to refuse a change
    /// the user asked for, and the restore path does not depend on it.
    nonisolated private func backUpConfigOnceForThisLaunch(originalText: String) {
        let path = context.paths.configYAML
        guard Self.backedUpConfigPaths.insertIfAbsent(path) else { return }
        let stamp = Self.backupTimestampFormatter.string(from: Date())
        let destination = path + ".scarf-backup-" + stamp
        guard let data = originalText.data(using: .utf8) else { return }
        do {
            try transport.writeFile(destination, data: data)
            Self.logger.info("backed up \(path, privacy: .public) to \(destination, privacy: .public)")
        } catch {
            Self.logger.warning(
                "could not back up \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Config paths this process has already backed up. A tiny lock-guarded
    /// set rather than a `@MainActor` flag, because every caller here is
    /// `nonisolated` and runs off-main by charter C10.
    private final class PathSet: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        /// - Returns: `true` when the path was NOT already present.
        func insertIfAbsent(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.insert(path).inserted
        }
    }
    private static let backedUpConfigPaths = PathSet()

    // MARK: - MCP YAML: mutators

    /// Replace (or add) one `indent-4` scalar in an entry.
    ///
    /// Safe to write a hardcoded four-space line here ONLY because
    /// `patchMCPServerField` has already refused every entry that isn't
    /// four-space indented — this used to insert into a 3-space entry and
    /// hand Hermes a `config.yaml` it could no longer parse. See
    /// `unpatchableReason`.
    nonisolated private static func replaceOrInsertScalar(key: String, value: String, in lines: inout [String]) {
        // entry header is at lines[0] at indent 2. Scalars live at indent 4.
        for index in 1..<lines.count {
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = Self.trimYAMLLine(line)
            if indent == 4, trimmed.hasPrefix(key + ":") || trimmed == key + ":" {
                // Keep the line ending this file uses: rewriting one line of
                // a CRLF config with an LF one is a diff on a line nobody
                // edited, in a file the user may well have in git.
                let carriageReturn = line.hasSuffix("\r") ? "\r" : ""
                lines[index] = "    \(key): \(value)\(carriageReturn)"
                return
            }
            if indent <= 2 && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                break
            }
        }
        // Insert right after header.
        lines.insert("    \(key): \(value)", at: 1)
    }

    nonisolated private static func removeScalar(key: String, in lines: inout [String]) {
        var removeIndex: Int?
        for index in 1..<lines.count {
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = Self.trimYAMLLine(line)
            if indent == 4, trimmed.hasPrefix(key + ":") || trimmed == key + ":" {
                removeIndex = index
                break
            }
            if indent <= 2 && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                break
            }
        }
        if let removeIndex {
            lines.remove(at: removeIndex)
        }
    }

    nonisolated private static func replaceOrInsertSubMap(header: String, map: [String: String], in lines: inout [String]) {
        var headerIndex: Int?
        var removeEnd: Int?
        for index in 1..<lines.count {
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = Self.trimYAMLLine(line)
            if indent == 4 && trimmed == "\(header):" {
                headerIndex = index
                continue
            }
            if headerIndex != nil {
                if indent >= 6 {
                    continue
                } else if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                } else {
                    removeEnd = index
                    break
                }
            }
        }

        var newLines: [String] = []
        if map.isEmpty {
            if let headerIndex, let end = removeEnd {
                lines.removeSubrange(headerIndex..<end)
            } else if let headerIndex {
                lines.removeSubrange(headerIndex..<lines.count)
            }
            return
        }

        newLines.append("    \(header):")
        for key in map.keys.sorted() {
            let value = map[key] ?? ""
            newLines.append("      \(key): \(yamlScalar(value))")
        }

        if let headerIndex {
            let end = removeEnd ?? lines.count
            lines.replaceSubrange(headerIndex..<end, with: newLines)
        } else {
            // Insert just before the first indent<=2 line we find after the header, else at end.
            var insertAt = lines.count
            for index in 1..<lines.count {
                let line = lines[index]
                let indent = line.prefix(while: { $0 == " " }).count
                let trimmed = Self.trimYAMLLine(line)
                if indent <= 2 && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    insertAt = index
                    break
                }
            }
            lines.insert(contentsOf: newLines, at: insertAt)
        }
    }

    /// Writes/removes the `identity_header:` nested block. Scoped narrowly
    /// to lines at indent==4 matching exactly `"identity_header:"` so it
    /// never touches an unrelated sibling block that also happens to be
    /// nested (e.g. a hand-authored `tools:` or a future unknown key) — the
    /// same containment discipline as `replaceOrInsertSubMap` /
    /// `replaceOrInsertToolsBlock`, which is what the regression test in
    /// HermesFileServiceConfigParityTests pins.
    nonisolated private static func replaceOrInsertIdentityHeader(header: MCPIdentityHeader?, in lines: inout [String]) {
        var headerIndex: Int?
        var removeEnd: Int?
        for index in 1..<lines.count {
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = Self.trimYAMLLine(line)
            if indent == 4 && trimmed == "identity_header:" {
                headerIndex = index
                continue
            }
            if headerIndex != nil {
                if indent >= 6 {
                    continue
                } else if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                } else {
                    removeEnd = index
                    break
                }
            }
        }

        guard let header, !header.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            if let headerIndex, let end = removeEnd {
                lines.removeSubrange(headerIndex..<end)
            } else if let headerIndex {
                lines.removeSubrange(headerIndex..<lines.count)
            }
            return
        }

        var newLines: [String] = ["    identity_header:"]
        newLines.append("      name: \(yamlScalar(header.name))")
        newLines.append("      value_from: \(header.valueFrom.rawValue)")
        if header.valueFrom == .static {
            newLines.append("      value: \(yamlScalar(header.value))")
        }

        if let headerIndex {
            let end = removeEnd ?? lines.count
            lines.replaceSubrange(headerIndex..<end, with: newLines)
        } else {
            var insertAt = lines.count
            for index in 1..<lines.count {
                let line = lines[index]
                let indent = line.prefix(while: { $0 == " " }).count
                let trimmed = Self.trimYAMLLine(line)
                if indent <= 2 && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    insertAt = index
                    break
                }
            }
            lines.insert(contentsOf: newLines, at: insertAt)
        }
    }

    nonisolated private static func replaceOrInsertToolsBlock(include: [String], exclude: [String], resources: Bool, prompts: Bool, in lines: inout [String]) {
        var headerIndex: Int?
        var removeEnd: Int?
        for index in 1..<lines.count {
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = Self.trimYAMLLine(line)
            if indent == 4 && trimmed == "tools:" {
                headerIndex = index
                continue
            }
            if headerIndex != nil {
                if indent >= 6 {
                    continue
                } else if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                } else {
                    removeEnd = index
                    break
                }
            }
        }

        var newLines: [String] = ["    tools:"]
        newLines.append("      include:")
        for tool in include { newLines.append("        - \(yamlScalar(tool))") }
        newLines.append("      exclude:")
        for tool in exclude { newLines.append("        - \(yamlScalar(tool))") }
        newLines.append("      resources: \(resources ? "true" : "false")")
        newLines.append("      prompts: \(prompts ? "true" : "false")")

        if let headerIndex {
            let end = removeEnd ?? lines.count
            lines.replaceSubrange(headerIndex..<end, with: newLines)
        } else {
            var insertAt = lines.count
            for index in 1..<lines.count {
                let line = lines[index]
                let indent = line.prefix(while: { $0 == " " }).count
                let trimmed = Self.trimYAMLLine(line)
                if indent <= 2 && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    insertAt = index
                    break
                }
            }
            lines.insert(contentsOf: newLines, at: insertAt)
        }
    }

    nonisolated static func yamlScalar(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        // YAML 1.2 reserved indicators that change meaning at the start of a
        // scalar: @ * & ? | > ! % , [ ] { } < ` ' " — plus space (would be
        // trimmed) and dash (looks like a sequence). Anything starting with
        // one of these must be quoted or YAML treats the value as an alias,
        // tag, flow collection, etc., and parsing breaks.
        let reservedFirstChars: Set<Character> = [
            "@", "*", "&", "?", "|", ">", "!", "%", ",",
            "[", "]", "{", "}", "<", "`", "'", "\""
        ]
        let firstCharNeedsQuoting = value.first.map { reservedFirstChars.contains($0) } ?? false
        let needsQuoting = value.contains(":") || value.contains("#") || value.contains("\"")
            || value.hasPrefix(" ") || value.hasSuffix(" ") || value.hasPrefix("-")
            || ["true", "false", "null", "yes", "no"].contains(value.lowercased())
            || firstCharNeedsQuoting
        if needsQuoting {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }

    /// The inverse of ``yamlScalar``.
    ///
    /// It used to strip the quotes and stop, which made the pair asymmetric
    /// for the one thing quoting exists to carry: `yamlScalar` writes
    /// `\\` for a backslash and `\"` for a quote, and reading them back
    /// verbatim turned `/a\b` into `/a\\b` one save later, and again the
    /// save after that. The registrar compares this value against a real
    /// filesystem path, so an unescape that doesn't undo the escape is a
    /// permanent "the command moved" — a rewrite of a file Hermes watches,
    /// every launch, forever.
    nonisolated static func unquote(_ value: String) -> String {
        let v = value
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            // Double-quoted YAML: `\\` and `\"` are the escapes we emit.
            // Other escape sequences are left as written rather than
            // half-decoded — we never produce them, and inventing a partial
            // decoder for `\n`/`\uXXXX` would be a new way to be wrong.
            var out = ""
            var escaped = false
            for char in v.dropFirst().dropLast() {
                if escaped {
                    if char != "\\" && char != "\"" { out.append("\\") }
                    out.append(char)
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else {
                    out.append(char)
                }
            }
            if escaped { out.append("\\") }
            return out
        }
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
            // Single-quoted YAML has exactly one escape: `''` is a quote.
            return String(v.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return v
    }

    /// Normalizes an `client_cert`-style value that may be either a scalar
    /// path or an inline YAML list (`[cert, key, password]`). For a list,
    /// returns the first element (the cert path); for a scalar, returns it
    /// unquoted. Tolerant of whitespace and quoting on the list element.
    nonisolated private static func firstListElementOrScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return unquote(trimmed) }
        let inner = trimmed.dropFirst().drop(while: { $0 == " " })
        let body = inner.hasSuffix("]") ? inner.dropLast() : Substring(inner)
        let firstRaw = body.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        return unquote(firstRaw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Hermes Process

    nonisolated func isHermesRunning() -> Bool {
        hermesPID() != nil
    }

    nonisolated func hermesPID() -> pid_t? {
        switch hermesPIDResult() {
        case .success(let pid): return pid
        case .failure: return nil
        }
    }

    /// Error-surfacing variant. `.success(nil)` means `pgrep` ran successfully
    /// and found no Hermes gateway process (Hermes is genuinely not running).
    /// `.failure` means we couldn't probe at all (pgrep missing, connection
    /// down, permission issue) — a *different* UX from "not running".
    ///
    /// The regex narrows the match to the gateway daemon shape so unrelated
    /// commands that happen to contain "hermes" — `hermes acp` chat sessions,
    /// `hermes -z` one-shots, log tails, README readers — don't get flagged
    /// as "Hermes is running" in the dashboard banner. Two alternations cover
    /// both invocation forms: the python-module path (`python -m
    /// hermes_cli.main gateway run …`) and the script-path form
    /// (`/usr/local/bin/hermes gateway run …`). All callers semantically
    /// want the gateway PID specifically — `stopHermes()` issues
    /// `hermes gateway stop` first and only falls back to killing this
    /// PID, and the dashboard health probe only cares about the gateway.
    nonisolated func hermesPIDResult() -> Result<pid_t?, Error> {
        do {
            let result = try transport.runProcess(
                executable: "/usr/bin/pgrep",
                args: ["-f", #"(^|[[:space:]])-m[[:space:]]+hermes_cli\.main[[:space:]]+gateway[[:space:]]+run([[:space:]]|$)|(^|[[:space:]/])hermes[[:space:]]+gateway[[:space:]]+run([[:space:]]|$)"#],
                stdin: nil,
                timeout: 5
            )
            // pgrep exits 1 when nothing matches — that's "not running", NOT an
            // error. Anything else (127=command not found, 255=ssh failure) is.
            if result.exitCode == 0 {
                if let firstLine = result.stdoutString
                    .components(separatedBy: "\n")
                    .first(where: { !$0.isEmpty }),
                   let pid = pid_t(firstLine.trimmingCharacters(in: .whitespaces)) {
                    return .success(pid)
                }
                return .success(nil)
            } else if result.exitCode == 1 {
                return .success(nil)   // genuinely not running
            } else {
                let err = TransportError.commandFailed(exitCode: result.exitCode, stderr: result.stderrString)
                Self.logger.warning("pgrep failed (exit \(result.exitCode)): \(result.stderrString, privacy: .public)")
                return .failure(err)
            }
        } catch {
            Self.logger.warning("pgrep transport error: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    @discardableResult
    nonisolated func stopHermes() -> Bool {
        // v0.9.0 fixed `hermes gateway stop` so it issues `launchctl bootout` and
        // waits for exit. Use the CLI to avoid racing launchd's KeepAlive respawn.
        if runHermesCLI(args: ["gateway", "stop"]).exitCode == 0 {
            return true
        }
        guard let pid = hermesPID() else { return false }
        // For remote we can't issue a raw `kill(2)` — route through `kill(1)`
        // via the transport. Local uses the syscall for its minimal overhead.
        if context.isRemote {
            let result = try? transport.runProcess(
                executable: "/bin/kill",
                args: ["-TERM", String(pid)],
                stdin: nil,
                timeout: 5
            )
            return (result?.exitCode ?? -1) == 0
        }
        return kill(pid, SIGTERM) == 0
    }

    nonisolated func hermesBinaryPath() -> String? {
        // Single source of truth for install-location candidates lives in
        // HermesPathSet.hermesBinaryCandidates — keeps pipx/brew/manual lookups
        // consistent across the app.
        return HermesPathSet.hermesBinaryCandidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Keys queried from the user's login shell. PATH is needed because .app
    /// bundles launched from Finder/Dock get a minimal PATH (no Homebrew, no
    /// nvm, no asdf, no mise). The credential keys are needed because Hermes
    /// resolves AI provider auth by reading env vars — a GUI-launched Scarf
    /// subprocess sees none of the `export ANTHROPIC_API_KEY=…` lines from
    /// the user's shell init files.
    nonisolated private static let shellEnvKeys: [String] = [
        "PATH",
        "ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "ANTHROPIC_BASE_URL",
        "OPENAI_API_KEY", "OPENAI_BASE_URL",
        "OPENROUTER_API_KEY",
        "GEMINI_API_KEY", "GOOGLE_API_KEY",
        "GROQ_API_KEY", "MISTRAL_API_KEY", "XAI_API_KEY",
        "CLAUDE_CODE_OAUTH_TOKEN",
        // SSH agent socket — set by 1Password / Secretive / a manual
        // `ssh-add` in the user's shell rc. GUI-launched apps don't inherit
        // these by default, so without harvesting them here, `ssh` spawned
        // from Scarf can't reach the agent and authentication fails with
        // "Permission denied" (exit 255) even though terminal ssh works.
        "SSH_AUTH_SOCK", "SSH_AGENT_PID"
    ]

    /// Env vars harvested from the user's login shell. Computed once and cached.
    ///
    /// Probing strategy — two attempts, best result wins:
    /// 1. `zsh -l -i` (login + interactive) — sources BOTH `.zprofile` and
    ///    `.zshrc`, which is required for nvm/asdf/mise PATH on most setups
    ///    (those tools inject PATH from `.zshrc`, not `.zprofile`).
    ///    Interactive mode can hang on prompt frameworks (oh-my-zsh,
    ///    powerlevel10k, starship) so we suppress prompts via env and bound
    ///    with a 5-second timeout.
    /// 2. If that yields no PATH (timed out / prompt framework broke it),
    ///    fall back to `zsh -l` (login only) with a 3-second timeout.
    /// 3. If that also fails, hardcoded sane-default PATH; no credentials.
    nonisolated private static let enrichedShellEnv: [String: String] = {
        // Build a shell script that prints `KEY\0VALUE\0` for each key.
        // Using printf with \0 as separator lets us unambiguously split the
        // output even if a value contains newlines.
        let script = shellEnvKeys.map { key in
            #"printf '%s\0%s\0' "\#(key)" "$\#(key)""#
        }.joined(separator: "; ")

        // Attempt 1: login + interactive (covers nvm/asdf/mise in .zshrc).
        if let result = runShellProbe(script: script, interactive: true, timeout: 5.0),
           result["PATH"] != nil {
            return result
        }
        // Attempt 2: login only (safe fallback if interactive hangs).
        if let result = runShellProbe(script: script, interactive: false, timeout: 3.0),
           result["PATH"] != nil {
            return result
        }

        // Fallback when the login shell can't be queried (zsh missing,
        // sandbox restriction, timeout). Covers Apple Silicon + Intel
        // Homebrew plus the standard system paths. No credential env is
        // inferred — the user will see the missing-credentials hint instead.
        let home = NSHomeDirectory()
        let fallbackPath = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        return ["PATH": fallbackPath]
    }()

    /// Runs a zsh probe with the given script and returns the parsed
    /// `KEY\0VALUE\0`-delimited output. Returns nil on timeout/failure.
    /// When `interactive` is true, injects env vars that suppress common
    /// prompt frameworks so the shell doesn't hang waiting for terminal setup.
    nonisolated private static func runShellProbe(script: String, interactive: Bool, timeout: TimeInterval) -> [String: String]? {
        let pipe = Pipe()
        let errPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = interactive ? ["-l", "-i", "-c", script] : ["-l", "-c", script]
        process.standardOutput = pipe
        process.standardError = errPipe

        if interactive {
            // Defang prompt frameworks so -i doesn't hang on async prompt init.
            // We still inherit the parent env (HOME, USER etc.) so rc files resolve.
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "dumb"                       // disables fancy prompt setup
            env["PS1"] = ""
            env["PROMPT"] = ""
            env["RPROMPT"] = ""
            env["POWERLEVEL9K_INSTANT_PROMPT"] = "off" // p10k
            env["STARSHIP_DISABLE"] = "1"              // starship (some versions)
            env["ZSH_DISABLE_COMPFIX"] = "true"        // oh-my-zsh compaudit hang
            process.environment = env
        }

        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForWriting.close()
        }
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                // Brief grace period for SIGTERM to take; then the defer
                // cleanup closes the pipes regardless.
                Thread.sleep(forTimeInterval: 0.1)
                return nil
            }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            var result: [String: String] = [:]
            let parts = data.split(separator: 0, omittingEmptySubsequences: false)
            var i = 0
            while i + 1 < parts.count {
                if let key = String(data: Data(parts[i]), encoding: .utf8),
                   let value = String(data: Data(parts[i + 1]), encoding: .utf8),
                   !key.isEmpty, !value.isEmpty {
                    result[key] = value
                }
                i += 2
            }
            return result.isEmpty ? nil : result
        } catch {
            return nil
        }
    }

    /// Environment to hand any subprocess that may itself spawn user-installed
    /// binaries (Hermes spawning MCP servers, ACP tool calls, etc.). Starts
    /// from ProcessInfo.environment and overlays PATH + allowlisted credential
    /// env vars harvested from the user's login shell.
    nonisolated static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in enrichedShellEnv where !value.isEmpty {
            // Shell wins for PATH (we explicitly want the enriched one). For
            // credential keys, also let the shell win — GUI env rarely has
            // them, and if it does, the shell-exported value is usually the
            // one the user actually maintains.
            env[key] = value
        }
        return env
    }

    /// True if any known AI-provider credential is reachable. Hermes itself
    /// resolves credentials from four locations at runtime, so the preflight
    /// mirrors that set to avoid false "no credentials" warnings:
    ///   1. Current process env + login-shell env (queried once at startup)
    ///   2. `~/.hermes/.env`
    ///   3. `~/.hermes/auth.json` — Credential Pools (v1.6+ blessed flow)
    ///   4. `~/.hermes/config.yaml` — embedded `api_key:` for auxiliary /
    ///      delegation tasks
    /// Used by Chat to warn the user before `hermes acp` fails on send with
    /// "No Anthropic credentials found".
    ///
    /// **Local context:** also checks Scarf's process / login-shell env.
    /// **Remote context:** skips that step — our process env has nothing to
    /// do with the remote `hermes acp`'s runtime env. The remote `.env` /
    /// `auth.json` / `config.yaml` are still checked through the transport.
    nonisolated func hasAnyAICredential() -> Bool {
        let credentialKeys = Self.shellEnvKeys.filter { $0 != "PATH" && $0 != "ANTHROPIC_BASE_URL" && $0 != "OPENAI_BASE_URL" }

        if !context.isRemote {
            let env = Self.enrichedEnvironment()
            for key in credentialKeys {
                if let value = env[key], !value.isEmpty {
                    return true
                }
            }
        }
        // Scan .env (via transport — local file or scp) for KEY= lines.
        // Uses a simple substring check — good enough for a preflight hint;
        // hermes itself does the real parse.
        if let envText = readFile(context.paths.envFile) {
            for line in envText.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                for key in credentialKeys where trimmed.hasPrefix("\(key)=") || trimmed.hasPrefix("export \(key)=") {
                    // Must have a non-empty value after `=`
                    if let eq = trimmed.firstIndex(of: "="),
                       trimmed.index(after: eq) < trimmed.endIndex {
                        let value = trimmed[trimmed.index(after: eq)...]
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                        if !value.isEmpty { return true }
                    }
                }
            }
        }
        // Scan auth.json. Two shapes need to count as "credential present":
        //
        //   1. credential_pool.<provider>[].access_token
        //      — written by Configure → Credential Pools (manual key entry,
        //        round-robin / least-used routing).
        //
        //   2. providers.<name>.access_token
        //      — written by `hermes auth add <name>` for OAuth-authed
        //        providers (Nous Portal, Spotify, GitHub Copilot ACP, etc.).
        //        Pre-fix this was ignored, so a user with only Nous OAuth
        //        kept seeing the "No AI provider credentials" banner even
        //        after a successful Nous sign-in.
        //
        // Defensive parse: malformed input falls through to the next check.
        if let data = readFileData(context.paths.authJSON),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let pool = root["credential_pool"] as? [String: Any] {
                for (_, entries) in pool {
                    guard let list = entries as? [[String: Any]] else { continue }
                    for cred in list {
                        if let token = cred["access_token"] as? String, !token.isEmpty {
                            return true
                        }
                    }
                }
            }
            if let providers = root["providers"] as? [String: Any] {
                for (_, value) in providers {
                    guard let entry = value as? [String: Any] else { continue }
                    if let token = entry["access_token"] as? String, !token.isEmpty {
                        return true
                    }
                    // Some auth records (Spotify) carry only a refresh
                    // token until the first access-token mint — count
                    // that too so we don't false-negative seconds-old
                    // OAuth flows.
                    if let refresh = entry["refresh_token"] as? String, !refresh.isEmpty {
                        return true
                    }
                }
            }
        }
        // Scan config.yaml for `api_key:` lines with a non-empty value.
        // Covers both `auxiliary.<task>.api_key` and `delegation.api_key`
        // without needing to parse YAML structure.
        if let text = readFile(context.paths.configYAML) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("api_key:") else { continue }
                let value = trimmed.dropFirst("api_key:".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !value.isEmpty { return true }
            }
        }
        return false
    }

    /// Persist the primary model + provider to `config.yaml` in one call.
    /// Wraps two `hermes config set` invocations because Hermes doesn't
    /// expose a combined "set model" command.
    ///
    /// LEGACY — iOS `ChatView`'s preflight is the only remaining caller
    /// (t-9657430b). Every Mac writer routes through
    /// `LocalModelConfigPlan` + `applyModelConfigPlan(_:)` instead: this
    /// method never clears the local-managed keys, so switching away
    /// from a local provider through it strands a stale
    /// `model.base_url`/`api_key`/`api_mode`/`context_length`. Don't
    /// add new call sites.
    ///
    /// Returns `true` only if both writes succeed. If the second write
    /// fails the first is left in place — `model.default` without a
    /// matching `model.provider` is no worse than the all-empty state we
    /// started in, and the next preflight pass will re-prompt anyway.
    @discardableResult
    nonisolated func setModelAndProvider(model: String, provider: String) -> Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespaces)
        guard !trimmedProvider.isEmpty else { return false }

        let providerResult = runHermesCLI(args: ["config", "set", "model.provider", trimmedProvider], timeout: 30)
        guard providerResult.exitCode == 0 else {
            Self.logger.warning("hermes config set model.provider failed: \(providerResult.output, privacy: .public)")
            return false
        }
        // Subscription-gated overlay providers (Nous Portal) accept an
        // empty model — Hermes picks its own default. Skip the model
        // write in that case rather than persisting the empty string,
        // which Hermes would treat as "unset" and the preflight would
        // catch again on the next start.
        guard !trimmedModel.isEmpty else { return true }

        let modelResult = runHermesCLI(args: ["config", "set", "model.default", trimmedModel], timeout: 30)
        guard modelResult.exitCode == 0 else {
            Self.logger.warning("hermes config set model.default failed: \(modelResult.output, privacy: .public)")
            return false
        }
        return true
    }

    /// Execute a `LocalModelConfigPlan` — the ordered `hermes config set`
    /// operations for a model-picker save. Stops at the first failing
    /// operation and returns `false`. The plan's ordering is
    /// crash/abort-safe (see the plan type): local saves commit
    /// `model.provider` last and remote saves clear stale local keys
    /// last, so no abort prefix ever leaves `provider: <local alias>`
    /// without its `model.base_url` — the state where Hermes silently
    /// reroutes the chat to OpenRouter.
    @discardableResult
    nonisolated func applyModelConfigPlan(_ operations: [LocalModelConfigPlan.Operation]) -> Bool {
        for operation in operations {
            let result = runHermesCLI(args: operation.cliArguments, timeout: 30)
            guard result.exitCode == 0 else {
                // Log key only — a .set(model.api_key, …) value is a secret.
                let key = operation.cliArguments.count > 2 ? operation.cliArguments[2] : "?"
                Self.logger.warning("hermes config set \(key, privacy: .public) failed (exit \(result.exitCode)): \(result.output, privacy: .public)")
                return false
            }
        }
        return true
    }

    @discardableResult
    nonisolated func runHermesCLI(args: [String], timeout: TimeInterval = 60, stdinInput: String? = nil) -> (exitCode: Int32, output: String) {
        // Resolve the executable path — for remote, prefer the cached
        // `hermesBinaryHint` on the SSHConfig (populated by the Test
        // Connection probe) and fall back to bare `hermes` which relies on
        // the remote user's `$PATH`.
        let binary: String
        if context.isRemote {
            binary = context.paths.hermesBinary
        } else {
            guard let local = hermesBinaryPath() else { return (-1, "") }
            binary = local
        }

        let stdinData = stdinInput?.data(using: .utf8)
        do {
            let result = try transport.runProcess(
                executable: binary,
                args: args,
                stdin: stdinData,
                timeout: timeout
            )
            // Match the legacy signature: combined stdout+stderr in one
            // String so callers that grep through output don't need to
            // change. Stderr after stdout mirrors what the old Process impl
            // produced since both pipes were drained in that order.
            let combined = result.stdoutString + result.stderrString
            return (result.exitCode, combined)
        } catch let error as TransportError {
            return (-1, error.diagnosticStderr.isEmpty
                ? (error.errorDescription ?? "transport error")
                : error.diagnosticStderr)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    /// Split-stream variant of `runHermesCLI`. Use this when you need to
    /// parse stdout (e.g. JSON output) without stderr contamination, and
    /// surface stderr separately as a user-facing error message. Transport
    /// failures land in `stderr` with an empty `stdout`.
    @discardableResult
    nonisolated func runHermesCLISplit(args: [String], timeout: TimeInterval = 60, stdinInput: String? = nil) -> (exitCode: Int32, stdout: String, stderr: String) {
        let binary: String
        if context.isRemote {
            binary = context.paths.hermesBinary
        } else {
            guard let local = hermesBinaryPath() else { return (-1, "", "hermes binary not found") }
            binary = local
        }

        let stdinData = stdinInput?.data(using: .utf8)
        do {
            let result = try transport.runProcess(
                executable: binary,
                args: args,
                stdin: stdinData,
                timeout: timeout
            )
            return (result.exitCode, result.stdoutString, result.stderrString)
        } catch let error as TransportError {
            let message = error.diagnosticStderr.isEmpty
                ? (error.errorDescription ?? "transport error")
                : error.diagnosticStderr
            return (-1, "", message)
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }

    /// Raw-bytes variant of `runHermesCLISplit`. Use this when stdout is a
    /// *payload* to be written to disk rather than text to be parsed —
    /// session export pipes JSONL out of `hermes sessions export -` and
    /// writes it to a file on the user's Mac, so it must not round-trip
    /// through `String` (lossy on any non-UTF8 byte) and must never have
    /// stderr merged into it (that would corrupt the JSONL outright).
    /// Transport failures land in `stderr` with empty `stdout`.
    @discardableResult
    nonisolated func runHermesCLIData(args: [String], timeout: TimeInterval = 60, stdinInput: String? = nil) -> (exitCode: Int32, stdout: Data, stderr: String) {
        let binary: String
        if context.isRemote {
            binary = context.paths.hermesBinary
        } else {
            guard let local = hermesBinaryPath() else { return (-1, Data(), "hermes binary not found") }
            binary = local
        }

        let stdinData = stdinInput?.data(using: .utf8)
        do {
            let result = try transport.runProcess(
                executable: binary,
                args: args,
                stdin: stdinData,
                timeout: timeout
            )
            return (result.exitCode, result.stdout, result.stderrString)
        } catch let error as TransportError {
            let message = error.diagnosticStderr.isEmpty
                ? (error.errorDescription ?? "transport error")
                : error.diagnosticStderr
            return (-1, Data(), message)
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
    }

    // MARK: - File I/O

    /// Read a UTF-8 text file through the transport. Missing files and any
    /// transport error surface as `nil` — callers that don't need the
    /// specific error reason keep using this. New call sites that want to
    /// show a user-actionable message should use `readFileResult`.
    nonisolated private func readFile(_ path: String) -> String? {
        switch readFileResult(path) {
        case .success(let s):
            return s
        case .failure:
            return nil
        }
    }

    nonisolated private func readFileData(_ path: String) -> Data? {
        switch readFileDataResult(path) {
        case .success(let d):
            return d
        case .failure:
            return nil
        }
    }

    /// Error-surfacing read. Returns the decoded text on success, or the
    /// underlying `TransportError` (or raw error for local failures) on
    /// failure. Every failure is also logged via `os.Logger` — the warning
    /// trail in Console.app is how we diagnose "connection green, data
    /// empty" bug reports without needing to wire the error through every
    /// existing call site.
    nonisolated func readFileResult(_ path: String) -> Result<String, Error> {
        switch readFileDataResult(path) {
        case .success(let data):
            guard let s = String(data: data, encoding: .utf8) else {
                let err = TransportError.fileIO(path: path, underlying: "file is not valid UTF-8")
                Self.logger.warning("readFile(\(path, privacy: .public)): not UTF-8")
                return .failure(err)
            }
            return .success(s)
        case .failure(let err):
            return .failure(err)
        }
    }

    nonisolated func readFileDataResult(_ path: String) -> Result<Data, Error> {
        do {
            let data = try transport.readFile(path)
            return .success(data)
        } catch {
            // Don't log "No such file" — that's a routine, expected case
            // for optional files (skill.yaml, gateway_state.json before
            // Hermes starts, ~/.hermes/memories/USER.md on fresh installs,
            // etc.). The caller still gets the Result.failure so it can
            // distinguish missing from present-but-unreadable.
            // Log everything else — permission denied, connection drops,
            // sqlite3 missing — since those are actionable diagnostics.
            if !Self.isFileNotFound(error) {
                Self.logger.warning("readFile(\(path, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
            return .failure(error)
        }
    }

    /// `true` iff the error represents "file does not exist" as opposed to
    /// a permission / transport / parse failure. Used to suppress routine
    /// logging for optional files while still surfacing real problems.
    nonisolated private static func isFileNotFound(_ error: Error) -> Bool {
        if let transportErr = error as? TransportError,
           case .fileIO(_, let underlying) = transportErr {
            return underlying.lowercased().contains("no such file")
        }
        // Cocoa NSFileNoSuchFileError (returned by LocalTransport when
        // reading a missing file via FileManager).
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 260 { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == 2 { return true }   // ENOENT
        return false
    }

    /// Write a UTF-8 text file atomically through the transport. Matches the
    /// old pre-transport behavior (print + swallow on error) because the
    /// callers don't have a UI path for surfacing I/O failures — that's
    /// planned for Phase 4.
    nonisolated private func writeFile(_ path: String, content: String) {
        guard let data = content.data(using: .utf8) else { return }
        do {
            try transport.writeFile(path, data: data)
        } catch {
            Self.logger.warning("Failed to write \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
