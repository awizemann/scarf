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

        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 && trimmed.hasSuffix(":") {
                currentSection = String(trimmed.dropLast())
                continue
            }

            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let val = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
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
            autoTTS: values["voice.auto_tts"] != "false"
        )
    }

    // MARK: - Gateway State

    func loadGatewayState() -> GatewayState? {
        guard let data = readFileData(HermesPaths.gatewayStateJSON) else { return nil }
        return try? JSONDecoder().decode(GatewayState.self, from: data)
    }

    // MARK: - Memory

    func loadMemory() -> String {
        readFile(HermesPaths.memoryMD) ?? ""
    }

    func loadUserProfile() -> String {
        readFile(HermesPaths.userMD) ?? ""
    }

    func saveMemory(_ content: String) {
        writeFile(HermesPaths.memoryMD, content: content)
    }

    func saveUserProfile(_ content: String) {
        writeFile(HermesPaths.userMD, content: content)
    }

    // MARK: - Cron

    func loadCronJobs() -> [HermesCronJob] {
        guard let data = readFileData(HermesPaths.cronJobsJSON) else { return [] }
        let file = try? JSONDecoder().decode(CronJobsFile.self, from: data)
        return file?.jobs ?? []
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
                return HermesSkill(
                    id: categoryName + "/" + skillName,
                    name: skillName,
                    category: categoryName,
                    path: skillPath,
                    files: files.sorted()
                )
            }

            guard !skills.isEmpty else { return nil }
            return HermesSkillCategory(id: categoryName, name: categoryName, skills: skills)
        }
    }

    func loadSkillContent(path: String) -> String {
        readFile(path) ?? ""
    }

    // MARK: - Hermes Process

    func isHermesRunning() -> Bool {
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
            return !data.isEmpty
        } catch {
            return false
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
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
