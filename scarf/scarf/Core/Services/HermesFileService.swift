import Foundation

struct HermesFileService: Sendable {

    // MARK: - Config

    func loadConfig() -> HermesConfig {
        guard let content = readFile(HermesPaths.configYAML) else { return .empty }
        return parseConfig(content)
    }

    private func parseConfig(_ yaml: String) -> HermesConfig {
        let parsed = Self.parseNestedYAML(yaml)
        let values = parsed.values
        let lists = parsed.lists
        let maps = parsed.maps

        func bool(_ key: String, default def: Bool) -> Bool {
            guard let v = values[key] else { return def }
            return v == "true"
        }
        func int(_ key: String, default def: Int) -> Int {
            Int(values[key] ?? "") ?? def
        }
        func double(_ key: String, default def: Double) -> Double {
            Double(values[key] ?? "") ?? def
        }
        func str(_ key: String, default def: String = "") -> String {
            // Strip quotes added by Hermes's YAML dumper around strings with special chars.
            let raw = values[key] ?? def
            return Self.stripYAMLQuotes(raw)
        }

        let dockerEnv = maps["terminal.docker_env"] ?? [:]
        let commandAllowlist = lists["permanent_allowlist"] ?? lists["command_allowlist"] ?? []

        let display = DisplaySettings(
            skin: str("display.skin", default: "default"),
            compact: bool("display.compact", default: false),
            resumeDisplay: str("display.resume_display", default: "full"),
            bellOnComplete: bool("display.bell_on_complete", default: false),
            inlineDiffs: bool("display.inline_diffs", default: true),
            toolProgressCommand: bool("display.tool_progress_command", default: false),
            toolPreviewLength: int("display.tool_preview_length", default: 0),
            busyInputMode: str("display.busy_input_mode", default: "interrupt")
        )

        let terminal = TerminalSettings(
            cwd: str("terminal.cwd", default: "."),
            timeout: int("terminal.timeout", default: 180),
            envPassthrough: lists["terminal.env_passthrough"] ?? [],
            persistentShell: bool("terminal.persistent_shell", default: true),
            dockerImage: str("terminal.docker_image"),
            dockerMountCwdToWorkspace: bool("terminal.docker_mount_cwd_to_workspace", default: false),
            dockerForwardEnv: lists["terminal.docker_forward_env"] ?? [],
            dockerVolumes: lists["terminal.docker_volumes"] ?? [],
            containerCPU: int("terminal.container_cpu", default: 0),
            containerMemory: int("terminal.container_memory", default: 0),
            containerDisk: int("terminal.container_disk", default: 0),
            containerPersistent: bool("terminal.container_persistent", default: false),
            modalImage: str("terminal.modal_image"),
            modalMode: str("terminal.modal_mode", default: "auto"),
            daytonaImage: str("terminal.daytona_image"),
            singularityImage: str("terminal.singularity_image")
        )

        let browser = BrowserSettings(
            inactivityTimeout: int("browser.inactivity_timeout", default: 120),
            commandTimeout: int("browser.command_timeout", default: 30),
            recordSessions: bool("browser.record_sessions", default: false),
            allowPrivateURLs: bool("browser.allow_private_urls", default: false),
            camofoxManagedPersistence: bool("browser.camofox.managed_persistence", default: false)
        )

        let voice = VoiceSettings(
            recordKey: str("voice.record_key", default: "ctrl+b"),
            maxRecordingSeconds: int("voice.max_recording_seconds", default: 120),
            silenceDuration: double("voice.silence_duration", default: 3.0),
            ttsProvider: str("tts.provider", default: "edge"),
            ttsEdgeVoice: str("tts.edge.voice", default: "en-US-AriaNeural"),
            ttsElevenLabsVoiceID: str("tts.elevenlabs.voice_id"),
            ttsElevenLabsModelID: str("tts.elevenlabs.model_id", default: "eleven_multilingual_v2"),
            ttsOpenAIModel: str("tts.openai.model", default: "gpt-4o-mini-tts"),
            ttsOpenAIVoice: str("tts.openai.voice", default: "alloy"),
            ttsNeuTTSModel: str("tts.neutts.model"),
            ttsNeuTTSDevice: str("tts.neutts.device", default: "cpu"),
            sttEnabled: bool("stt.enabled", default: true),
            sttProvider: str("stt.provider", default: "local"),
            sttLocalModel: str("stt.local.model", default: "base"),
            sttLocalLanguage: str("stt.local.language"),
            sttOpenAIModel: str("stt.openai.model", default: "whisper-1"),
            sttMistralModel: str("stt.mistral.model", default: "voxtral-mini-latest")
        )

        func aux(_ name: String) -> AuxiliaryModel {
            AuxiliaryModel(
                provider: str("auxiliary.\(name).provider", default: "auto"),
                model: str("auxiliary.\(name).model"),
                baseURL: str("auxiliary.\(name).base_url"),
                apiKey: str("auxiliary.\(name).api_key"),
                timeout: int("auxiliary.\(name).timeout", default: 30)
            )
        }
        let auxiliary = AuxiliarySettings(
            vision: aux("vision"),
            webExtract: aux("web_extract"),
            compression: aux("compression"),
            sessionSearch: aux("session_search"),
            skillsHub: aux("skills_hub"),
            approval: aux("approval"),
            mcp: aux("mcp"),
            flushMemories: aux("flush_memories")
        )

        let security = SecuritySettings(
            redactSecrets: bool("security.redact_secrets", default: true),
            redactPII: bool("privacy.redact_pii", default: false),
            tirithEnabled: bool("security.tirith_enabled", default: true),
            tirithPath: str("security.tirith_path", default: "tirith"),
            tirithTimeout: int("security.tirith_timeout", default: 5),
            tirithFailOpen: bool("security.tirith_fail_open", default: true),
            blocklistEnabled: bool("security.website_blocklist.enabled", default: false),
            blocklistDomains: lists["security.website_blocklist.domains"] ?? []
        )

        let humanDelay = HumanDelaySettings(
            mode: str("human_delay.mode", default: "off"),
            minMS: int("human_delay.min_ms", default: 800),
            maxMS: int("human_delay.max_ms", default: 2500)
        )

        let compression = CompressionSettings(
            enabled: bool("compression.enabled", default: true),
            threshold: double("compression.threshold", default: 0.5),
            targetRatio: double("compression.target_ratio", default: 0.2),
            protectLastN: int("compression.protect_last_n", default: 20)
        )

        let checkpoints = CheckpointSettings(
            enabled: bool("checkpoints.enabled", default: true),
            maxSnapshots: int("checkpoints.max_snapshots", default: 50)
        )

        let logging = LoggingSettings(
            level: str("logging.level", default: "INFO"),
            maxSizeMB: int("logging.max_size_mb", default: 5),
            backupCount: int("logging.backup_count", default: 3)
        )

        let delegation = DelegationSettings(
            model: str("delegation.model"),
            provider: str("delegation.provider"),
            baseURL: str("delegation.base_url"),
            apiKey: str("delegation.api_key"),
            maxIterations: int("delegation.max_iterations", default: 50)
        )

        let discord = DiscordSettings(
            requireMention: bool("discord.require_mention", default: true),
            freeResponseChannels: str("discord.free_response_channels"),
            autoThread: bool("discord.auto_thread", default: true),
            reactions: bool("discord.reactions", default: true)
        )

        let telegram = TelegramSettings(
            requireMention: bool("telegram.require_mention", default: true),
            reactions: bool("telegram.reactions", default: false)
        )

        // Slack fields live under both `platforms.slack.*` (newer) and `slack.*`
        // (legacy) in config.yaml. Prefer the newer path but fall back.
        let slack = SlackSettings(
            replyToMode: values["platforms.slack.reply_to_mode"] ?? values["slack.reply_to_mode"] ?? "first",
            requireMention: (values["platforms.slack.require_mention"] ?? values["slack.require_mention"]) != "false",
            replyInThread: (values["platforms.slack.extra.reply_in_thread"] ?? "true") != "false",
            replyBroadcast: (values["platforms.slack.extra.reply_broadcast"] ?? "false") == "true"
        )

        let matrix = MatrixSettings(
            requireMention: bool("matrix.require_mention", default: true),
            autoThread: bool("matrix.auto_thread", default: true),
            dmMentionThreads: bool("matrix.dm_mention_threads", default: false)
        )

        let mattermost = MattermostSettings(
            requireMention: bool("mattermost.require_mention", default: true),
            replyMode: str("mattermost.reply_mode", default: "off")
        )

        let whatsapp = WhatsAppSettings(
            unauthorizedDMBehavior: str("whatsapp.unauthorized_dm_behavior", default: "pair"),
            replyPrefix: str("whatsapp.reply_prefix")
        )

        // Home Assistant lives under `platforms.homeassistant.extra.*`.
        let homeAssistant = HomeAssistantSettings(
            watchDomains: lists["platforms.homeassistant.extra.watch_domains"] ?? [],
            watchEntities: lists["platforms.homeassistant.extra.watch_entities"] ?? [],
            watchAll: bool("platforms.homeassistant.extra.watch_all", default: false),
            ignoreEntities: lists["platforms.homeassistant.extra.ignore_entities"] ?? [],
            cooldownSeconds: int("platforms.homeassistant.extra.cooldown_seconds", default: 30)
        )

        return HermesConfig(
            model: str("model.default", default: "unknown"),
            provider: str("model.provider", default: "unknown"),
            maxTurns: int("agent.max_turns", default: 0),
            personality: str("display.personality", default: "default"),
            terminalBackend: str("terminal.backend", default: "local"),
            memoryEnabled: bool("memory.memory_enabled", default: false),
            memoryCharLimit: int("memory.memory_char_limit", default: 0),
            userCharLimit: int("memory.user_char_limit", default: 0),
            nudgeInterval: int("memory.nudge_interval", default: 0),
            streaming: values["display.streaming"] != "false",
            showReasoning: bool("display.show_reasoning", default: false),
            verbose: bool("agent.verbose", default: false),
            autoTTS: values["voice.auto_tts"] != "false",
            silenceThreshold: int("voice.silence_threshold", default: QueryDefaults.defaultSilenceThreshold),
            reasoningEffort: str("agent.reasoning_effort", default: "medium"),
            showCost: bool("display.show_cost", default: false),
            approvalMode: str("approvals.mode", default: "manual"),
            browserBackend: str("browser.backend"),
            memoryProvider: str("memory.provider"),
            dockerEnv: dockerEnv,
            commandAllowlist: commandAllowlist,
            memoryProfile: str("memory.profile"),
            serviceTier: str("agent.service_tier", default: "normal"),
            gatewayNotifyInterval: int("agent.gateway_notify_interval", default: 600),
            forceIPv4: bool("network.force_ipv4", default: false),
            contextEngine: str("context.engine", default: "compressor"),
            interimAssistantMessages: values["display.interim_assistant_messages"] != "false",
            honchoInitOnSessionStart: bool("honcho.initOnSessionStart", default: false),
            timezone: str("timezone"),
            userProfileEnabled: bool("memory.user_profile_enabled", default: true),
            toolUseEnforcement: str("agent.tool_use_enforcement", default: "auto"),
            gatewayTimeout: int("agent.gateway_timeout", default: 1800),
            approvalTimeout: int("approvals.timeout", default: 60),
            fileReadMaxChars: int("file_read_max_chars", default: 100_000),
            cronWrapResponse: bool("cron.wrap_response", default: true),
            prefillMessagesFile: str("prefill_messages_file"),
            skillsExternalDirs: lists["skills.external_dirs"] ?? [],
            display: display,
            terminal: terminal,
            browser: browser,
            voice: voice,
            auxiliary: auxiliary,
            security: security,
            humanDelay: humanDelay,
            compression: compression,
            checkpoints: checkpoints,
            logging: logging,
            delegation: delegation,
            discord: discord,
            telegram: telegram,
            slack: slack,
            matrix: matrix,
            mattermost: mattermost,
            whatsapp: whatsapp,
            homeAssistant: homeAssistant
        )
    }

    /// Parsed YAML result bundle.
    struct ParsedYAML: Sendable {
        var values: [String: String]           // "section.key" -> scalar string
        var lists: [String: [String]]          // "section.key" -> items from a bullet list
        var maps: [String: [String: String]]   // "section.key" -> nested key-value map
    }

    /// Parse a subset of YAML into flat dotted paths.
    ///
    /// Supports:
    /// - Scalar key-value pairs at any indent level → `values["a.b.c"] = "..."`
    /// - Empty-valued section headers → acts as a path prefix for nested scalars
    /// - Bullet lists (`- item`) nested under a `key:` → `lists["a.b"]`
    /// - Nested maps where a header has no value and children are `k: v` pairs →
    ///   captured as `maps["a.b"]` AND each child as `values["a.b.k"]`.
    ///
    /// This is sufficient for Hermes config; we do not attempt full YAML compliance.
    nonisolated static func parseNestedYAML(_ yaml: String) -> ParsedYAML {
        var values: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var maps: [String: [String: String]] = [:]
        // Path stack: each entry is (indent, name). Pop when indent shrinks.
        var stack: [(indent: Int, name: String)] = []

        func currentPath(joinedWith child: String? = nil) -> String {
            var parts = stack.map(\.name)
            if let child { parts.append(child) }
            return parts.joined(separator: ".")
        }

        let rawLines = yaml.components(separatedBy: "\n")
        for line in rawLines {
            // Skip comment-only and blank lines but preserve indent semantics.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count
            let isListItem = trimmed.hasPrefix("- ")

            // Pop stack entries with indent >= current indent.
            // Exception: a list item at the same indent as its parent key is
            // valid block-style YAML ("toolsets:\n- hermes-cli") — keep the
            // parent so the item is attributed to it.
            while let top = stack.last {
                let shouldPop: Bool
                if isListItem && top.indent == indent {
                    shouldPop = false
                } else {
                    shouldPop = top.indent >= indent
                }
                if shouldPop { stack.removeLast() } else { break }
            }

            if isListItem {
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let stripped = stripYAMLQuotes(item)
                let path = currentPath()
                guard !path.isEmpty else { continue }
                lists[path, default: []].append(stripped)
                continue
            }

            // Key-value or section line.
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let afterColon = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            let path = currentPath(joinedWith: key)

            if afterColon.isEmpty || afterColon == "|" || afterColon == ">" {
                // Section header or empty-valued key — push onto stack so children nest.
                stack.append((indent: indent, name: key))
                continue
            }

            // Inline `{}` / `[]` literals → treat as empty.
            if afterColon == "{}" {
                values[path] = ""
                maps[path] = [:]
                continue
            }
            if afterColon == "[]" {
                values[path] = ""
                lists[path] = []
                continue
            }

            values[path] = afterColon

            // Also record as a map entry under the parent, so we can treat blocks
            // like `terminal.docker_env` as `[String: String]` without a separate scan.
            if !stack.isEmpty {
                let parentPath = currentPath()
                maps[parentPath, default: [:]][key] = stripYAMLQuotes(afterColon)
            }
        }
        return ParsedYAML(values: values, lists: lists, maps: maps)
    }

    /// Strip a single layer of surrounding single or double quotes from a YAML scalar.
    nonisolated static func stripYAMLQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Gateway State

    func loadGatewayState() -> GatewayState? {
        guard let data = readFileData(HermesPaths.gatewayStateJSON) else { return nil }
        do {
            return try JSONDecoder().decode(GatewayState.self, from: data)
        } catch {
            print("[Scarf] Failed to decode gateway state: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Memory

    func loadMemoryProfiles() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: HermesPaths.memoriesDir) else { return [] }
        return entries.filter { name in
            var isDir: ObjCBool = false
            let path = HermesPaths.memoriesDir + "/" + name
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    func loadMemory(profile: String = "") -> String {
        let path = memoryPath(profile: profile, file: "MEMORY.md")
        return readFile(path) ?? ""
    }

    func loadUserProfile(profile: String = "") -> String {
        let path = memoryPath(profile: profile, file: "USER.md")
        return readFile(path) ?? ""
    }

    func saveMemory(_ content: String, profile: String = "") {
        let path = memoryPath(profile: profile, file: "MEMORY.md")
        writeFile(path, content: content)
    }

    func saveUserProfile(_ content: String, profile: String = "") {
        let path = memoryPath(profile: profile, file: "USER.md")
        writeFile(path, content: content)
    }

    private func memoryPath(profile: String, file: String) -> String {
        if profile.isEmpty {
            return HermesPaths.memoriesDir + "/" + file
        }
        return HermesPaths.memoriesDir + "/" + profile + "/" + file
    }

    // MARK: - Cron

    func loadCronJobs() -> [HermesCronJob] {
        guard let data = readFileData(HermesPaths.cronJobsJSON) else { return [] }
        do {
            let file = try JSONDecoder().decode(CronJobsFile.self, from: data)
            return file.jobs
        } catch {
            print("[Scarf] Failed to decode cron jobs: \(error.localizedDescription)")
            return []
        }
    }

    func loadCronOutput(jobId: String) -> String? {
        let dir = HermesPaths.cronOutputDir
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let matching = files.filter { $0.contains(jobId) }.sorted().last
        guard let filename = matching else { return nil }
        return readFile(dir + "/" + filename)
    }

    // MARK: - Skills

    func loadSkills() -> [HermesSkillCategory] {
        let dir = HermesPaths.skillsDir
        let fm = FileManager.default
        guard let categories = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        return categories.sorted().compactMap { categoryName in
            let categoryPath = dir + "/" + categoryName
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: categoryPath, isDirectory: &isDir), isDir.boolValue else { return nil }
            guard let skillNames = try? fm.contentsOfDirectory(atPath: categoryPath) else { return nil }

            let skills = skillNames.sorted().compactMap { skillName -> HermesSkill? in
                let skillPath = categoryPath + "/" + skillName
                var isSkillDir: ObjCBool = false
                guard fm.fileExists(atPath: skillPath, isDirectory: &isSkillDir), isSkillDir.boolValue else { return nil }
                let files = (try? fm.contentsOfDirectory(atPath: skillPath)) ?? []
                let requiredConfig = parseSkillRequiredConfig(skillPath + "/skill.yaml")
                return HermesSkill(
                    id: categoryName + "/" + skillName,
                    name: skillName,
                    category: categoryName,
                    path: skillPath,
                    files: files.sorted(),
                    requiredConfig: requiredConfig
                )
            }

            guard !skills.isEmpty else { return nil }
            return HermesSkillCategory(id: categoryName, name: categoryName, skills: skills)
        }
    }

    func loadSkillContent(path: String) -> String {
        guard isValidSkillPath(path) else { return "" }
        return readFile(path) ?? ""
    }

    func saveSkillContent(path: String, content: String) {
        guard isValidSkillPath(path) else { return }
        writeFile(path, content: content)
    }

    private func isValidSkillPath(_ path: String) -> Bool {
        guard !path.contains(".."), path.hasPrefix(HermesPaths.skillsDir) else {
            print("[Scarf] Rejected skill path outside skills directory: \(path)")
            return false
        }
        return true
    }

    private func parseSkillRequiredConfig(_ path: String) -> [String] {
        guard let content = readFile(path) else { return [] }
        var result: [String] = []
        var inRequiredConfig = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if trimmed == "required_config:" || trimmed.hasPrefix("required_config:") {
                inRequiredConfig = true
                continue
            }
            if inRequiredConfig {
                if indent < 2 && !trimmed.isEmpty {
                    break
                }
                if trimmed.hasPrefix("- ") {
                    result.append(String(trimmed.dropFirst(2)))
                }
            }
        }
        return result
    }

    // MARK: - MCP Servers

    func loadMCPServers() -> [HermesMCPServer] {
        guard let yaml = readFile(HermesPaths.configYAML) else { return [] }
        let parsed = parseMCPServersBlock(yaml: yaml)
        let fm = FileManager.default
        return parsed.map { server in
            let tokenPath = HermesPaths.mcpTokensDir + "/" + server.name + ".json"
            let hasToken = fm.fileExists(atPath: tokenPath)
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
                hasOAuthToken: hasToken
            )
        }
    }

    /// Creates the server entry via `hermes mcp add` with only the command (no args).
    /// Args are written separately via `setMCPServerArgs` to avoid argparse issues with `-`-prefixed args like `-y`.
    /// Pipes `y\n` because the CLI prompts to save even when the initial connection check fails (which it will, since we intentionally add no args first).
    @discardableResult
    func addMCPServerStdio(name: String, command: String, args: [String]) -> (exitCode: Int32, output: String) {
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
    func addMCPServerHTTP(name: String, url: String, auth: String?) -> (exitCode: Int32, output: String) {
        var cliArgs: [String] = ["mcp", "add", name, "--url", url]
        if let auth, !auth.isEmpty {
            cliArgs.append(contentsOf: ["--auth", auth])
        }
        return runHermesCLI(args: cliArgs, timeout: 45, stdinInput: "y\ny\ny\n")
    }

    @discardableResult
    func setMCPServerArgs(name: String, args: [String]) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertList(header: "args", items: args, in: &entryLines)
        }
    }

    @discardableResult
    func removeMCPServer(name: String) -> (exitCode: Int32, output: String) {
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

    private static func parseToolListFromTestOutput(_ output: String) -> [String] {
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
    func toggleMCPServerEnabled(name: String, enabled: Bool) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertScalar(key: "enabled", value: enabled ? "true" : "false", in: &entryLines)
        }
    }

    @discardableResult
    func setMCPServerEnv(name: String, env: [String: String]) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertSubMap(header: "env", map: env, in: &entryLines)
        }
    }

    @discardableResult
    func setMCPServerHeaders(name: String, headers: [String: String]) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertSubMap(header: "headers", map: headers, in: &entryLines)
        }
    }

    @discardableResult
    func updateMCPToolFilters(name: String, include: [String], exclude: [String], resources: Bool, prompts: Bool) -> Bool {
        patchMCPServerField(name: name) { entryLines in
            Self.replaceOrInsertToolsBlock(include: include, exclude: exclude, resources: resources, prompts: prompts, in: &entryLines)
        }
    }

    @discardableResult
    func setMCPServerTimeouts(name: String, timeout: Int?, connectTimeout: Int?) -> Bool {
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
    func deleteMCPOAuthToken(name: String) -> Bool {
        let path = HermesPaths.mcpTokensDir + "/" + name + ".json"
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func restartGateway() -> (exitCode: Int32, output: String) {
        runHermesCLI(args: ["gateway", "restart"], timeout: 30)
    }

    // MARK: - MCP YAML: block extractor + parser

    private struct MCPBlockLocation {
        let prefix: [String]
        let block: [String]   // includes the "mcp_servers:" header line
        let suffix: [String]
    }

    private func extractMCPBlock(yaml: String) -> MCPBlockLocation {
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

    fileprivate func parseMCPServersBlock(yaml: String) -> [HermesMCPServer] {
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
            let transport: MCPTransport = fields["url"] != nil ? .http : .stdio
            let enabledStr = fields["enabled"]?.lowercased()
            let enabled = enabledStr != "false"
            let timeout = fields["timeout"].flatMap(Int.init)
            let connectTimeout = fields["connect_timeout"].flatMap(Int.init)
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
                hasOAuthToken: false
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

    private func patchMCPServerField(name: String, mutate: (inout [String]) -> Void) -> Bool {
        guard let yaml = readFile(HermesPaths.configYAML) else { return false }
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
        writeFile(HermesPaths.configYAML, content: newYAML)
        return true
    }

    // MARK: - MCP YAML: mutators

    private static func replaceOrInsertScalar(key: String, value: String, in lines: inout [String]) {
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

    private static func removeScalar(key: String, in lines: inout [String]) {
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

    private static func replaceOrInsertList(header: String, items: [String], in lines: inout [String]) {
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

    private static func replaceOrInsertSubMap(header: String, map: [String: String], in lines: inout [String]) {
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

    private static func replaceOrInsertToolsBlock(include: [String], exclude: [String], resources: Bool, prompts: Bool, in lines: inout [String]) {
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

    private static func yamlScalar(_ value: String) -> String {
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

    private static func unquote(_ value: String) -> String {
        var v = value
        if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2) || (v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    // MARK: - Hermes Process

    func isHermesRunning() -> Bool {
        hermesPID() != nil
    }

    func hermesPID() -> pid_t? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "hermes"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            guard let firstLine = output.components(separatedBy: "\n").first(where: { !$0.isEmpty }),
                  let pid = pid_t(firstLine.trimmingCharacters(in: .whitespaces)) else { return nil }
            return pid
        } catch {
            return nil
        }
    }

    @discardableResult
    func stopHermes() -> Bool {
        // v0.9.0 fixed `hermes gateway stop` so it issues `launchctl bootout` and
        // waits for exit. Use the CLI to avoid racing launchd's KeepAlive respawn.
        if runHermesCLI(args: ["gateway", "stop"]).exitCode == 0 {
            return true
        }
        guard let pid = hermesPID() else { return false }
        return kill(pid, SIGTERM) == 0
    }

    nonisolated func hermesBinaryPath() -> String? {
        // Single source of truth for install-location candidates lives in
        // HermesPaths.hermesBinaryCandidates — keeps pipx/brew/manual lookups
        // consistent across the app.
        return HermesPaths.hermesBinaryCandidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Keys queried from the user's login shell. PATH is needed because .app
    /// bundles launched from Finder/Dock get a minimal PATH (no Homebrew, no
    /// nvm, no asdf, no mise). The credential keys are needed because Hermes
    /// resolves AI provider auth by reading env vars — a GUI-launched Scarf
    /// subprocess sees none of the `export ANTHROPIC_API_KEY=…` lines from
    /// the user's shell init files.
    private static let shellEnvKeys: [String] = [
        "PATH",
        "ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "ANTHROPIC_BASE_URL",
        "OPENAI_API_KEY", "OPENAI_BASE_URL",
        "OPENROUTER_API_KEY",
        "GEMINI_API_KEY", "GOOGLE_API_KEY",
        "GROQ_API_KEY", "MISTRAL_API_KEY", "XAI_API_KEY",
        "CLAUDE_CODE_OAUTH_TOKEN"
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
    private static let enrichedShellEnv: [String: String] = {
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
    private static func runShellProbe(script: String, interactive: Bool, timeout: TimeInterval) -> [String: String]? {
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

    /// True if any known AI-provider credential is reachable — either already
    /// in the current process env, present in the login-shell env we queried,
    /// or present in `~/.hermes/.env`. Used by Chat to warn the user before
    /// `hermes acp` fails on send with "No Anthropic credentials found".
    nonisolated static func hasAnyAICredential() -> Bool {
        let credentialKeys = shellEnvKeys.filter { $0 != "PATH" && $0 != "ANTHROPIC_BASE_URL" && $0 != "OPENAI_BASE_URL" }
        let env = enrichedEnvironment()
        for key in credentialKeys {
            if let value = env[key], !value.isEmpty {
                return true
            }
        }
        // Scan ~/.hermes/.env for KEY= lines. Uses a simple substring check —
        // good enough for a preflight hint; hermes itself does the real parse.
        let envPath = HermesPaths.home + "/.env"
        if let data = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in data.split(separator: "\n") {
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
        return false
    }

    @discardableResult
    nonisolated func runHermesCLI(args: [String], timeout: TimeInterval = 60, stdinInput: String? = nil) -> (exitCode: Int32, output: String) {
        guard let binary = hermesBinaryPath() else { return (-1, "") }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe: Pipe? = stdinInput != nil ? Pipe() : nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.environment = Self.enrichedEnvironment()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe { process.standardInput = stdinPipe }
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdinPipe?.fileHandleForReading.close()
            try? stdinPipe?.fileHandleForWriting.close()
        }
        do {
            try process.run()
            if let stdinInput, let stdinPipe, let data = stdinInput.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
                try? stdinPipe.fileHandleForWriting.close()
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let combined = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
            return (process.terminationStatus, combined)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    // MARK: - File I/O

    private func readFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func readFileData(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    private func writeFile(_ path: String, content: String) {
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            print("[Scarf] Failed to write \(path): \(error.localizedDescription)")
        }
    }
}
