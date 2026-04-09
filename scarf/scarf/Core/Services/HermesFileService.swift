import Foundation

struct HermesFileService: Sendable {

    // MARK: - Config

    func loadConfig() -> HermesConfig {
        guard let content = readFile(HermesPaths.configYAML) else { return .empty }
        return parseConfig(content)
    }

    private func parseConfig(_ yaml: String) -> HermesConfig {
        var values: [String: String] = [:]
        var currentSection = ""
        var dockerEnv: [String: String] = [:]
        var commandAllowlist: [String] = []
        var inDockerEnv = false
        var inAllowlist = false

        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            // Detect end of nested blocks when indent returns to section level
            if indent <= 2 && (inDockerEnv || inAllowlist) {
                inDockerEnv = false
                inAllowlist = false
            }

            // Collect docker_env nested key-value pairs
            if inDockerEnv, indent >= 4, let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let val = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                dockerEnv[key] = val
                continue
            }

            // Collect allowlist items
            if inAllowlist, indent >= 4, trimmed.hasPrefix("- ") {
                commandAllowlist.append(String(trimmed.dropFirst(2)))
                continue
            }

            if indent == 0 && trimmed.hasSuffix(":") {
                currentSection = String(trimmed.dropLast())
                continue
            }

            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let val = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

                if key == "docker_env" && val.isEmpty {
                    inDockerEnv = true
                    continue
                }
                if key == "permanent_allowlist" && val.isEmpty {
                    inAllowlist = true
                    continue
                }

                values[currentSection + "." + key] = val
            }
        }

        return HermesConfig(
            model: values["model.default"] ?? "unknown",
            provider: values["model.provider"] ?? "unknown",
            maxTurns: Int(values["agent.max_turns"] ?? "") ?? 0,
            personality: values["display.personality"] ?? "default",
            terminalBackend: values["terminal.backend"] ?? "local",
            memoryEnabled: values["memory.memory_enabled"] == "true",
            memoryCharLimit: Int(values["memory.memory_char_limit"] ?? "") ?? 0,
            userCharLimit: Int(values["memory.user_char_limit"] ?? "") ?? 0,
            nudgeInterval: Int(values["memory.nudge_interval"] ?? "") ?? 0,
            streaming: values["display.streaming"] != "false",
            showReasoning: values["display.show_reasoning"] == "true",
            verbose: values["agent.verbose"] == "true",
            autoTTS: values["voice.auto_tts"] != "false",
            silenceThreshold: Int(values["voice.silence_threshold"] ?? "") ?? QueryDefaults.defaultSilenceThreshold,
            reasoningEffort: values["agent.reasoning_effort"] ?? "medium",
            showCost: values["display.show_cost"] == "true",
            approvalMode: values["approvals.mode"] ?? "manual",
            browserBackend: values["browser.backend"] ?? "",
            memoryProvider: values["memory.provider"] ?? "",
            dockerEnv: dockerEnv,
            commandAllowlist: commandAllowlist,
            memoryProfile: values["memory.profile"] ?? ""
        )
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
        guard let pid = hermesPID() else { return false }
        return kill(pid, SIGTERM) == 0
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
