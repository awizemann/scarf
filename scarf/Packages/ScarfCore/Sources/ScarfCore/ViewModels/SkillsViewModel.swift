import Foundation
import os

/// Unified Skills viewmodel. Promoted from the Mac target into ScarfCore
/// in v2.5 so iOS and Mac share the exact same Installed / Hub / Updates
/// state machine. Replaces the old Mac `SkillsViewModel` and the
/// minimal iOS `IOSSkillsViewModel`.
///
/// Transport-backed throughout: skill scanning goes through
/// `SkillsScanner.scan(context:transport:)`, file I/O goes through
/// `transport.readFile / writeFile`, and CLI invocations go through
/// `transport.runProcess(executable:args:stdin:timeout:)`. iOS gets the
/// same hub features as Mac without a target-specific code path.
@Observable
public final class SkillsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "SkillsViewModel")
    public let context: ServerContext
    private let transport: any ServerTransport

    public init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    // MARK: - Installed skills

    public var categories: [HermesSkillCategory] = []
    public var selectedSkill: HermesSkill?
    public var skillContent = ""
    public var selectedFileName: String?
    public var searchText = ""
    public var missingConfig: [String] = []
    public var isEditing = false
    public var editText = ""
    /// True while the installed-skills scan is in flight. Renders a
    /// progress indicator on iOS; Mac historically didn't surface this
    /// from VM state but adding it doesn't break the existing UI.
    public var isLoading: Bool = false
    /// Diagnostic for a failed scan. Nil on success or when the dir
    /// is simply missing (fresh install).
    public var lastError: String?

    // MARK: - Hub integration

    public var hubQuery = ""
    public var hubResults: [HermesHubSkill] = []
    public var updates: [HermesSkillUpdate] = []
    public var isHubLoading = false
    public var hubMessage: String?
    public var hubSource: String = "all"

    public let hubSources = ["all", "official", "skills-sh", "well-known", "github", "clawhub", "lobehub"]

    public var filteredCategories: [HermesSkillCategory] {
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

    public var totalSkillCount: Int {
        categories.reduce(0) { $0 + $1.skills.count }
    }

    /// Awaitable scan. iOS's `.task { await vm.load() }` and the
    /// ScarfCore unit tests use this directly; Mac call sites wrap in
    /// `Task { await ... }` from `onAppear`.
    @MainActor
    public func load() async {
        isLoading = true
        lastError = nil
        let ctx = context
        let xport = transport
        let cats: [HermesSkillCategory] = await Task.detached {
            SkillsScanner.scan(context: ctx, transport: xport)
        }.value
        categories = cats
        isLoading = false
    }

    public func selectSkill(_ skill: HermesSkill) {
        selectedSkill = skill
        let mainFile = skill.files.first(where: { $0.hasSuffix(".md") }) ?? skill.files.first
        if let file = mainFile {
            selectedFileName = file
            skillContent = loadSkillContent(path: skill.path + "/" + file)
        } else {
            selectedFileName = nil
            skillContent = ""
        }
        missingConfig = computeMissingConfig(for: skill)
    }

    private func computeMissingConfig(for skill: HermesSkill) -> [String] {
        guard !skill.requiredConfig.isEmpty else { return [] }
        guard let yaml = context.readText(context.paths.configYAML) else {
            return skill.requiredConfig
        }
        return skill.requiredConfig.filter { key in
            !yaml.contains(key)
        }
    }

    public func selectFile(_ file: String) {
        guard let skill = selectedSkill else { return }
        selectedFileName = file
        skillContent = loadSkillContent(path: skill.path + "/" + file)
    }

    public var isMarkdownFile: Bool {
        selectedFileName?.hasSuffix(".md") == true
    }

    private var currentFilePath: String? {
        guard let skill = selectedSkill, let file = selectedFileName else { return nil }
        return skill.path + "/" + file
    }

    public func startEditing() {
        editText = skillContent
        isEditing = true
    }

    public func saveEdit() {
        guard let path = currentFilePath else { return }
        saveSkillContent(path: path, content: editText)
        skillContent = editText
        isEditing = false
    }

    public func cancelEditing() {
        isEditing = false
    }

    // MARK: - Hub browse / search / install / update

    public func browseHub() {
        isHubLoading = true
        let bin = context.paths.hermesBinary
        let xport = transport
        let source = hubSource
        Task.detached { [weak self] in
            var args = ["skills", "browse", "--size", "40"]
            if source != "all" { args += ["--source", source] }
            let result = Self.runHermes(executable: bin, args: args, transport: xport, timeout: 30)
            let parsed = HermesSkillsHubParser.parseHubList(result.output)
            await self?.finishBrowse(results: parsed, exitCode: result.exitCode, isSearch: false)
        }
    }

    public func searchHub() {
        guard !hubQuery.isEmpty else {
            browseHub()
            return
        }
        isHubLoading = true
        let bin = context.paths.hermesBinary
        let xport = transport
        let source = hubSource
        let query = hubQuery
        Task.detached { [weak self] in
            var args = ["skills", "search", query, "--limit", "40"]
            if source != "all" { args += ["--source", source] }
            let result = Self.runHermes(executable: bin, args: args, transport: xport, timeout: 30)
            let parsed = HermesSkillsHubParser.parseHubList(result.output)
            await self?.finishBrowse(results: parsed, exitCode: result.exitCode, isSearch: true)
        }
    }

    public func installHubSkill(_ skill: HermesHubSkill) {
        isHubLoading = true
        hubMessage = "Installing \(skill.identifier)…"
        let bin = context.paths.hermesBinary
        let xport = transport
        let identifier = skill.identifier
        Task.detached { [weak self] in
            // --yes skips confirmation since we're running non-interactively.
            let result = Self.runHermes(
                executable: bin,
                args: ["skills", "install", identifier, "--yes"],
                transport: xport,
                timeout: 120
            )
            await self?.finishInstall(identifier: identifier, exitCode: result.exitCode)
        }
    }

    public func uninstallHubSkill(_ identifier: String) {
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            let result = Self.runHermes(
                executable: bin,
                args: ["skills", "uninstall", identifier, "--yes"],
                transport: xport,
                timeout: 60
            )
            await self?.finishUninstall(exitCode: result.exitCode)
        }
    }

    public func checkForUpdates() {
        isHubLoading = true
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            let result = Self.runHermes(
                executable: bin,
                args: ["skills", "check"],
                transport: xport,
                timeout: 60
            )
            let parsed = HermesSkillsHubParser.parseUpdateList(result.output)
            await self?.finishCheckForUpdates(updates: parsed)
        }
    }

    public func updateAll() {
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            let result = Self.runHermes(
                executable: bin,
                args: ["skills", "update", "--yes"],
                transport: xport,
                timeout: 300
            )
            await self?.finishUpdateAll(exitCode: result.exitCode)
        }
    }

    // MARK: - Hub action finishers
    //
    // Each detached task above bounces through exactly one of these
    // MainActor-isolated finishers. Keeping the post-CLI sequencing
    // (load + sleep + clear status) here means the detached closure
    // crosses the `self?` weak boundary only once — required for clean
    // builds under Swift 6 strict concurrency, and clearer to reason
    // about than the prior interleaved `MainActor.run` chains.

    @MainActor
    private func finishBrowse(results: [HermesHubSkill], exitCode: Int32, isSearch: Bool) async {
        isHubLoading = false
        hubResults = results
        if results.isEmpty {
            hubMessage = isSearch
                ? "No matches"
                : (exitCode == 0 ? "No results" : "Browse failed")
        } else {
            hubMessage = nil
        }
    }

    @MainActor
    private func finishInstall(identifier: String, exitCode: Int32) async {
        isHubLoading = false
        hubMessage = exitCode == 0 ? "Installed \(identifier)" : "Install failed"
        await load()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hubMessage = nil
    }

    @MainActor
    private func finishUninstall(exitCode: Int32) async {
        hubMessage = exitCode == 0 ? "Uninstalled" : "Uninstall failed"
        await load()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        hubMessage = nil
    }

    @MainActor
    private func finishCheckForUpdates(updates: [HermesSkillUpdate]) async {
        isHubLoading = false
        self.updates = updates
        hubMessage = updates.isEmpty ? "No updates available" : "\(updates.count) update(s)"
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hubMessage = nil
    }

    @MainActor
    private func finishUpdateAll(exitCode: Int32) async {
        hubMessage = exitCode == 0 ? "Updated" : "Update failed"
        await load()
        checkForUpdates()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hubMessage = nil
    }

    // MARK: - Transport helpers

    /// Combined stdout+stderr CLI runner. Mirrors the legacy
    /// `HermesFileService.runHermesCLI` shape so callers grepping
    /// through `output` keep working.
    nonisolated private static func runHermes(
        executable: String,
        args: [String],
        transport: any ServerTransport,
        timeout: TimeInterval
    ) -> (exitCode: Int32, output: String) {
        do {
            let result = try transport.runProcess(
                executable: executable,
                args: args,
                stdin: nil,
                timeout: timeout
            )
            return (result.exitCode, result.stdoutString + result.stderrString)
        } catch let error as TransportError {
            return (-1, error.diagnosticStderr.isEmpty
                ? (error.errorDescription ?? "transport error")
                : error.diagnosticStderr)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func loadSkillContent(path: String) -> String {
        guard isValidSkillPath(path) else { return "" }
        guard let data = try? transport.readFile(path),
              let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s
    }

    private func saveSkillContent(path: String, content: String) {
        guard isValidSkillPath(path) else { return }
        guard let data = content.data(using: .utf8) else { return }
        do {
            try transport.writeFile(path, data: data)
        } catch {
            logger.error("saveSkillContent(\(path, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isValidSkillPath(_ path: String) -> Bool {
        guard !path.contains(".."), path.hasPrefix(context.paths.skillsDir) else {
            logger.warning("Rejected skill path outside skills dir: \(path, privacy: .public)")
            return false
        }
        return true
    }
}
