import Foundation
import os

/// A single search/browse result from a skill registry.
struct HermesHubSkill: Identifiable, Sendable, Equatable {
    var id: String { identifier }
    let identifier: String      // e.g. "openai/skills/skill-creator"
    let name: String
    let description: String
    let source: String          // "official" | "skills-sh" | etc.
}

/// A local skill that has an upstream version available.
struct HermesSkillUpdate: Identifiable, Sendable, Equatable {
    var id: String { identifier }
    let identifier: String
    let currentVersion: String
    let availableVersion: String
}

@Observable
final class SkillsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "SkillsViewModel")
    private let fileService = HermesFileService()

    // MARK: - Installed skills (existing behavior)
    var categories: [HermesSkillCategory] = []
    var selectedSkill: HermesSkill?
    var skillContent = ""
    var selectedFileName: String?
    var searchText = ""
    var missingConfig: [String] = []
    var isEditing = false
    var editText = ""
    private var currentConfig = HermesConfig.empty

    // MARK: - Hub integration (new)
    var hubQuery = ""
    var hubResults: [HermesHubSkill] = []
    var updates: [HermesSkillUpdate] = []
    var isHubLoading = false
    var hubMessage: String?
    var hubSource: String = "all"

    let hubSources = ["all", "official", "skills-sh", "well-known", "github", "clawhub", "lobehub"]

    var filteredCategories: [HermesSkillCategory] {
        guard !searchText.isEmpty else { return categories }
        return categories.compactMap { category in
            let filtered = category.skills.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.category.localizedCaseInsensitiveContains(searchText)
            }
            guard !filtered.isEmpty else { return nil }
            return HermesSkillCategory(id: category.id, name: category.name, skills: filtered)
        }
    }

    var totalSkillCount: Int {
        categories.reduce(0) { $0 + $1.skills.count }
    }

    func load() {
        categories = fileService.loadSkills()
        currentConfig = fileService.loadConfig()
    }

    func selectSkill(_ skill: HermesSkill) {
        selectedSkill = skill
        let mainFile = skill.files.first(where: { $0.hasSuffix(".md") }) ?? skill.files.first
        if let file = mainFile {
            selectedFileName = file
            skillContent = fileService.loadSkillContent(path: skill.path + "/" + file)
        } else {
            selectedFileName = nil
            skillContent = ""
        }
        missingConfig = computeMissingConfig(for: skill)
    }

    private func computeMissingConfig(for skill: HermesSkill) -> [String] {
        guard !skill.requiredConfig.isEmpty else { return [] }
        guard let yaml = try? String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8) else {
            return skill.requiredConfig
        }
        return skill.requiredConfig.filter { key in
            !yaml.contains(key)
        }
    }

    func selectFile(_ file: String) {
        guard let skill = selectedSkill else { return }
        selectedFileName = file
        skillContent = fileService.loadSkillContent(path: skill.path + "/" + file)
    }

    var isMarkdownFile: Bool {
        selectedFileName?.hasSuffix(".md") == true
    }

    private var currentFilePath: String? {
        guard let skill = selectedSkill, let file = selectedFileName else { return nil }
        return skill.path + "/" + file
    }

    func startEditing() {
        editText = skillContent
        isEditing = true
    }

    func saveEdit() {
        guard let path = currentFilePath else { return }
        fileService.saveSkillContent(path: path, content: editText)
        skillContent = editText
        isEditing = false
    }

    func cancelEditing() {
        isEditing = false
    }

    // MARK: - Hub browse/search/install/update

    func browseHub() {
        isHubLoading = true
        Task.detached { [fileService, hubSource] in
            var args = ["skills", "browse", "--size", "40"]
            if hubSource != "all" { args += ["--source", hubSource] }
            let result = fileService.runHermesCLI(args: args, timeout: 30)
            let parsed = Self.parseHubList(result.output)
            await MainActor.run {
                self.isHubLoading = false
                self.hubResults = parsed
                if parsed.isEmpty {
                    self.hubMessage = result.exitCode == 0 ? "No results" : "Browse failed"
                } else {
                    self.hubMessage = nil
                }
            }
        }
    }

    func searchHub() {
        guard !hubQuery.isEmpty else {
            browseHub()
            return
        }
        isHubLoading = true
        Task.detached { [fileService, hubSource, hubQuery] in
            var args = ["skills", "search", hubQuery, "--limit", "40"]
            if hubSource != "all" { args += ["--source", hubSource] }
            let result = fileService.runHermesCLI(args: args, timeout: 30)
            let parsed = Self.parseHubList(result.output)
            await MainActor.run {
                self.isHubLoading = false
                self.hubResults = parsed
                if parsed.isEmpty {
                    self.hubMessage = "No matches"
                } else {
                    self.hubMessage = nil
                }
            }
        }
    }

    func installHubSkill(_ skill: HermesHubSkill) {
        isHubLoading = true
        hubMessage = "Installing \(skill.identifier)…"
        Task.detached { [fileService] in
            // --yes skips confirmation since we're running non-interactively.
            let result = fileService.runHermesCLI(args: ["skills", "install", skill.identifier, "--yes"], timeout: 120)
            await MainActor.run {
                self.isHubLoading = false
                self.hubMessage = result.exitCode == 0 ? "Installed \(skill.identifier)" : "Install failed"
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.hubMessage = nil
                }
            }
        }
    }

    func uninstallHubSkill(_ identifier: String) {
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["skills", "uninstall", identifier, "--yes"], timeout: 60)
            await MainActor.run {
                self.hubMessage = result.exitCode == 0 ? "Uninstalled" : "Uninstall failed"
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.hubMessage = nil
                }
            }
        }
    }

    func checkForUpdates() {
        isHubLoading = true
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["skills", "check"], timeout: 60)
            let parsed = Self.parseUpdateList(result.output)
            await MainActor.run {
                self.isHubLoading = false
                self.updates = parsed
                self.hubMessage = parsed.isEmpty ? "No updates available" : "\(parsed.count) update(s)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.hubMessage = nil
                }
            }
        }
    }

    func updateAll() {
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["skills", "update", "--yes"], timeout: 300)
            await MainActor.run {
                self.hubMessage = result.exitCode == 0 ? "Updated" : "Update failed"
                self.load()
                self.checkForUpdates()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.hubMessage = nil
                }
            }
        }
    }

    // MARK: - Parsers (best-effort, tolerant of format changes)
    // `nonisolated` so callers in `Task.detached` can run them off the main actor.

    /// Parse `hermes skills browse|search` output.
    ///
    /// Hermes emits a Rich box-drawn table with vertical bars as column separators:
    ///
    ///     │    # │ Name           │ Description            │ Source       │ Trust      │
    ///     ├──────┼────────────────┼────────────────────────┼──────────────┼────────────┤
    ///     │    1 │ 1password      │ Set up and use 1Pass…  │ official     │ ★ official │
    ///
    /// Description cells can wrap across multiple rows — the continuation rows have
    /// an empty `#` column. We join consecutive rows with the same skill by checking
    /// if the first column (after `│`) is whitespace-only.
    nonisolated private static func parseHubList(_ output: String) -> [HermesHubSkill] {
        var results: [HermesHubSkill] = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw
            // Skip everything that isn't a data row. Data rows start with `│` and
            // contain multiple `│` separators. Border rows (`┏`, `┡`, `├`, `└`, etc.)
            // are drawn with `━` or `─` and should be skipped.
            guard line.contains("│") else { continue }
            let cells = line.split(separator: "│", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            // Expect at least: leading empty, #, Name, Description, Source, Trust, trailing empty
            guard cells.count >= 6 else { continue }

            let numCell = cells[1]
            let nameCell = cells[2]
            let descCell = cells[3]
            let sourceCell = cells[4]
            // Trust column (index 5) is informational only — we ignore it in the UI.

            // Continuation row: `#` column is empty. Merge its description into the
            // last-added entry if present.
            if numCell.isEmpty {
                guard !results.isEmpty else { continue }
                let last = results.removeLast()
                let merged = [last.description, descCell].filter { !$0.isEmpty }.joined(separator: " ")
                results.append(HermesHubSkill(
                    identifier: last.identifier,
                    name: last.name,
                    description: merged,
                    source: last.source
                ))
                continue
            }
            // Header row — first data-looking row whose number cell isn't a digit.
            if Int(numCell) == nil { continue }
            // Empty name cell shouldn't happen but guard anyway.
            guard !nameCell.isEmpty else { continue }

            // Identifier: `hermes skills browse` shows the short name in the Name
            // column. For install we need the full identifier like
            // `<source>/<name>`. The CLI accepts just the name for official hub,
            // so we use that as the install target.
            let source = sourceCell
                .replacingOccurrences(of: "★", with: "")
                .trimmingCharacters(in: .whitespaces)
            results.append(HermesHubSkill(
                identifier: nameCell,   // hermes skills install accepts the name for official/hub-indexed skills
                name: nameCell,
                description: descCell,
                source: source
            ))
        }
        return results
    }

    /// Parse `hermes skills check` output for available updates. Format is
    /// undocumented; we look for `→` (U+2192) or `->` arrow markers between
    /// version strings.
    nonisolated private static func parseUpdateList(_ output: String) -> [HermesSkillUpdate] {
        var results: [HermesSkillUpdate] = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("→") || line.contains("->") else { continue }
            let marker = line.contains("→") ? "→" : "->"
            let parts = line.components(separatedBy: marker)
            guard parts.count == 2 else { continue }
            let left = parts[0].trimmingCharacters(in: .whitespaces)
            let available = parts[1].trimmingCharacters(in: .whitespaces)
            let leftTokens = left.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard leftTokens.count >= 2 else { continue }
            let identifier = leftTokens[0]
            let current = leftTokens[leftTokens.count - 1]
            results.append(HermesSkillUpdate(identifier: identifier, currentVersion: current, availableVersion: available))
        }
        return results
    }
}
