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

    /// Test seam: run against a supplied transport instead of the context's
    /// own. Used to COUNT round trips — the per-server `fileExists` probing in
    /// `loadMCPServers` was only visible as a cost once something could count
    /// it (P35).
    nonisolated init(context: ServerContext, transport: any ServerTransport) {
        self.context = context
        self.transport = transport
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

    /// What a PROVEN config.yaml read found: the parsed config and its raw
    /// text.
    ///
    /// There is deliberately no `exists` here. `loadConfigProven` carried one
    /// and nothing ever read it — and there is no caller that could: absence
    /// is already folded into `config` (`.empty`) and `rawText` (`""`), and
    /// the only thing `exists` could gate is the "Reload before saving"
    /// refusal, which by construction never sees an absent file (an ABSENT
    /// config.yaml is not a refusal — a fresh host genuinely has nothing set
    /// and Save must work, or first-run setup is impossible). A decoded-but-
    /// dead field is the class P18 deleted rather than kept "for later".
    struct ProvenConfig: Sendable {
        let config: HermesConfig
        let rawText: String
    }

    /// ``loadConfig()`` with the two failures kept apart, the same way
    /// `HermesEnvService.loadProven()` splits `.env`'s (GW-F6 / DI L10,
    /// round-3 P33).
    ///
    /// **Why `loadConfigResult()` is not this.** That one maps a plain
    /// `readFileResult`, so it (a) cannot tell an ABSENT config.yaml from an
    /// unreadable one — both are `.failure`, and refusing to save on a fresh
    /// host that simply has no config.yaml yet would break every first-run
    /// setup — and (b) judges on ONE read, so a single dropped SSH round-trip
    /// reads as damage. `GuardedTextFile.load` is the primitive that already
    /// settles both: absence is proved by a failed read AND a failed `stat`,
    /// and a present-but-unreadable file is only declared after a RETRY.
    ///
    /// **Why the distinction is load-bearing.** `loadConfig()`'s `.empty`
    /// fallback feeds the platform setup forms. A blipped read made
    /// `whatsapp_cloud` render blank fields over live values, and its Save
    /// writes the whole block explicitly — so pressing Save on a form the
    /// user never edited would `hermes config set … ""` over the access
    /// token, app secret and verify token, and set `enabled: false`.
    /// Surfacing at LOAD, and refusing the save, is what closes it.
    /// Why a config.yaml could not be read. Mirrors
    /// `HermesEnvService.LoadRefusal` — the two files' refusals reach the
    /// same save bar, so they read as one sentence family.
    ///
    /// `GuardedTextFile.Refusal`'s own prose is written for a WRITE ("refusing
    /// to overwrite it"), which is the wrong tense on a form that has not
    /// written anything yet and needs to be told what to do next.
    enum LoadRefusal: LocalizedError, Equatable {
        case unreadable(path: String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(path):
                return "Couldn't read \(path). It's there, but two reads of it failed — the fields below may be blank even though values are set. Fix the connection or the file's permissions and Reload before saving, or a save will write those blanks over live values."
            }
        }
    }

    nonisolated func loadConfigProven() throws -> ProvenConfig {
        // Read-only, so the UNSERIALIZED initializer is correct: reads need
        // no serialization against each other, only against a writer, and a
        // reader that loses that race read bytes that were true a moment ago
        // (see `GuardedTextFile.lockContext`).
        let path = context.paths.configYAML
        let loaded: GuardedTextFile.Loaded
        do {
            loaded = try GuardedTextFile(transport: transport, label: "config.yaml").load(path)
        } catch {
            throw LoadRefusal.unreadable(path: path)
        }
        return ProvenConfig(
            config: loaded.exists ? HermesConfig(yaml: loaded.text) : .empty,
            rawText: loaded.text
        )
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

    /// Load `MEMORY.md` WITH PROOF (GW-F2, audit DI H3).
    ///
    /// The old body was `readFile(path) ?? ""`, which is the absent-vs-
    /// unreadable inference one hop upstream of the guard: the editor's
    /// conflict check compared the user's baseline against that `""`,
    /// concluded the file "changed to empty", and offered "Reload to take
    /// the new version" — after which the next save published emptiness
    /// THROUGH the guard, because by then the file read fine. The guard was
    /// being bypassed by the UI it protects.
    ///
    /// An empty file is still `""` with `exists == true`; only a
    /// stat-confirmed unreadable file (or non-UTF-8 bytes) throws. The
    /// returned `Loaded` is the write's proof token — hand it back to
    /// ``saveMemoryFile(_:target:profile:ifMatches:)``, which re-reads under
    /// the lock and does the conflict comparison there.
    ///
    /// Transport-only, i.e. UNSERIALIZED, on purpose (GW-F3): this is a READ.
    /// Reads need no lock against each other, and a read that loses a race
    /// against a writer returns bytes that were true a moment ago. The lock
    /// belongs to the write, and every write of these files takes it.
    nonisolated func loadMemoryFile(profile: String = "") throws -> GuardedTextFile.Loaded {
        try GuardedTextFile(transport: transport, label: "MEMORY.md")
            .load(memoryPath(profile: profile, file: "MEMORY.md"))
    }

    /// `USER.md`'s counterpart to ``loadMemoryFile(profile:)``.
    nonisolated func loadUserProfileFile(profile: String = "") throws -> GuardedTextFile.Loaded {
        try GuardedTextFile(transport: transport, label: "USER.md")
            .load(memoryPath(profile: profile, file: "USER.md"))
    }

    nonisolated func loadMemory(profile: String = "") throws -> String {
        try loadMemoryFile(profile: profile).text
    }

    nonisolated func loadUserProfile(profile: String = "") throws -> String {
        try loadUserProfileFile(profile: profile).text
    }

    /// GUARDED, and therefore THROWING. Only a PROVEN-unreadable file is
    /// refused — an empty `MEMORY.md` is a legal state (the guard's
    /// zero-byte reclassification) — and a refusal has to reach the user,
    /// which is why these no longer swallow.
    ///
    /// Unconditional save. The read the write is validated against is taken
    /// HERE, under the file's write lock (GW-F3) — a proof threaded in from
    /// an earlier read would be a `.bak` cut from bytes the file may no
    /// longer hold. Callers that also need a conflict check against an
    /// editor baseline use ``saveMemoryFile(_:target:profile:ifMatches:)``,
    /// which does the comparison inside the same hold.
    nonisolated func saveMemory(_ content: String, profile: String = "") throws {
        _ = try saveMemoryFile(content, target: .memory, profile: profile, ifMatches: nil)
    }

    nonisolated func saveUserProfile(_ content: String, profile: String = "") throws {
        _ = try saveMemoryFile(content, target: .userProfile, profile: profile, ifMatches: nil)
    }

    /// Conflict-checked, SERIALIZED save of `MEMORY.md` / `USER.md`.
    ///
    /// The Mac memory editor's save is a read-modify-write with a
    /// conflict check in the middle, and before GW-F3 the two halves
    /// straddled the lock that did not exist: the editor read the file,
    /// compared it against its baseline, and passed that `Loaded` down as
    /// the write's proof. Serializing only the write would have been
    /// theatre — the read it was validated against would still have been
    /// taken outside the hold, so a concurrent template install could land
    /// its memory appendix in the window and have it published away.
    ///
    /// So the comparison moves in here, where it runs against a read taken
    /// UNDER the lock. `baseline == nil` is the user's explicit "overwrite"
    /// answer to a conflict and skips the comparison; a mismatch publishes
    /// nothing and hands back the on-disk text the editor should offer.
    ///
    /// Synchronous and `nonisolated` by construction — the caller runs it
    /// inside one `Task.detached`, because the lock's reentrancy is
    /// thread-local and a hold must not span an `await`.
    nonisolated func saveMemoryFile(
        _ content: String,
        target: MemoryFileTarget,
        profile: String = "",
        ifMatches baseline: String?
    ) throws -> MemorySaveResult {
        let path = memoryPath(profile: profile, file: target.fileName)
        let file = GuardedTextFile(context: context, label: target.fileName)
        var conflict: String?
        try file.mutate(path) { loaded in
            if let baseline, loaded.text != baseline {
                conflict = loaded.text
                return nil
            }
            return content
        }
        if let conflict { return .conflict(onDisk: conflict) }
        return .saved
    }

    /// Which of the two hand-authored memory files a save targets.
    enum MemoryFileTarget: Sendable {
        case memory
        case userProfile

        nonisolated var fileName: String {
            switch self {
            case .memory: return "MEMORY.md"
            case .userProfile: return "USER.md"
            }
        }
    }

    /// Outcome of ``saveMemoryFile(_:target:profile:ifMatches:)``. A refusal
    /// or a lost lock race is a `throw`, not a case here.
    enum MemorySaveResult: Sendable, Equatable {
        case saved
        case conflict(onDisk: String)
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
        // ONE listing of `mcp-tokens/` for the whole roster. The per-server
        // probe this replaces asked `fileExists` once per candidate spelling
        // — up to 2N serialized SSH round trips inside a single load. An
        // unreadable or absent directory is an empty set, which is exactly
        // "no server has a token" and the same answer the per-path probe gave.
        let tokenEntries = Set((try? transport.listDirectory(context.paths.mcpTokensDir)) ?? [])
        return parsed.map { server in
            // NOT `<name>.json`: Hermes files OAuth state under
            // `_safe_filename(name)`, so `github.com` is `github_com.json`.
            // See `HermesMCPOAuthPaths` for the port and the tag walk.
            let hasToken = HermesMCPOAuthPaths
                .hasToken(serverName: server.name, tokenDirEntries: tokenEntries)
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
                supportsParallelToolCalls: server.supportsParallelToolCalls,
                clientCert: server.clientCert,
                clientKey: server.clientKey,
                sslVerify: server.sslVerify,
                identityHeader: server.identityHeader,
                strictRedirectHeaders: server.strictRedirectHeaders,
                cwd: server.cwd,
                oauthFlow: server.oauthFlow
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
    /// `--transport` flag — it'd be rejected at argparse time). So we create
    /// the entry with `hermes mcp add --url` (which produces a remote/HTTP-
    /// shaped block) and then write the `transport: sse` scalar into that
    /// server's YAML block via the same surgical patcher the rest of the
    /// MCP YAML surface uses. The `transport: sse` scalar is what the
    /// reader keys on to discriminate SSE from HTTP.
    @discardableResult
    nonisolated func addMCPServerSSE(
        name: String,
        url: String,
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
        // Stamp the SSE transport discriminator into the freshly-written
        // entry's YAML block.
        //
        // The stamp is not cosmetic: `transport: sse` is the ONLY thing that
        // discriminates this entry from the plain HTTP entry `hermes mcp add
        // --url` just wrote. Discarding the patcher's Bool reported a
        // successful SSE add for a server that is, on disk, an HTTP server —
        // and the reader then contradicted the UI on the next load. Report
        // the partial failure instead, with the entry named so the user can
        // fix or remove it.
        let stamped = patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertScalar(key: "transport", value: "sse", in: &entryLines)
        }
        guard stamped else {
            return (
                exitCode: 1,
                output: addResult.output
                    + (addResult.output.hasSuffix("\n") ? "" : "\n")
                    + "Server '\(name)' was created, but writing 'transport: sse' to "
                    + "~/.hermes/config.yaml failed — it is configured as a plain HTTP "
                    + "server. Remove it and try again, or add 'transport: sse' by hand."
            )
        }
        return addResult
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
                // Quoted through `yamlScalar` like every other scalar
                // writer (`setMCPServerCommand`): a path with a space,
                // a colon, a `#`, or a leading `~`-adjacent indicator
                // emitted bare makes PyYAML raise, and one PyYAML error
                // makes Hermes discard the WHOLE config.yaml layer.
                Self.replaceOrInsertScalar(
                    key: "client_cert",
                    value: Self.yamlScalar(path.trimmingCharacters(in: .whitespaces)),
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
                // Quoted through `yamlScalar` like every other scalar
                // writer (`setMCPServerCommand`): a path with a space,
                // a colon, a `#`, or a leading `~`-adjacent indicator
                // emitted bare makes PyYAML raise, and one PyYAML error
                // makes Hermes discard the WHOLE config.yaml layer.
                Self.replaceOrInsertScalar(
                    key: "client_key",
                    value: Self.yamlScalar(path.trimmingCharacters(in: .whitespaces)),
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
                // `ssl_verify` is EITHER a bool or a CA-bundle path
                // (mcp_client.py reads both). The bool form must stay a
                // bare `true` / `false` — `yamlScalar` quotes those on
                // purpose, and a quoted "true" is a PATH named "true" to
                // Hermes, which is a silent downgrade of certificate
                // verification. Only the path form is quoted, and it must
                // be: a bundle path with a `#` or a `:` in it, emitted
                // bare, makes PyYAML raise, and one PyYAML error makes
                // Hermes discard the WHOLE config.yaml layer
                // (gateway/config.py:776-791 at v2026.9.7).
                let raw = value.trimmingCharacters(in: .whitespaces)
                let isBool = ["true", "false"].contains(raw.lowercased())
                Self.replaceOrInsertScalar(
                    key: "ssl_verify",
                    value: isBool ? raw.lowercased() : Self.yamlScalar(raw),
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

    /// Updates the v0.21.1 `oauth.flow` scalar — `"browser"` (Hermes's
    /// default) or `"device"` (RFC 8628). Pass `nil`/empty to drop the key.
    /// Caller is responsible for capability-gating —
    /// `HermesCapabilities.hasMCPOAuthFlow`.
    ///
    /// Uses the nested-SCALAR patcher, not the `identity_header` block writer:
    /// the `oauth:` block also holds the user's `client_id`, `client_secret`,
    /// `scope` and `timeout`, which Scarf does not model. Rewriting the block
    /// wholesale would delete credentials the user cannot recover.
    @discardableResult
    nonisolated func setMCPServerOAuthFlow(name: String, flow: String?) -> Bool {
        // `patchMCPServerField`'s mutate closure cannot fail, so the
        // refusal is carried out: an unsupported `oauth:` shape leaves the
        // entry byte-identical and this returns false, which the caller
        // surfaces instead of reporting a save that never happened.
        let refusal = RefusalFlag()
        let patched = patchMCPServerField(name: name) { entryLines in
            let trimmed = flow?.trimmingCharacters(in: .whitespaces) ?? ""
            if !Self.replaceOrInsertNestedScalar(
                block: "oauth",
                key: "flow",
                value: trimmed.isEmpty ? nil : trimmed,
                in: &entryLines
            ) {
                refusal.hit = true
            }
        }
        if refusal.hit {
            Self.logger.warning(
                "refusing to set oauth.flow on MCP server \(name, privacy: .public): its `oauth:` block is an inline flow mapping or a scalar, which this patcher cannot edit without risking the block's other keys"
            )
            return false
        }
        return patched
    }

    /// One-bit out-param for a `mutate` closure that has no return value.
    private final class RefusalFlag: @unchecked Sendable { var hit = false }

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
                // Quoted through `yamlScalar` like every other scalar
                // writer (`setMCPServerCommand`): a path with a space,
                // a colon, a `#`, or a leading `~`-adjacent indicator
                // emitted bare makes PyYAML raise, and one PyYAML error
                // makes Hermes discard the WHOLE config.yaml layer.
                Self.replaceOrInsertScalar(
                    key: "cwd",
                    value: Self.yamlScalar(path.trimmingCharacters(in: .whitespaces)),
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

    /// Remove one MCP server, judged by what `hermes mcp remove` PRINTED.
    ///
    /// P40: `cmd_mcp_remove` is a `-> None` whose not-found arm prints
    /// `✗ Server '<name>' not found in config.` and returns at exit 0
    /// (`hermes_cli/mcp_config.py:104`, `:518-519` @ v2026.9.7), and on a
    /// managed install `save_config` refuses underneath it while `:524` prints
    /// `✓ Removed …` anyway. See ``HermesMCPRemoveVerdict``.
    @discardableResult
    nonisolated func removeMCPServer(name: String) -> HermesCLIOutcome {
        let result = runHermesCLI(args: HermesMCPRemoveVerdict.argv(name: name), timeout: 30)
        return HermesMCPRemoveVerdict.judge(output: result.output, exitCode: result.exitCode)
    }

    nonisolated func testMCPServer(name: String) async -> MCPTestResult {
        let started = Date()
        let service = self
        let result = await Task.detached { () -> (Int32, String) in
            service.runHermesCLI(args: HermesMCPTestVerdict.argv(name: name), timeout: 30)
        }.value
        let elapsed = Date().timeIntervalSince(started)
        let tools = Self.parseToolListFromTestOutput(result.1)
        // hermes mcp test exits 0 even when the inner connection fails — it
        // reports the failure on stdout instead. Judged by the emitter's own
        // anchored lines; see ``HermesMCPTestVerdict``.
        let output = result.1
        // P54, round-6 (lesson 12): the verdict has THREE states and this
        // kept only the bool, so `.unconfirmed` — exit 0 with neither
        // marker — reached both views as a hard "Test failed". The
        // confidence rides along now; `succeeded` still answers "may the UI
        // claim it passed?" and is false for both negative answers.
        let outcome = HermesMCPTestVerdict.judge(output: output, exitCode: result.0)
        return MCPTestResult(
            serverName: name,
            succeeded: outcome.succeeded,
            output: output,
            tools: tools,
            elapsed: elapsed,
            confidence: outcome.confidence
        )
    }

    /// Tool names out of `hermes mcp test` output.
    ///
    /// The old implementation looked for `- ` / `* ` bullets. **Hermes has
    /// never printed those**, so the tool chips this feeds have been empty on
    /// every host. `_print_tools` (`hermes_cli/mcp_config.py:49-52` at
    /// `v2026.9.7`) emits, for each tool, four leading spaces then the name
    /// padded to `width` (36, from the call site at `:619`) then the
    /// description truncated to 55:
    ///
    ///     ✓ Connected (412ms)
    ///     ✓ Tools discovered: 2
    ///
    ///         read_file                            Read a file from disk
    ///         write_file                           Write a file to disk
    ///
    /// Two things make a bare "indented line" test unsafe, so the block is
    /// anchored on the `Tools discovered: N` line (`:616`) instead:
    ///
    /// * The `Auth:` header arm at `:605` also prints a four-space-indented
    ///   `    {header}: {masked}` line, ABOVE the count — anchoring below it
    ///   keeps masked header values out of the tool list.
    /// * `N` bounds the block, so a description that wraps in the user's
    ///   terminal cannot contribute a phantom tool.
    ///
    /// ANSI is stripped even though `color()` (`hermes_cli/colors.py`) is a
    /// no-op whenever stdout is not a TTY — which is always, for a piped
    /// Scarf run. It costs nothing and it keeps the parse honest if that
    /// ever stops being true; note that when colour IS on, the `:{width}s`
    /// padding is applied to the ESCAPED string, so column alignment is not
    /// something this can rely on. It splits on whitespace instead.
    nonisolated static func parseToolListFromTestOutput(_ output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard let countIndex = lines.firstIndex(where: {
            stripANSI($0).contains(toolsDiscoveredMarker)
        }) else { return [] }
        let after = stripANSI(lines[countIndex])
            .components(separatedBy: toolsDiscoveredMarker)
            .last ?? ""
        let expected = Int(after.trimmingCharacters(in: .whitespaces)) ?? 0
        guard expected > 0 else { return [] }

        var tools: [String] = []
        for rawLine in lines[(countIndex + 1)...] {
            let line = stripANSI(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A blank line separates the count from the block (`:618`); it
            // does not end it.
            if trimmed.isEmpty { continue }
            // The block is exactly the indented rows. The first line that
            // isn't one ends it — `cmd_mcp_test` prints nothing else in
            // between, so this is a fail-closed bound, not a heuristic.
            guard line.hasPrefix("    ") else { break }
            guard let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first else { continue }
            let name = String(token)
            // MCP tool names are `[a-zA-Z0-9_-]` by convention and by every
            // name Hermes registers; anything else is not a tool row.
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            else { continue }
            tools.append(name)
            if tools.count == expected { break }
        }
        return tools
    }

    private static let toolsDiscoveredMarker = "Tools discovered: "

    /// Drop CSI/OSC escape sequences from a CLI line.
    nonisolated private static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var out = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\u{1B}" else { out.append(ch); continue }
            guard let next = iterator.next() else { break }
            if next == "[" {
                // CSI: parameter/intermediate bytes, then a final byte in
                // 0x40…0x7E.
                while let c = iterator.next() {
                    if let ascii = c.asciiValue, ascii >= 0x40, ascii <= 0x7E { break }
                }
            } else if next == "]" {
                // OSC: runs to BEL or ST (ESC \).
                while let c = iterator.next() {
                    if c == "\u{07}" { break }
                    if c == "\u{1B}" { _ = iterator.next(); break }
                }
            }
            // Anything else is a two-character escape; `next` is consumed
            // with it and nothing is emitted.
        }
        return out
    }

    @discardableResult
    nonisolated func toggleMCPServerEnabled(name: String, enabled: Bool) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertScalar(key: "enabled", value: enabled ? "true" : "false", in: &entryLines)
        }
    }

    @discardableResult
    nonisolated func setMCPServerEnv(name: String, env: [String: String]) -> Bool {
        // `expecting` is what makes this write fail CLOSED. The structural
        // half of `verifyPatchedConfig` cannot see this damage: a key that
        // commented its own mapping out leaves the `mcp_servers` entry list
        // untouched (`entryNames` only reads indent 0/2) and leaves a shape
        // `unpatchableReason` accepts (it skips `#` lines). Naming the rows
        // we wrote turns "the file still looks like a file" into "the rows
        // we wrote are in it" — and a missing row restores the original.
        patchMCPServerField(
            name: name,
            expecting: env.isEmpty ? [] : Self.subMapRows(header: "env", map: env)
        ) { entryLines in
            Self.replaceOrInsertSubMap(header: "env", map: env, in: &entryLines)
        }
    }

    @discardableResult
    nonisolated func setMCPServerHeaders(name: String, headers: [String: String]) -> Bool {
        // Read-back proof for the rows we wrote — see `setMCPServerEnv`.
        patchMCPServerField(
            name: name,
            expecting: headers.isEmpty ? [] : Self.subMapRows(header: "headers", map: headers)
        ) { entryLines in
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

    /// "Clear Token" — unlink the SAME set of files Hermes's own
    /// `remove_oauth_tokens` unlinks (`tools/mcp_oauth.py:690-693` →
    /// `HermesTokenStorage.remove`, `:391-394`, at `v2026.9.7`): the tokens,
    /// the DCR client registration, the discovered server metadata and the
    /// CIMD-refused marker.
    ///
    /// Deleting only `<name>.json` was worse than doing nothing: it left the
    /// cached `client.json`, so the next login re-sent a `client_id` the
    /// server had already forgotten and failed with an `invalid_client` the
    /// user had no way to clear — the very state Hermes drops on its own
    /// when it can see the rejection (`tools/mcp_oauth_manager.py:174`).
    ///
    /// Every unlink is best-effort by construction: both transports'
    /// `removeFile` is `rm -f`-shaped, so a sidecar an older Hermes never
    /// wrote is a no-op, not a failure. Only a real I/O error is reported.
    @discardableResult
    nonisolated func deleteMCPOAuthToken(name: String) -> Bool {
        var ok = true
        for path in HermesMCPOAuthPaths.statePaths(
            serverName: name, tokensDir: context.paths.mcpTokensDir
        ) {
            do {
                try transport.removeFile(path)
            } catch {
                Self.logger.error("clear MCP OAuth state failed for \(path, privacy: .public)")
                ok = false
            }
        }
        return ok
    }

    /// Restart the gateway, judged by what the backend PRINTED (P40). Same
    /// walk as ``stopHermes()``: `cmd_gateway` discards `gateway_command`'s
    /// return (`hermes_cli/main.py:1736-1742` @ v2026.9.7) and `_cmd_restart`
    /// has exit-0 refusal arms of its own (`hermes_cli/gateway.py:6047`).
    @discardableResult
    nonisolated func restartGateway() -> HermesCLIOutcome {
        let result = runHermesCLI(args: HermesGatewayServiceVerdict.argv(.restart), timeout: 30)
        return HermesGatewayServiceVerdict.judge(
            verb: .restart, output: result.output, exitCode: result.exitCode
        )
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
        var resources = true
        var prompts = true
        var subSection: String?
        // v0.20.4 — identity_header is a small fixed-shape nested block
        // (name / value_from / value). Captured separately from `fields`
        // since it's not a flat scalar.
        var identityHeaderName: String?
        var identityHeaderValueFrom: String?
        var identityHeaderValue: String?
        // v0.21.1 — `oauth.flow`. The ONLY key Scarf reads out of the `oauth:`
        // block; client_id / client_secret / scope / timeout stay unmodelled
        // and untouched (see HermesMCPServer.oauthFlow).
        var oauthFlow: String?

        func flush() {
            guard let name = currentName else { return }
            // 3-way transport discriminator, in HERMES'S OWN ORDER: `url`
            // first, then `transport`.
            //
            // `_is_http()` is `"url" in self._config`
            // (`tools/mcp_tool_health.py:27` @ `v2026.9.7`), and
            // `:412`'s `config.get("transport") == "sse"` is only REACHED on
            // the HTTP path. Hermes's own status payload says the same thing:
            // `cfg.get("transport", "http") if "url" in cfg else "stdio"`
            // (`tools/mcp_tool_discovery.py:484`) — a url-less entry is
            // `stdio` whatever its `transport:` key says. Testing `transport`
            // first made Scarf render `.sse` for a url-less `transport: sse`
            // entry: a transport the host does not run, with the editor then
            // offering SSE-only fields for it.
            //
            // Below the SSE check, URL-bearing entries fall back to .http
            // (v0.12 shape) and command-bearing entries to .stdio. This
            // preserves byte-for-byte round-trip on existing files — pre-v0.13
            // entries have no `transport:` key so they parse identically.
            //
            // The comparison is EXACT-CASE because Hermes's is:
            // `if config.get("transport") == "sse"` (`tools/mcp_tool_transport.py:412`
            // at `v2026.9.7`), with no `.lower()` anywhere on the path. A
            // `transport: SSE` entry goes down the Streamable-HTTP arm on the
            // host, so showing it as SSE in Scarf described a server that does
            // not exist — and the editor then offered SSE-only fields for
            // it. The `unquote` is not a widening: `"sse"` and `'sse'` are
            // the same `str` to PyYAML as bare `sse`, and the old
            // `.lowercased()` matched NEITHER of them.
            let transport: MCPTransport = {
                guard fields["url"] != nil else { return .stdio }
                return Self.unquote(fields["transport"] ?? "") == "sse" ? .sse : .http
            }()
            // Hermes reads every one of these through `_parse_boolish`
            // (`tools/mcp_tool_common.py:120-137` at `v2026.9.7`; the same
            // word sets back to `v2026.6.19:tools/mcp_tool.py:3754`), which
            // accepts {true,1,yes,on} / {false,0,no,off} case-insensitively
            // and falls back to the DEFAULT for anything else. An exact
            // `!= "false"` test read `enabled: no` as enabled — Scarf showed
            // a live server the gateway was ignoring.
            let enabled = Self.boolish(fields["enabled"], default: true)
            let timeout = fields["timeout"].flatMap(Int.init)
            let connectTimeout = fields["connect_timeout"].flatMap(Int.init)
            // v0.14 — supports_parallel_tool_calls is an optional bool;
            // absent means "use Hermes's default" and stays nil.
            // Absent stays nil ("use Hermes's default"); a present value is
            // read with the same boolish words Hermes uses
            // (`mcp_tool_discovery.py:254`). A present-but-unparseable value
            // stays nil, which renders as the default Hermes will apply.
            let parallel: Bool? = fields["supports_parallel_tool_calls"]
                .flatMap { Self.boolishOptional($0) }
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
                supportsParallelToolCalls: parallel,
                clientCert: clientCert,
                clientKey: clientKey,
                sslVerify: sslVerify,
                identityHeader: identityHeader,
                strictRedirectHeaders: strictRedirectHeaders,
                cwd: cwd,
                oauthFlow: oauthFlow
            )
            servers.append(server)

            currentName = nil
            fields = [:]
            argsList = []
            envMap = [:]
            headersMap = [:]
            includeList = []
            excludeList = []
            // `_parse_boolish(tools_filter.get(f), default=True)`
            // (`tools/mcp_tool_registration.py:77`): an ABSENT key means
            // exposed, not hidden. Defaulting these to false made the editor
            // render both toggles off for every server that had never set
            // them — and one save then wrote the `false` the user never chose.
            resources = true
            prompts = true
            subSection = nil
            identityHeaderName = nil
            identityHeaderValueFrom = nil
            identityHeaderValue = nil
            oauthFlow = nil
        }

        /// `key: value` split shared by every scalar site below: trims CRLF,
        /// unquotes the key (a hand-edited `"command":` is the same key), and
        /// drops an unquoted trailing `# comment` from the value.
        ///
        /// The separator comes from `HermesYAML.blockKeySpan`, the one
        /// block-style key scanner, rather than a second one here. P41b:
        /// `trimmed.firstIndex(of: ":")` had no quote awareness, so an env or
        /// header name containing a colon — which the editor writes correctly
        /// as `'A: B': v` through `YAMLScalar.quoteIfNeeded` — read back as
        /// the key `'A` with the value `B': v`, and the next save persisted
        /// that. It also disagreed with the parser on an unquoted
        /// `llama3:8b: high`-shaped name.
        func keyValue(_ trimmed: String) -> (key: String, value: String)? {
            guard let span = HermesYAML.blockKeySpan(in: trimmed) else { return nil }
            let key = Self.unquote(
                String(span.key).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let value = Self.stripInlineComment(
                String(span.afterColon)
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
                    } else if let (key, value) = keyValue(trimmed), key == "resources" {
                        resources = Self.boolish(value, default: true)
                    } else if let (key, value) = keyValue(trimmed), key == "prompts" {
                        prompts = Self.boolish(value, default: true)
                    }
                case "tools.include":
                    if trimmed.hasPrefix("- ") {
                        includeList.append(Self.unquote(String(trimmed.dropFirst(2))))
                    }
                case "tools.exclude":
                    if trimmed.hasPrefix("- ") {
                        excludeList.append(Self.unquote(String(trimmed.dropFirst(2))))
                    }
                case "oauth":
                    if let (key, value) = keyValue(trimmed), key == "flow" {
                        oauthFlow = Self.unquote(value)
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
        // GUARDED. One of five writers of `~/.hermes/config.yaml`; all of
        // them share `GuardedTextFile` so "absent" and "unreadable" are
        // decided once, with proof, rather than five times by inference. An
        // absent file still returns `false` here exactly as the old
        // `readFile(…) ?? nil` did; a stat-confirmed unreadable one now
        // refuses instead of being patched from a read that failed.
        //
        // SERIALIZED (GW-F3 / DI H4). This one keeps `load`/`write` split
        // rather than using `mutate`, because it is not a plain rewrite: it
        // publishes, RE-READS off disk, and RESTORES the pre-patch bytes
        // when the verification fails. All four of those touches have to be
        // inside one hold or the restore can publish over a concurrent
        // writer's config — which is why the lock is taken here, around the
        // whole method, instead of inside each write.
        let configFile = GuardedTextFile(context: context, label: "config.yaml")
        return (try? configFile.withLock(context.paths.configYAML) {
            patchMCPServerFieldLocked(
                name: name, expecting: expecting, configFile: configFile, mutate: mutate
            )
        }) ?? false
    }

    /// The body of ``patchMCPServerField(name:expecting:mutate:)``, run
    /// under config.yaml's write lock.
    nonisolated private func patchMCPServerFieldLocked(
        name: String,
        expecting: [String],
        configFile: GuardedTextFile,
        mutate: (inout [String]) -> Void
    ) -> Bool {
        let loadedConfig: GuardedTextFile.Loaded
        do {
            loadedConfig = try configFile.load(context.paths.configYAML)
        } catch {
            Self.logger.error(
                "refusing to patch MCP server \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        guard loadedConfig.exists else { return false }
        let yaml = loadedConfig.text
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
        // Failures are logged and swallowed here on purpose: the read-back
        // below is the real proof, and it restores when nothing landed.
        do {
            try configFile.write(newYAML, to: context.paths.configYAML, after: loadedConfig)
        } catch {
            Self.logger.warning(
                "Failed to write \(self.context.paths.configYAML, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        // Read the file BACK OFF DISK — the write goes through a transport
        // that logs and swallows its failures, so "we built a good string" is
        // not evidence that a good string landed.
        guard let written = readFile(context.paths.configYAML) else {
            Self.logger.error(
                "could not re-read \(self.context.paths.configYAML, privacy: .public) after patching \(name, privacy: .public); restoring"
            )
            // Restore the bytes we read and still hold. `loadedConfig`
            // proved them good, so the guard cannot refuse here; the `.bak`
            // it refreshes still holds that same pre-patch text.
            try? configFile.write(yaml, to: context.paths.configYAML, after: loadedConfig)
            return false
        }
        if let reason = Self.verifyPatchedConfig(
            text: written, name: name, expecting: expecting, namesBefore: namesBefore
        ) {
            Self.logger.error(
                "patch of MCP server \(name, privacy: .public) failed verification (\(reason, privacy: .public)); restoring \(self.context.paths.configYAML, privacy: .public)"
            )
            // Restore the bytes we read and still hold. `loadedConfig`
            // proved them good, so the guard cannot refuse here; the `.bak`
            // it refreshes still holds that same pre-patch text.
            try? configFile.write(yaml, to: context.paths.configYAML, after: loadedConfig)
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
    /// A leading U+FEFF is framing too, and in NEITHER `.whitespaces` nor
    /// `.whitespacesAndNewlines` — so on a BOM'd config.yaml the very first
    /// line read as `"\u{FEFF}mcp_servers:"`, `extractMCPBlock` found no
    /// block, and every MCP edit refused forever. Stripped here, after the
    /// trim, so every comparison in this file sees the same bytes; the line
    /// itself is never rewritten, so the BOM survives on disk.
    nonisolated static func trimYAMLLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return YAMLScalar.strippingBOM(trimmed)
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
            if let why = badKeyReason(trimmed: trimmed, colon: colon) { return why }
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

    /// Why the KEY half of an entry's `key: value` line is a shape the
    /// line mutators cannot round-trip, or `nil` when it is fine.
    ///
    /// `unpatchableReason` used to accept any indent-4-or-deeper line with a
    /// colon in it, which meant a key carrying a YAML flow indicator — the
    /// exact damage the pre-P19 unquoted map-key writer produced — passed
    /// the post-write verification that exists to catch it. A quoted key is
    /// always fine; a bare one must not open a flow collection.
    nonisolated private static func badKeyReason(
        trimmed: String,
        colon: String.Index
    ) -> String? {
        guard let first = trimmed.first, first != "'", first != "\"" else { return nil }
        let key = String(trimmed[trimmed.startIndex..<colon])
        // A tab anywhere in a plain scalar makes PyYAML raise a ScannerError.
        if key.contains("\t") { return "tab inside the key `\(key)`" }
        // Only a LEADING `{` / `[` is a hazard — it opens a flow collection,
        // and PyYAML then raises a ConstructorError on the unhashable key.
        // Verified against PyYAML 6: `a,b`, `a}b`, `a]b`, `a{b` and `a[b` all
        // load fine as plain keys, so rejecting those would refuse to edit
        // configs Hermes reads perfectly well.
        if let first = key.first, first == "{" || first == "[" {
            return "YAML flow indicator opens the unquoted key `\(key)`"
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
            // UNGUARDED-WRITE(C): per-launch timestamped config backup at a fresh, unique name.
            try transport.unguardedWriteFile(destination, data: data)
            Self.logger.info("backed up \(path, privacy: .public) to \(destination, privacy: .public)")
        } catch {
            Self.logger.warning(
                "could not back up \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// `nonisolated`: DateFormatter is documented thread-safe for formatting
    /// once configured, and this one is never reconfigured after init.
    nonisolated private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Config paths this process has already backed up. A tiny lock-guarded
    /// set rather than a `@MainActor` flag, because every caller here is
    /// `nonisolated` and runs off-main by charter C10.
    nonisolated private final class PathSet: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        /// - Returns: `true` when the path was NOT already present.
        func insertIfAbsent(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.insert(path).inserted
        }
    }
    nonisolated private static let backedUpConfigPaths = PathSet()

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

    /// Set (or drop) ONE child scalar inside a nested block, leaving every
    /// sibling key in that block byte-identical.
    ///
    /// This is the writer for `oauth.flow`, whose block also holds the user's
    /// `client_id` / `client_secret` / `scope` / `timeout`. The
    /// `replaceOrInsert<Block>` writers rebuild their block from Scarf's model
    /// and are only safe for blocks Scarf models COMPLETELY — using one here
    /// would silently delete credentials.
    ///
    /// Containment mirrors the other writers: the block header must be at
    /// indent 4 and match exactly, children are read at indent 6, and the block
    /// ends at the first line with indent <= 4 that is neither blank nor a
    /// comment. `nil` removes just the child line (and the block itself only
    /// if that child was its sole content — an emptied `oauth:` mapping is a
    /// YAML null that Hermes would read as a missing config).
    ///
    /// Returns `false` — leaving `lines` untouched — when the block exists in
    /// a shape this patcher cannot edit: an INLINE FLOW mapping
    /// (`oauth: {client_id: x}`) or a scalar. Matching only the bare
    /// `oauth:` header would miss those and then INSERT a second `oauth:`
    /// block; PyYAML keeps the last duplicate key, so the user's credentials
    /// would vanish from Hermes's view without a byte of them being deleted.
    @discardableResult
    nonisolated private static func replaceOrInsertNestedScalar(
        block: String,
        key: String,
        value: String?,
        in lines: inout [String]
    ) -> Bool {
        var blockIndex: Int?
        var childIndex: Int?
        var blockEnd: Int?
        var childCount = 0
        for index in 1..<lines.count {
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = Self.trimYAMLLine(line)
            if blockIndex == nil {
                if indent == 4, trimmed.hasPrefix(block + ":") {
                    // What follows the colon decides: nothing (or only a
                    // trailing comment) is an ordinary block header; a VALUE
                    // is an inline-flow mapping or a scalar, which this
                    // patcher cannot edit — refuse rather than insert a
                    // second `oauth:` header PyYAML would let win.
                    let rest = Self.stripInlineComment(String(trimmed.dropFirst(block.count + 1)))
                    if rest.isEmpty {
                        blockIndex = index
                    } else {
                        return false
                    }
                } else if indent <= 2 && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    break
                }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if indent >= 6 {
                childCount += 1
                if childIndex == nil, trimmed.hasPrefix(key + ":") || trimmed == key + ":" {
                    childIndex = index
                }
                continue
            }
            blockEnd = index
            break
        }

        guard let value else {
            guard let childIndex, let blockIndex else { return true }
            if childCount == 1 {
                // Removing the only child would leave `oauth:` as a null
                // mapping, which reads differently from an absent block.
                lines.removeSubrange(blockIndex...childIndex)
            } else {
                lines.remove(at: childIndex)
            }
            return true
        }

        guard blockIndex != nil else {
            // No block yet — create it with this single child, ahead of the
            // next entry, exactly where a scalar insert would go.
            lines.insert(contentsOf: ["    \(block):", "      \(key): \(value)"], at: 1)
            return true
        }
        if let childIndex {
            let carriageReturn = lines[childIndex].hasSuffix("\r") ? "\r" : ""
            lines[childIndex] = "      \(key): \(value)\(carriageReturn)"
        } else {
            lines.insert("      \(key): \(value)", at: blockEnd ?? lines.count)
        }
        return true
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

    /// The exact rows `replaceOrInsertSubMap` emits for a nested
    /// `env:` / `headers:` mapping — shared with the callers so they can
    /// hand them to `patchMCPServerField(expecting:)` and have the
    /// post-write reader PROVE they landed.
    ///
    /// **Keys are quoted, not just values.** P10 routed the values through
    /// `yamlScalar` and left the keys bare, so a user-typed key was spliced
    /// in raw. Verified against PyYAML 6 at indent 6 under `headers:`:
    /// `{a}` / `[x]` raise `ConstructorError`, `a: b` and a key containing a
    /// TAB raise `ScannerError`, `*z` raises `ComposerError` (undefined
    /// alias), a leading `#` turns the whole `headers` mapping into `None`,
    /// and `on` becomes the key `True`. Hermes swallows a PyYAML error and
    /// discards the ENTIRE config.yaml layer (`gateway/config.py:775-791`
    /// at `v2026.9.7`), so none of those fail loudly. Keys go through the
    /// same `YAMLScalar.quoteIfNeeded` as `GatewayConfigWriter.setMap`'s —
    /// the two writers no longer disagree.
    nonisolated static func subMapRows(header: String, map: [String: String]) -> [String] {
        var rows = ["    \(header):"]
        for key in map.keys.sorted() {
            rows.append("      \(YAMLScalar.quoteIfNeeded(key)): \(yamlScalar(map[key] ?? ""))")
        }
        return rows
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

        newLines.append(contentsOf: subMapRows(header: header, map: map))

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

    /// Emit one MCP scalar VALUE — a thin forwarder over
    /// ``YAMLScalar/quoteIfNeeded(_:)``, which is the one emission rule
    /// every config.yaml writer in Scarf shares.
    ///
    /// **It used to be a fourth copy of that rule, and it was the copy that
    /// was wrong.** Its double-quoted arm escaped exactly `\\` and `\"`, so
    /// any C0/C1 control, DEL, NEL or U+2028/U+2029 a user pasted into an
    /// MCP `env:` / `headers:` value, a tool name, a cert path or a
    /// `command` went out RAW inside the quotes — and PyYAML's READER
    /// refuses those in EVERY quoting style ("unacceptable character
    /// #x0001: special characters are not allowed"), so Hermes swallowed
    /// the error and discarded the WHOLE config.yaml layer
    /// (`gateway/config.py:775-791` @ `v2026.9.7`). Fuzzed 7 000 inputs
    /// through PyYAML 6.0.3: `quoteIfNeeded` 0 failures, this routine 3 953.
    /// `patchMCPServerField(expecting:)` could not see it either — the
    /// expected rows are built by the same `subMapRows`, so the literal
    /// match succeeds on a file PyYAML rejects (P19's lesson, applied to a
    /// scalar the verifier itself emits).
    ///
    /// Two emission differences fall out of the unification, both safe
    /// because ``unquote(_:)`` (i.e. ``YAMLScalar/unquote(_:)``) reverses
    /// both: a safe-but-quotable scalar comes out SINGLE-quoted rather than
    /// double-quoted, and an empty value comes out `''` rather than `""`.
    /// PyYAML loads either spelling as the same string.
    ///
    /// `ssl_verify` still must not reach here for its BOOL form — a quoted
    /// `"true"` is a CA-bundle path named `true` to Hermes. That carve-out
    /// lives at the call site (`setMCPServerSSLVerify`), where the bool and
    /// path forms are told apart.
    nonisolated static func yamlScalar(_ value: String) -> String {
        YAMLScalar.quoteIfNeeded(value)
    }

    // MARK: - Boolish scalars

    /// The two word sets `_parse_boolish` accepts
    /// (`tools/mcp_tool_common.py:120-121` at `v2026.9.7`; identical at
    /// `v2026.6.19:tools/mcp_tool.py:3762-3765`, so this is not gated).
    private static let boolishTrueWords: Set<String> = ["true", "1", "yes", "on"]
    private static let boolishFalseWords: Set<String> = ["false", "0", "no", "off"]

    /// Read a YAML scalar the way Hermes's `_parse_boolish` does: the value is
    /// unquoted and inline-comment-stripped first (a `"false"` and a
    /// `false  # was true` are both `false` to PyYAML, and neither matches a
    /// literal comparison), then matched against the word sets. Anything else
    /// — including an absent key — is `default`, which is what Hermes falls
    /// back to after its `logger.warning`.
    nonisolated static func boolish(_ raw: String?, default fallback: Bool) -> Bool {
        boolishOptional(raw) ?? fallback
    }

    /// As `boolish` but `nil` for absent-or-unrecognised, for the callers that
    /// must distinguish "the user set it" from "Hermes decides".
    ///
    /// **The word sets are only half of `_parse_boolish`; the other half is a
    /// TYPE gate, and getting it wrong inverts the answer.** Hermes is handed
    /// a value PyYAML has already typed, and it matches the words only
    /// `isinstance(value, str)` (`tools/mcp_tool_common.py:124-137` at
    /// `v2026.9.7`). A bare `enabled: 0` is an `int` to PyYAML — neither
    /// `bool` nor `str` — so it warns and returns the DEFAULT. `enabled: 0`
    /// is therefore an ENABLED server on the host (default `True`), and
    /// `supports_parallel_tool_calls: 1` is OFF (default `False`). Scarf read
    /// both backwards. Quoted (`enabled: "0"`) IS a `str` and does read as
    /// false, which is why the gate runs on the raw scalar, before `unquote`.
    ///
    /// `null` / `~` / an empty value are the same case from the other side:
    /// PyYAML loads `None`, and `_parse_boolish` returns the default for it
    /// explicitly (`:127-128`).
    ///
    /// This is deliberately NOT the reader for `ssl_verify`, which never
    /// reaches `_parse_boolish` — it is passed to httpx as-is, where a bare
    /// `0` and a CA-bundle path both mean something else again. That one
    /// stays a `String?` all the way to the UI.
    nonisolated static func boolishOptional(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        let plain = stripInlineComment(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        // Anything PyYAML retypes to a non-`str`, non-`bool` (int, float,
        // null, timestamp) never reaches Hermes's word match.
        if YAMLScalar.resolvesToNonString(plain), !YAMLScalar.resolvesToBool(plain) {
            return nil
        }
        let value = unquote(plain)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if boolishTrueWords.contains(value) { return true }
        if boolishFalseWords.contains(value) { return false }
        return nil
    }

    /// The reader half of `YAMLScalar`'s writers: PyYAML's whole escape
    /// table inside double quotes (`\\ \" \/ \n \r \t \0 \a \b \f \v \e
    /// \N \_ \L \P \xNN \uNNNN \UNNNNNNNN`) and `''` inside single quotes.
    /// Wider than it was before P37 — the old local copy stopped at
    /// `\\ \" \n \r \t \xNN \uNNNN` and passed the rest through, which is
    /// simply a reader that cannot read what PyYAML writes.
    ///
    /// P37: this WAS a second copy of that escape table, and it differed
    /// from the one in `HermesBotProfileYAML` in exactly the way that
    /// matters — its hex arm called `UInt32(_:radix:)` with no
    /// `allSatisfy(\.isHexDigit)` guard, so `\x+9` decoded to a TAB. One
    /// decoder now: ``YAMLScalar/unquote(_:)``.
    nonisolated static func unquote(_ value: String) -> String {
        YAMLScalar.unquote(value)
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

    /// Stop the gateway, judged by what `hermes gateway stop` PRINTED.
    ///
    /// P40: the exit code was the whole verdict here, and `_cmd_stop` is a
    /// `-> None` whose "nothing to stop" arms print `✗ …` and return at exit 0
    /// (`hermes_cli/gateway.py:5993`, `:5998` @ v2026.9.7) — so every caller
    /// (two of which report to Analytics) recorded a stop that never happened
    /// as a success. See ``HermesGatewayServiceVerdict`` for the full walk.
    ///
    /// Round-4 decision 2: "nothing was running" is a SUCCESS carrying
    /// ``HermesCLIOutcome/warning``, not a failure — so the `pgrep`/`kill`
    /// fallback below is reached only when the CLI genuinely could not stop a
    /// gateway, which is what it was always for.
    ///
    /// **The fallback is gated on a POSITIVE failure signal, never on
    /// `!succeeded`.** `_dispatch_via_service_manager_if_s6`
    /// (`hermes_cli/gateway.py:5608-5629` @ v2026.9.7) hands `stop` to the s6
    /// service manager and prints NOTHING on the success path
    /// (`hermes_cli/service_manager.py:529-566` prints nothing either), so on
    /// an s6 container host a real stop lands as
    /// ``HermesCLIOutcome/Confidence/unconfirmed``. Falling through to
    /// `pgrep` + `kill -TERM` there is actively harmful: `s6-supervise` reads
    /// a bare SIGTERM as a crash and restarts the gateway ~1s later — Hermes
    /// says so itself in `_dispatch_all_via_service_manager_if_s6`'s docstring
    /// (`:5631-5634`). "Could not confirm" leaves the answer to the reload
    /// every caller already does; only ``HermesCLIOutcome/Confidence/failed``
    /// — a matched refusal marker, or a non-zero exit — earns the kill.
    @discardableResult
    nonisolated func stopHermes() -> HermesCLIOutcome {
        // v0.9.0 fixed `hermes gateway stop` so it issues `launchctl bootout` and
        // waits for exit. Use the CLI to avoid racing launchd's KeepAlive respawn.
        let result = runHermesCLI(args: HermesGatewayServiceVerdict.argv(.stop))
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .stop, output: result.output, exitCode: result.exitCode
        )
        if outcome.succeeded { return outcome }
        // No positive failure signal ⇒ we do not know, and we must not guess
        // with a signal. See the doc above (s6).
        guard outcome.confidence == .failed else { return outcome }
        // The fallback SIGTERM is a real stop when it lands; when it does not,
        // Hermes's own refusal line is still the better message.
        func fallback(_ ok: Bool) -> HermesCLIOutcome {
            ok ? HermesCLIOutcome(succeeded: true, detail: nil) : outcome
        }
        guard let pid = hermesPID() else { return fallback(false) }
        // For remote we can't issue a raw `kill(2)` — route through `kill(1)`
        // via the transport. Local uses the syscall for its minimal overhead.
        if context.isRemote {
            let result = try? transport.runProcess(
                executable: "/bin/kill",
                args: ["-TERM", String(pid)],
                stdin: nil,
                timeout: 5
            )
            return fallback((result?.exitCode ?? -1) == 0)
        }
        return fallback(kill(pid, SIGTERM) == 0)
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
    /// **Synchronous on purpose, and the one app-target reap that stays so**
    /// (round-5 P48, t-12d04477). Its only caller is the `enrichedShellEnv`
    /// `static let` initializer above — a lazy global, which Swift runs
    /// synchronously on whichever thread first touches it and which cannot be
    /// `async`. Making this `async` would mean giving the enrichment an
    /// asynchronous entry point and auditing every one of its many
    /// synchronous readers, which is a larger change than the hazard: the
    /// budgets here are 5 s and 3 s, not the 300 s the async rule was written
    /// for, and the value is computed exactly once per process.
    nonisolated static func runShellProbe(script: String, interactive: Bool, timeout: TimeInterval) -> [String: String]? {
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

        // Only the WRITE ends here: once `waitDraining` has launched its
        // readers they own the read ends and close each one themselves, and
        // closing a handle another thread is blocked reading is a raised
        // exception. The launch-failure path below has no readers, so it
        // closes all four.
        defer {
            try? pipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
        }
        do {
            try process.run()
            // C10, both halves. The old shape polled for the exit and THEN
            // read stdout, with stderr on a pipe nothing ever read: an rc
            // file noisy enough to fill the 64 KB stderr buffer — `nvm`
            // warnings, a `compaudit` complaint per insecure directory —
            // wedged zsh in `write()` until the budget expired, and the env
            // probe came back nil for a shell that was working fine. Both
            // pipes are drained CONCURRENTLY with the wait now.
            let (exited, drained) = process.waitDraining(
                timeout: timeout, pipes: [pipe, errPipe])
            guard exited else { return nil }
            let data = drained.first ?? Data()
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
            // Never launched, so nothing is draining: these two are ours to
            // close (the write ends are the `defer`'s).
            try? pipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
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
    /// LEGACY. It has no callers left: iOS `ChatView`'s preflight — the
    /// last one this doc named — spawns its own `HermesConfigSet.argv` over
    /// the transport (P46 finding 12) and never came through here.
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

        // P39: output-judged, like every other `config set` Scarf shells —
        // the managed-install arm exits 0 (`hermes_cli/config.py:3450-3452`).
        let providerResult = runHermesCLI(
            args: HermesConfigSet.argv(key: "model.provider", value: trimmedProvider), timeout: 30)
        guard HermesConfigSet.judge(output: providerResult.output, exitCode: providerResult.exitCode).succeeded else {
            Self.logger.warning("hermes config set model.provider failed: \(providerResult.output, privacy: .public)")
            return false
        }
        // Subscription-gated overlay providers (Nous Portal) accept an
        // empty model — Hermes picks its own default. Skip the model
        // write in that case rather than persisting the empty string,
        // which Hermes would treat as "unset" and the preflight would
        // catch again on the next start.
        guard !trimmedModel.isEmpty else { return true }

        let modelResult = runHermesCLI(
            args: HermesConfigSet.argv(key: "model.default", value: trimmedModel), timeout: 30)
        guard HermesConfigSet.judge(output: modelResult.output, exitCode: modelResult.exitCode).succeeded else {
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
            // P39: output-judged (`HermesConfigSet`) — the managed-install arm
            // of `set_config_value` exits 0, and a model plan that "succeeded"
            // against an untouched config.yaml is exactly the silent reroute
            // this plan's ordering exists to prevent.
            guard HermesConfigSet.judge(output: result.output, exitCode: result.exitCode).succeeded else {
                // Log key only — a .set(model.api_key, …) value is a secret.
                Self.logger.warning("hermes config set \(operation.key, privacy: .public) failed (exit \(result.exitCode)): \(result.output, privacy: .public)")
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
            // A SEPARATOR when stdout does not already end in one. Without
            // it a stdout with no trailing newline welds its last line to
            // stderr's first — and every anchored refusal marker
            // (``HermesCLIMarkers/managedRefusalAnchored`` and friends) asks
            // whether a line STARTS with the marker, which a welded line
            // never does. The exit-0 refusal families are exactly the ones
            // that print to stderr while stdout carries a success line.
            let stdout = result.stdoutString
            let separator = (stdout.isEmpty || stdout.hasSuffix("\n")) ? "" : "\n"
            let combined = stdout + separator + result.stderrString
            return (result.exitCode, combined)
        } catch let error as TransportError {
            let message = error.diagnosticStderr.isEmpty
                ? (error.errorDescription ?? "transport error")
                : error.diagnosticStderr
            // A `.timeout` carries what the child printed before the kill, and
            // on this path that partial stdout is EVIDENCE, not noise: the
            // callers hand `output` to a `HermesCLIVerdict`, and the live
            // shape is `_cmd_restart`'s no-service arm — `Starting gateway...`
            // and then a foreground `run_gateway` that never returns
            // (`hermes_cli/gateway.py:6062-6066` @ v2026.9.7), so the ONLY way
            // the run ends is this timeout. Dropping it reported a gateway
            // that was coming up as "restart failed". The message keeps its
            // place as the last line, so `fallbackDetail` still quotes
            // something useful when nothing was printed.
            let partial = error.partialStdoutText
            return (-1, partial.isEmpty ? message : partial + "\n" + message)
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

}
