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
    /// Hermes v0.15 skill bundles read from `~/.hermes/skill-bundles/`.
    /// Populated alongside the installed-skill scan in `load()`. Empty on
    /// pre-v0.15 hosts (the directory simply doesn't exist) — the Bundles
    /// tab in `SkillsView` is capability-gated so the empty state never
    /// shows on hosts that can't have bundles.
    public var bundles: [HermesSkillBundle] = []
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
    /// Skills the last `updateAll()` left untouched because they carry
    /// local edits (Hermes v0.20.4+). Always empty on older hosts — they
    /// never skip — so the UI section stays hidden and Updates renders
    /// exactly as it did before.
    public internal(set) var skippedLocalEdits: [String] = []
    public var isHubLoading = false
    public var hubMessage: String?
    public var hubSource: String = "all"

    /// Last successful `browseHub` payload, kept around so that the
    /// "All Sources" search path can filter client-side (issue #79).
    /// `hermes skills search` with no `--source` flag routes through
    /// the centralized `hermes-index` source which can miss skills
    /// that are visible in browse — we'd rather give the user the
    /// canonical "type-to-filter" UX than chase Hermes's index gaps.
    /// Source-specific searches still shell out to the CLI for full
    /// upstream semantics. Setter is `internal` so the in-tree test
    /// suite can seed the cache without invoking the live CLI;
    /// out-of-module callers can still only read.
    public internal(set) var lastBrowseResults: [HermesHubSkill] = []

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
    ///
    /// Pinned-name set is auto-fetched from the curator state file on
    /// v0.12+ hosts; callers can override by passing an explicit set
    /// (the Curator screen does this when it has a fresher snapshot in
    /// hand).
    ///
    /// `essentialHermesAgentSkill` should be
    /// `HermesCapabilities.hasEssentialHermesAgentSkill` for the connected
    /// host (v0.20.6+). Hermes drops `hermes-agent` from every read of
    /// `skills.disabled` on those hosts even if a stale/hand-edited
    /// config.yaml still lists it, so it must never render as OFF there —
    /// doing so would show a skill as disabled when Hermes is loading it
    /// regardless. Defaults to `false` (pre-v0.20.6 behavior: render the
    /// raw config value verbatim) so existing callers are unaffected.
    @MainActor
    public func load(pinnedNames: Set<String>? = nil, essentialHermesAgentSkill: Bool = false) async {
        isLoading = true
        lastError = nil
        let ctx = context
        let xport = transport
        let pins = pinnedNames
        let essentialFloor = essentialHermesAgentSkill
        // v2.8 — instrumented so future captures show how many SSH
        // RTTs the SkillsScanner walk costs on remote (it stats
        // every ~/.hermes/skills/* directory + reads SKILL.md per).
        let cats: [HermesSkillCategory] = await ScarfMon.measureAsync(.diskIO, "skills.load") {
            await Task.detached {
                var disabled = Self.readDisabledSkillNames(context: ctx)
                if essentialFloor { disabled.remove("hermes-agent") }
                let pinned = pins ?? Self.readPinnedSkillNames(context: ctx)
                return SkillsScanner.scan(
                    context: ctx,
                    transport: xport,
                    disabledNames: disabled,
                    pinnedNames: pinned
                )
            }.value
        }
        let totalSkills = cats.reduce(0) { $0 + $1.skills.count }
        ScarfMon.event(.diskIO, "skills.load.count", count: totalSkills)
        categories = cats
        // v0.15 skill bundles. Enumerated through the same transport so
        // remote contexts work; empty on pre-v0.15 hosts where the dir
        // doesn't exist.
        let loadedBundles: [HermesSkillBundle] = await Task.detached {
            SkillBundlesScanner.scan(context: ctx, transport: xport)
        }.value
        bundles = loadedBundles
        isLoading = false
    }

    /// Read the curator's pinned-skills list from
    /// `~/.hermes/skills/.curator_state` (JSON despite the lack of an
    /// extension). Pre-v0.12 hosts won't have this file yet — return
    /// an empty set so the pin badge stays hidden.
    nonisolated static func readPinnedSkillNames(context: ServerContext) -> Set<String> {
        guard let data = context.readData(context.paths.curatorStateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        // Curator stores pins in either `pinned: [name, ...]` or
        // `pinned_skills: [name, ...]` depending on Hermes version —
        // accept both shapes so we don't break on a future rename.
        let raw = (obj["pinned"] as? [String]) ?? (obj["pinned_skills"] as? [String]) ?? []
        return Set(raw)
    }

    /// Read the `skills.disabled:` array from `~/.hermes/config.yaml`.
    /// Hermes v0.12 stores skill disable state there (one global list
    /// + optional `skills.platform_disabled` overrides). Returns the
    /// global list only — Scarf doesn't surface platform overrides
    /// today. Empty set on missing file / parse failure.
    nonisolated static func readDisabledSkillNames(context: ServerContext) -> Set<String> {
        guard let yaml = context.readText(context.paths.configYAML) else { return [] }
        // Lightweight match: find `skills:` block, then `disabled:` array
        // inside it. The full YAML parser is overkill for one nested array.
        var inSkillsBlock = false
        var disabledIndent: Int?
        var collected: [String] = []
        for raw in yaml.components(separatedBy: "\n") {
            // Top-level `skills:` declaration.
            if raw.hasPrefix("skills:") {
                inSkillsBlock = true
                continue
            }
            if inSkillsBlock {
                // A new top-level block ends the `skills:` scope.
                if !raw.hasPrefix(" ") && !raw.hasPrefix("\t") && raw.contains(":") {
                    break
                }
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("disabled:") {
                    // Inline form `disabled: [a, b, c]`
                    let after = trimmed.dropFirst("disabled:".count).trimmingCharacters(in: .whitespaces)
                    if after.hasPrefix("[") && after.hasSuffix("]") {
                        let body = after.dropFirst().dropLast()
                        let parts = body.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        for p in parts where !p.isEmpty {
                            collected.append(p.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
                        }
                        return Set(collected)
                    }
                    // Block form: `disabled:` followed by `  - name`
                    disabledIndent = raw.prefix { $0 == " " || $0 == "\t" }.count
                    continue
                }
                if let baseIndent = disabledIndent {
                    let leading = raw.prefix { $0 == " " || $0 == "\t" }.count
                    if !trimmed.isEmpty {
                        // PyYAML's default `yaml.dump` emits list items at the
                        // same indent as the parent key, so `- foo` lines for
                        // `disabled:` arrive at `leading == baseIndent`. Only
                        // a strictly shallower indent — or a same-indent line
                        // that isn't a list item (sibling key) — ends the block.
                        if leading < baseIndent { break }
                        if leading == baseIndent && !trimmed.hasPrefix("- ") { break }
                    }
                    if trimmed.hasPrefix("- ") {
                        let name = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                        if !name.isEmpty {
                            collected.append(String(name))
                        }
                    }
                }
            }
        }
        return Set(collected)
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
            await self?.finishBrowse(
                results: parsed,
                exitCode: result.exitCode,
                rawOutput: result.output,
                isSearch: false
            )
        }
    }

    public func searchHub() {
        guard !hubQuery.isEmpty else {
            browseHub()
            return
        }
        let source = hubSource
        let query = hubQuery
        // Issue #79 — for "All Sources", filter the cached browse list
        // client-side instead of shelling out. Hermes's all-source
        // search routes through its centralized index which can miss
        // skills (e.g. honcho) that browse surfaces from non-indexed
        // registries. Specific-source searches keep the CLI path so
        // power users still get full upstream search semantics.
        if source == "all" {
            if lastBrowseResults.isEmpty {
                // No cache yet — kick off a browse, then filter on
                // completion. The chained call lets the user type a
                // query before ever clicking Browse.
                browseHubThenFilter(query: query)
            } else {
                // Pure in-memory filter — runs synchronously on the
                // calling actor (UI invocations are already on
                // MainActor) so the user sees the narrowed list
                // without a render-tick gap.
                applyClientSideFilter(query: query, against: lastBrowseResults)
            }
            return
        }
        isHubLoading = true
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            let args = ["skills", "search", query, "--limit", "40", "--source", source]
            let result = Self.runHermes(executable: bin, args: args, transport: xport, timeout: 30)
            let parsed = HermesSkillsHubParser.parseHubList(result.output)
            await self?.finishBrowse(
                results: parsed,
                exitCode: result.exitCode,
                rawOutput: result.output,
                isSearch: true
            )
        }
    }

    /// Run a browse fetch and then immediately apply a client-side
    /// filter. Used by `searchHub` when the user types into search
    /// before any browse has cached results.
    private func browseHubThenFilter(query: String) {
        isHubLoading = true
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            let args = ["skills", "browse", "--size", "40"]
            let result = Self.runHermes(executable: bin, args: args, transport: xport, timeout: 30)
            let parsed = HermesSkillsHubParser.parseHubList(result.output)
            await self?.finishBrowseThenFilter(
                browseResults: parsed,
                query: query,
                exitCode: result.exitCode,
                rawOutput: result.output
            )
        }
    }

    @MainActor
    private func finishBrowseThenFilter(
        browseResults: [HermesHubSkill],
        query: String,
        exitCode: Int32,
        rawOutput: String
    ) async {
        if exitCode == 0 {
            lastBrowseResults = browseResults
            applyClientSideFilter(query: query, against: browseResults)
        } else {
            // Surface the underlying browse failure rather than a
            // blank "no matches" state — the user typed a query, not
            // a browse request, but the cache was empty so we tried.
            isHubLoading = false
            hubResults = []
            let detail = Self.firstSignificantLine(rawOutput)
            hubMessage = detail.isEmpty
                ? "Search failed (exit \(exitCode))"
                : "Search failed: \(detail)"
        }
    }

    private func applyClientSideFilter(query: String, against pool: [HermesHubSkill]) {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matches: [HermesHubSkill]
        if needle.isEmpty {
            matches = pool
        } else {
            matches = pool.filter { skill in
                skill.name.localizedCaseInsensitiveContains(needle)
                    || skill.description.localizedCaseInsensitiveContains(needle)
                    || skill.identifier.localizedCaseInsensitiveContains(needle)
            }
        }
        isHubLoading = false
        hubResults = matches
        hubMessage = matches.isEmpty ? "No matches" : nil
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

    /// v0.12: install a skill from a direct HTTPS URL pointing at a
    /// SKILL.md (or a tarball). Hermes pulls + installs without going
    /// through the registry indirection. The Mac UI gates this on
    /// `HermesCapabilities.hasSkillURLInstall` so a v0.11 host doesn't
    /// see a button that errors out with "unrecognized argument".
    ///
    /// `categoryOverride` and `nameOverride` map to `--category` /
    /// `--name` flags Hermes ships for direct-URL installs (the URL's
    /// SKILL.md may not declare those, especially for one-off scripts).
    public func installFromURL(
        _ url: String,
        categoryOverride: String? = nil,
        nameOverride: String? = nil
    ) {
        isHubLoading = true
        hubMessage = "Installing from URL…"
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            var args = ["skills", "install", url, "--yes"]
            if let category = categoryOverride, !category.isEmpty {
                args += ["--category", category]
            }
            if let name = nameOverride, !name.isEmpty {
                args += ["--name", name]
            }
            let result = Self.runHermes(
                executable: bin,
                args: args,
                transport: xport,
                timeout: 180
            )
            await self?.finishInstall(identifier: url, exitCode: result.exitCode)
        }
    }

    /// v0.12: trigger a hot reload of `~/.hermes/skills/` so the agent
    /// picks up file edits without a session restart. Hermes ships
    /// `/reload-skills` as a slash command in chat AND `hermes skills
    /// audit` as a CLI form. We use `audit` here so the reload works
    /// even when no chat session is active.
    public func reloadSkills() async {
        isHubLoading = true
        let bin = context.paths.hermesBinary
        let xport = transport
        let result = await Task.detached {
            Self.runHermes(
                executable: bin,
                args: ["skills", "audit"],
                transport: xport,
                timeout: 30
            )
        }.value
        hubMessage = result.exitCode == 0 ? "Skills reloaded" : "Reload failed"
        isHubLoading = false
        await load()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.hubMessage = nil
        }
    }

    /// `skills uninstall` has no `--yes` flag (argparse exits 2 if passed —
    /// this action silently failed for every release that sent it). The
    /// command confirms via an interactive `input("Confirm [y/N]: ")` prompt
    /// that reads EOF as "n" when stdin is closed, so the caller must feed a
    /// "y" line (`uninstallStdin`) to confirm non-interactively.
    nonisolated static func uninstallArgs(_ identifier: String) -> [String] {
        ["skills", "uninstall", identifier]
    }
    nonisolated static let uninstallStdin = "y\n"

    /// `skills update` has no `--yes` flag (argparse exits 2 if passed) and
    /// never prompts — `do_update` in hermes_cli/skills_hub.py runs straight
    /// through. Omitting the optional `name` positional updates all outdated
    /// skills.
    nonisolated static let updateAllArgs = ["skills", "update"]

    public func uninstallHubSkill(_ identifier: String) {
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            let result = Self.runHermes(
                executable: bin,
                args: Self.uninstallArgs(identifier),
                transport: xport,
                timeout: 60,
                stdin: Self.uninstallStdin
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

    /// Single-skill forced update. `--force` makes Hermes overwrite a
    /// skill the user has edited on disk, destroying those edits — so it
    /// is ONLY ever sent for one explicitly named skill, chosen by the
    /// user from the "kept local edits" list. `updateAll()` must never
    /// carry it.
    ///
    /// v0.20.4+ only. Callers gate on
    /// `HermesCapabilities.hasSkillsUpdateForce`; older hosts have no
    /// skip behaviour to override and don't surface the action.
    nonisolated static func forceUpdateArgs(_ name: String) -> [String] {
        ["skills", "update", name, "--force"]
    }

    public func updateAll() {
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            let result = Self.runHermes(
                executable: bin,
                args: Self.updateAllArgs,
                transport: xport,
                timeout: 300
            )
            let report = HermesSkillsHubParser.parseUpdateReport(result.output)
            await self?.finishUpdateAll(exitCode: result.exitCode, report: report)
        }
    }

    /// Re-run the update for one skill with `--force`, discarding that
    /// skill's local edits. Gate the call site on `hasSkillsUpdateForce`.
    public func forceUpdateSkill(_ name: String) {
        let bin = context.paths.hermesBinary
        let xport = transport
        isHubLoading = true
        Task.detached { [weak self] in
            let result = Self.runHermes(
                executable: bin,
                args: Self.forceUpdateArgs(name),
                transport: xport,
                timeout: 300
            )
            await self?.finishForceUpdate(name: name, exitCode: result.exitCode)
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
    private func finishBrowse(
        results: [HermesHubSkill],
        exitCode: Int32,
        rawOutput: String,
        isSearch: Bool
    ) async {
        isHubLoading = false
        hubResults = results
        // Cache the fresh browse payload so the "All Sources" search
        // path can filter client-side (issue #79). Search results are
        // not cached — they're already filtered by the user's query
        // and would poison the filter pool.
        if !isSearch && exitCode == 0 {
            lastBrowseResults = results
        }
        if results.isEmpty {
            if exitCode == 0 {
                hubMessage = isSearch ? "No matches" : "No results"
            } else {
                let label = isSearch ? "Search failed" : "Browse failed"
                let detail = Self.firstSignificantLine(rawOutput)
                hubMessage = detail.isEmpty
                    ? "\(label) (exit \(exitCode))"
                    : "\(label): \(detail)"
            }
        } else {
            hubMessage = nil
        }
    }

    /// Extract the first non-empty, non-decorative line from CLI output —
    /// used to surface the actual error reason in `hubMessage` instead of a
    /// canned "Browse failed". Skips Rich box-drawing chrome and ANSI noise
    /// so the message stays readable in a one-line banner.
    ///
    /// The ESC byte is spelled with an ICU `\x1B` escape, NOT Swift's
    /// `\u{001B}`: this pattern is a RAW string handed to
    /// `NSRegularExpression`, where Swift performs no escape processing
    /// at all — the engine received those seven literal characters,
    /// which ICU reads as `` followed by a stray `{}`, so the
    /// pattern never matched a real escape sequence and ANSI colour
    /// codes reached the banner verbatim.
    nonisolated static func firstSignificantLine(_ output: String) -> String {
        let stripped = output
            .replacingOccurrences(
                of: #"\x1B\[[0-9;]*[a-zA-Z]"#,
                with: "",
                options: .regularExpression
            )
        for raw in stripped.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.unicodeScalars.allSatisfy({ scalar in
                let v = scalar.value
                // Skip pure box-drawing rows (U+2500..U+257F) so the
                // diagnostic surfaces the actual error text below them.
                return (v >= 0x2500 && v <= 0x257F) || scalar == " "
            }) { continue }
            return String(line.prefix(160))
        }
        return ""
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
    private func finishUpdateAll(exitCode: Int32, report: HermesSkillsUpdateReport) async {
        skippedLocalEdits = exitCode == 0 ? report.skipped : []
        if exitCode != 0 {
            hubMessage = "Update failed"
        } else if report.skipped.isEmpty {
            // Pre-v0.20.4 and clean v0.20.4 runs land here — same
            // wording the UI has always shown.
            hubMessage = "Updated"
        } else {
            hubMessage = "Updated \(report.updatedCount) · \(report.skipped.count) kept local edits"
        }
        await load()
        checkForUpdates()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hubMessage = nil
    }

    @MainActor
    private func finishForceUpdate(name: String, exitCode: Int32) async {
        isHubLoading = false
        if exitCode == 0 {
            skippedLocalEdits.removeAll { $0 == name }
            hubMessage = "Updated \(name) (local edits discarded)"
        } else {
            hubMessage = "Update failed for \(name)"
        }
        await load()
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
        timeout: TimeInterval,
        stdin: String? = nil
    ) -> (exitCode: Int32, output: String) {
        do {
            let result = try transport.runProcess(
                executable: executable,
                args: args,
                stdin: stdin.flatMap { $0.data(using: .utf8) },
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
        guard Self.skillPathIsContained(path, skillsDir: context.paths.skillsDir) else {
            logger.warning("Rejected skill path outside skills dir: \(path, privacy: .public)")
            return false
        }
        return true
    }

    /// Containment check for a skill file path, gating both the editor's
    /// read and its write-back.
    ///
    /// The `..`-plus-`hasPrefix` pair below is a purely LEXICAL guarantee —
    /// neither operation follows symlinks — so on its own it waved through
    /// `~/.hermes/skills/<cat>/<skill>/SKILL.md` being a symlink to
    /// somewhere else entirely, and `transport.writeFile` then wrote
    /// THROUGH the link, outside the skills root. Skills are agent- and
    /// installer-writable, and a hub skill arrives as a downloaded
    /// tarball, so the link need not be user-made.
    ///
    /// The symlink layer applies the convention's resolve-BOTH-sides rule
    /// through the tested `MiniAppAssetResolver.isSymlinkContained`. As in
    /// `WidgetPathResolver.resolve`, it is deliberately NOT
    /// `containedFilePath`: that helper also demands the file exist
    /// locally as a non-directory, which is wrong here because skill I/O
    /// goes through `ServerContext`'s transport and the skills tree may
    /// live on a REMOTE host. Hence the gate on the skills dir existing
    /// locally — for a remote context there is nothing to stat and no way
    /// to see a remote symlink from here, so the lexical rule stands alone.
    nonisolated static func skillPathIsContained(_ path: String, skillsDir: String) -> Bool {
        guard !path.contains(".."), path.hasPrefix(skillsDir) else { return false }
        if FileManager.default.fileExists(atPath: skillsDir),
           !MiniAppAssetResolver.isSymlinkContained(path: path, baseDirectory: skillsDir) {
            return false
        }
        return true
    }
}
