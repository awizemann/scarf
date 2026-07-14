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
                sslVerify: server.sslVerify
            )
        }
    }

    /// Creates the server entry via `hermes mcp add` with only the command (no args).
    /// Args are written separately via `setMCPServerArgs` to avoid argparse issues with `-`-prefixed args like `-y`.
    /// Pipes `y\n` because the CLI prompts to save even when the initial connection check fails (which it will, since we intentionally add no args first).
    @discardableResult
    nonisolated func addMCPServerStdio(name: String, command: String, args: [String]) -> (exitCode: Int32, output: String) {
        let addResult = runHermesCLI(
            args: ["mcp", "add", name, "--command", command],
            timeout: 45,
            stdinInput: "y\ny\ny\n"
        )
        guard addResult.exitCode == 0 else { return addResult }
        if !args.isEmpty {
            _ = setMCPServerArgs(name: name, args: args)
        }
        return addResult
    }

    @discardableResult
    nonisolated func addMCPServerHTTP(name: String, url: String, auth: String?) -> (exitCode: Int32, output: String) {
        var cliArgs: [String] = ["mcp", "add", name, "--url", url]
        if let auth, !auth.isEmpty {
            cliArgs.append(contentsOf: ["--auth", auth])
        }
        return runHermesCLI(args: cliArgs, timeout: 45, stdinInput: "y\ny\ny\n")
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
    nonisolated func addMCPServerSSE(name: String, url: String, sseReadTimeout: Int?) -> (exitCode: Int32, output: String) {
        let addResult = runHermesCLI(
            args: ["mcp", "add", name, "--url", url],
            timeout: 45,
            stdinInput: "y\ny\ny\n"
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

    @discardableResult
    nonisolated func setMCPServerArgs(name: String, args: [String]) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertList(header: "args", items: args, in: &entryLines)
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
        let hasFailureMarker = output.contains("✗")
            || output.range(of: "Connection failed", options: .caseInsensitive) != nil
            || output.range(of: "No such file or directory", options: .caseInsensitive) != nil
            || output.range(of: "Error:", options: .caseInsensitive) != nil
        return MCPTestResult(
            serverName: name,
            succeeded: result.0 == 0 && !hasFailureMarker,
            output: output,
            tools: tools,
            elapsed: elapsed
        )
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
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 && trimmed.contains(":") {
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
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
                sslVerify: sslVerify
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
        }

        for rawLine in location.block.dropFirst() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = rawLine.prefix(while: { $0 == " " }).count

            if indent == 2 && trimmed.hasSuffix(":") && !trimmed.contains(" ") {
                flush()
                currentName = String(trimmed.dropLast())
                subSection = nil
                continue
            }

            guard currentName != nil else { continue }

            if indent == 4 {
                if trimmed.hasPrefix("- ") && subSection == "args" {
                    argsList.append(Self.unquote(String(trimmed.dropFirst(2))))
                    continue
                }
                subSection = nil
                if trimmed.hasSuffix(":") {
                    subSection = String(trimmed.dropLast())
                    continue
                }
                if let colonIdx = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    fields[key] = value
                }
                continue
            }

            if indent >= 6 {
                switch subSection {
                case "args":
                    if trimmed.hasPrefix("- ") {
                        argsList.append(Self.unquote(String(trimmed.dropFirst(2))))
                    }
                case "env":
                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                        envMap[key] = Self.unquote(value)
                    }
                case "headers":
                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
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
                default:
                    break
                }
            }
        }

        flush()
        return servers
    }

    // MARK: - MCP YAML: surgical patcher

    nonisolated private func patchMCPServerField(name: String, mutate: (inout [String]) -> Void) -> Bool {
        guard let yaml = readFile(context.paths.configYAML) else { return false }
        let location = extractMCPBlock(yaml: yaml)
        guard !location.block.isEmpty else { return false }

        var block = location.block

        var entryStart = -1
        var entryEnd = block.count
        for (index, line) in block.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if entryStart < 0 {
                if indent == 2 && trimmed == "\(name):" {
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
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                entryEnd -= 1
            } else {
                break
            }
        }

        var entryLines = Array(block[entryStart..<entryEnd])
        mutate(&entryLines)

        block.replaceSubrange(entryStart..<entryEnd, with: entryLines)

        var combined: [String] = []
        combined.append(contentsOf: location.prefix)
        combined.append(contentsOf: block)
        combined.append(contentsOf: location.suffix)
        let newYAML = combined.joined(separator: "\n")
        writeFile(context.paths.configYAML, content: newYAML)
        return true
    }

    // MARK: - MCP YAML: mutators

    nonisolated private static func replaceOrInsertScalar(key: String, value: String, in lines: inout [String]) {
        // entry header is at lines[0] at indent 2. Scalars live at indent 4.
        for index in 1..<lines.count {
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent == 4, trimmed.hasPrefix(key + ":") || trimmed == key + ":" {
                lines[index] = "    \(key): \(value)"
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
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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

    nonisolated private static func replaceOrInsertList(header: String, items: [String], in lines: inout [String]) {
        var headerIndex: Int?
        var removeEnd: Int?
        for index in 1..<lines.count {
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent == 4 && trimmed == "\(header):" {
                headerIndex = index
                continue
            }
            if headerIndex != nil {
                // List items can appear at indent 4 (as "    - item") OR indent 6 depending on style.
                if trimmed.hasPrefix("- ") && indent >= 4 {
                    continue
                } else if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                } else if indent >= 6 {
                    continue
                } else {
                    removeEnd = index
                    break
                }
            }
        }

        if items.isEmpty {
            if let headerIndex, let end = removeEnd {
                lines.removeSubrange(headerIndex..<end)
            } else if let headerIndex {
                lines.removeSubrange(headerIndex..<lines.count)
            }
            return
        }

        var newLines: [String] = ["    \(header):"]
        for item in items {
            newLines.append("    - \(yamlScalar(item))")
        }

        if let headerIndex {
            let end = removeEnd ?? lines.count
            lines.replaceSubrange(headerIndex..<end, with: newLines)
        } else {
            var insertAt = lines.count
            for index in 1..<lines.count {
                let line = lines[index]
                let indent = line.prefix(while: { $0 == " " }).count
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if indent <= 2 && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    insertAt = index
                    break
                }
            }
            lines.insert(contentsOf: newLines, at: insertAt)
        }
    }

    nonisolated private static func replaceOrInsertSubMap(header: String, map: [String: String], in lines: inout [String]) {
        var headerIndex: Int?
        var removeEnd: Int?
        for index in 1..<lines.count {
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
                let trimmed = line.trimmingCharacters(in: .whitespaces)
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
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if indent <= 2 && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    insertAt = index
                    break
                }
            }
            lines.insert(contentsOf: newLines, at: insertAt)
        }
    }

    nonisolated private static func yamlScalar(_ value: String) -> String {
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

    nonisolated private static func unquote(_ value: String) -> String {
        var v = value
        if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2) || (v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2) {
            v = String(v.dropFirst().dropLast())
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
