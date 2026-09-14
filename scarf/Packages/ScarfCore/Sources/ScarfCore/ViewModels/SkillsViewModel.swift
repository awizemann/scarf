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
/// `@MainActor` on the whole type, not on a handful of methods.
///
/// ScarfCore builds in Swift 5 language mode with no default actor isolation,
/// so a method with no annotation here is genuinely nonisolated — and several
/// of them (`selectSkill`, `selectFile`, the load/apply pair) mutate
/// `@Observable` state SwiftUI reads on the main actor. Annotating only the
/// offenders leaves the type half-isolated, which is how the hole appeared in
/// the first place; the I/O that must stay off the main actor is already
/// factored into `nonisolated static` helpers called from explicit
/// `Task.detached` hops (charter C10), and those keep working unchanged.
@Observable
@MainActor
public final class SkillsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "SkillsViewModel")
    public let context: ServerContext
    private let transport: any ServerTransport

    public init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    /// Test seam: run against an injected transport instead of the one the
    /// context would make. Not public — the app always goes through
    /// `init(context:)`.
    init(context: ServerContext, transport: any ServerTransport) {
        self.context = context
        self.transport = transport
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
    /// The proof token behind `skillContent`. Nil means the current file was
    /// never read successfully — the viewer shows an empty buffer and Save
    /// is impossible, because saving that buffer is precisely how the old
    /// `?? ""` loader destroyed skills (GW-E2c).
    private var loadedContent: GuardedTextFile.Loaded?
    /// Why the current file couldn't be read or saved. Nil when all is well.
    /// The Skills editor reads this to explain a disabled Edit button.
    public private(set) var contentError: String?
    /// True when the selected file was read successfully and may be edited.
    public var canEditSelectedFile: Bool { loadedContent != nil }
    /// True while the selected file's contents are being read on a detached
    /// task (GW-F6 / PERF H1). Views render a spinner and keep Edit
    /// disabled — `canEditSelectedFile` is already false during the load
    /// because the proof token is dropped first, so this only distinguishes
    /// "still reading" from "read and refused".
    public private(set) var isLoadingContent = false
    /// True while a save is in flight. Disables the Save button so a
    /// double-tap can't start a second detached write.
    public private(set) var isSavingContent = false
    /// Stamps each content load so a slow one that lands after the user has
    /// moved to another file is discarded instead of painting stale text.
    private var contentToken: UInt64 = 0
    /// Skill files are hand-sized markdown. Past this a file is not an
    /// editable buffer; the guard refuses rather than republishing it.
    nonisolated static let maxSkillFileBytes = 8 * 1024 * 1024
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
    /// Rows `hermes skills check` reported as `update_available` — the
    /// only ones `hermes skills update` acts on.
    public var updates: [HermesSkillUpdate] = []
    /// Rows the same check reported as `orphaned` / `unavailable` /
    /// `invalid_install`. These are faults the user has to fix by hand;
    /// "Update All" cannot help them, and counting them as updates was
    /// the reason the tab promised work it could never do.
    public internal(set) var updateFaults: [HermesSkillUpdate] = []
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

    /// Host capability snapshot, used for the hub `--source` roster and to
    /// decide whether `skills search` can be asked for `--json`.
    ///
    /// Refreshed from `HermesVersionCache` by `load()` (one shared probe per
    /// server, already warm by the time the Hub tab is reachable). Settable
    /// so a view that already holds a resolved snapshot — and the test suite
    /// — can seed it without a probe. `.empty` (undetected) keeps the
    /// pre-target behaviour: the seven sources Scarf always offered, and the
    /// table parse.
    public var capabilities: HermesCapabilities = .empty

    /// `--source` choices for the hub pickers, gated by the floor at which
    /// each choice entered Hermes's `_SOURCE_CHOICES`
    /// (`hermes_cli/subcommands/skills.py`). argparse REJECTS an unknown
    /// `--source` value, so an ungated list turns a search on an older host
    /// into an exit-2 usage error rather than a degraded result.
    ///
    /// - the first seven are the pre-v0.15 set Scarf already shipped;
    /// - `browse-sh` arrived at v0.15 (`hasSkillsBrowseSHSource`);
    /// - the seven provider filters arrived together at v0.18
    ///   (`hasSkillsProviderSources`) — they are GitHub taps stored under
    ///   `source="github"`, not separate registries.
    public var hubSources: [String] {
        var sources = ["all", "official", "skills-sh", "well-known", "github", "clawhub", "lobehub"]
        if capabilities.hasSkillsBrowseSHSource { sources.append("browse-sh") }
        if capabilities.hasSkillsProviderSources {
            sources += ["nvidia", "openai", "anthropic", "huggingface", "voltagent", "gstack", "minimax"]
        }
        return sources
    }

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
        // One shared, cached `hermes --version` probe per server — this is
        // the same instance every other gated surface reads, so the Hub
        // tab's source roster and `--json` decision agree with the rest of
        // the app instead of re-probing.
        if !capabilities.detected {
            capabilities = await HermesVersionCache.shared.capabilities(for: ctx)
        }
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

    public func selectSkill(_ skill: HermesSkill) async {
        selectedSkill = skill
        let mainFile = skill.files.first(where: { $0.hasSuffix(".md") }) ?? skill.files.first
        if let file = mainFile {
            selectedFileName = file
            let path = skill.path + "/" + file
            await loadSelectedFile(path: path)
        } else {
            // No file to show is not a read failure — blank the viewer
            // without an error.
            selectedFileName = nil
            loadedContent = nil
            skillContent = ""
            contentError = nil
            isLoadingContent = false
        }
        // The config.yaml read is a transport read — an SSH round-trip on a
        // remote host — so it goes off the main actor like every other read
        // in this file (C10). Skipped entirely when the skill declares no
        // required config, exactly as before.
        if skill.requiredConfig.isEmpty {
            missingConfig = []
        } else {
            let ctx = context
            let yaml = await Task.detached(priority: .userInitiated) {
                ctx.readText(ctx.paths.configYAML)
            }.value
            missingConfig = Self.computeMissingConfig(for: skill, yaml: yaml)
        }
    }

    /// An unreadable config.yaml means "we cannot prove any key is present",
    /// so every required key is reported missing — the same answer as before.
    nonisolated static func computeMissingConfig(for skill: HermesSkill, yaml: String?) -> [String] {
        guard !skill.requiredConfig.isEmpty else { return [] }
        guard let yaml else { return skill.requiredConfig }
        return skill.requiredConfig.filter { key in
            !yaml.contains(key)
        }
    }

    public func selectFile(_ file: String) async {
        guard let skill = selectedSkill else { return }
        selectedFileName = file
        let path = skill.path + "/" + file
        await loadSelectedFile(path: path)
    }

    public var isMarkdownFile: Bool {
        selectedFileName?.hasSuffix(".md") == true
    }

    private var currentFilePath: String? {
        guard let skill = selectedSkill, let file = selectedFileName else { return nil }
        return skill.path + "/" + file
    }

    /// Arms the editor. A file that was never read successfully cannot be
    /// edited at all — the empty buffer on screen is not its contents, and
    /// letting Save publish it is the bug GW-E2c closes.
    public func startEditing() {
        guard canEditSelectedFile else { return }
        editText = skillContent
        isEditing = true
    }

    public func saveEdit() async {
        guard let path = currentFilePath else { return }
        // Reentrancy guard: Save is a button, and a detached write over SSH
        // is long enough to double-tap through. A second run would race the
        // first one's proof-token refresh and could publish twice.
        guard !isSavingContent else { return }
        isSavingContent = true
        defer { isSavingContent = false }
        await saveSkillContent(path: path, content: editText)
        // A refused or failed save leaves `contentError` set. Keep the
        // editor open on the user's text rather than dismissing it and
        // showing a `skillContent` that no longer matches the file.
        guard contentError == nil else { return }
        skillContent = editText
        isEditing = false
    }

    public func cancelEditing() {
        isEditing = false
    }

    /// Deselect and blank the viewer. Goes through the view model rather
    /// than having the list set `skillContent` directly, so the proof token
    /// behind that text is dropped with it — a stale token plus a blanked
    /// buffer is the exact pair that must never be savable.
    public func clearSelection() {
        selectedSkill = nil
        selectedFileName = nil
        loadedContent = nil
        skillContent = ""
        contentError = nil
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
            let result = await Self.runHermes(executable: bin, args: args, transport: xport, timeout: 30)
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
        // `skills search`'s TABLE has no `#` column (unlike `skills
        // browse`), so `parseHubList` discarded every row it was ever fed
        // from this path — search results have been silently empty on every
        // host. `--json` (v0.17+) is both the fix and the only shape that
        // carries the full identifier; older hosts keep the table parse,
        // which is no worse than what they had.
        Task { [weak self] in
            // L1: the Hub can be searched before `load()`'s capability probe
            // has landed (a cold launch straight into the tab). Reading the
            // undetected snapshot here would drop `--json` and route a
            // perfectly capable host through the table parser, which returns
            // nothing. Resolve first — it is the same cached, shared probe.
            guard let caps = await self?.resolvedCapabilities() else { return }
            let useJSON = caps.hasSkillsSearchJSON
            await Task.detached { [weak self] in
                // The query is a USER string: `--` (argparse's end-of-options
                // marker, honoured by every Hermes version) keeps a query
                // that starts with `-` from being read as a flag and exiting
                // 2. It comes last — everything after it is positional.
                var args = ["skills", "search", "--limit", "40", "--source", source]
                if useJSON { args.append("--json") }
                args += ["--", query]
                let result = await Self.runHermesSplit(
                    executable: bin, args: args, transport: xport, timeout: 30)
                // The JSON array is read from STDOUT alone — a stderr
                // warning carrying a `]` would otherwise truncate the sliced
                // payload and drop the result set into the table fallback.
                // Fall back to the table parse when the JSON can't be read,
                // so a host that answers something unexpected degrades to
                // the old behaviour rather than to "no results".
                let combined = result.stdout + result.stderr
                let parsed = (useJSON ? HermesSkillsHubParser.parseSearchJSON(result.stdout) : nil)
                    ?? HermesSkillsHubParser.parseHubList(combined)
                await self?.finishBrowse(
                    results: parsed,
                    exitCode: result.exitCode,
                    rawOutput: combined,
                    isSearch: true
                )
            }.value
        }
    }

    /// This server's capability snapshot, probing once if `load()` has not
    /// already resolved it. Shared cache, so a warm app pays nothing.
    @MainActor
    private func resolvedCapabilities() async -> HermesCapabilities {
        if !capabilities.detected {
            capabilities = await HermesVersionCache.shared.capabilities(for: context)
        }
        return capabilities
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
            let result = await Self.runHermes(executable: bin, args: args, transport: xport, timeout: 30)
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
            let result = await Self.runHermes(
                executable: bin,
                args: Self.installArgs(identifier),
                transport: xport,
                timeout: 120
            )
            await self?.finishInstall(
                identifier: identifier,
                exitCode: result.exitCode,
                output: result.output
            )
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
            let args = Self.installArgs(
                url, category: categoryOverride, name: nameOverride)
            let result = await Self.runHermes(
                executable: bin,
                args: args,
                transport: xport,
                timeout: 180
            )
            await self?.finishInstall(
                identifier: url,
                exitCode: result.exitCode,
                output: result.output
            )
        }
    }

    /// Re-runs Hermes's **security scanner** over every hub-installed skill
    /// — `hermes skills audit`, whose `do_audit` scans each install path with
    /// `scan_skill` and prints the report (`hermes_cli/skills_hub.py:879-904`
    /// at v2026.9.7). It does NOT reload anything: the only reload Hermes has
    /// is the `/reload-skills` slash command inside a chat session
    /// (`gateway/slash_commands.py:1038-1048`), which has no CLI form, so a
    /// running gateway is untouched by this call.
    public func rescanSkills() async {
        isHubLoading = true
        let bin = context.paths.hermesBinary
        let xport = transport
        let result = await Task.detached {
            await Self.runHermes(
                executable: bin,
                args: ["skills", "audit"],
                transport: xport,
                timeout: 30
            )
        }.value
        // `do_audit` is `-> None` (hermes_cli/skills_hub.py:879-880) so its exit code is 0
        // even for the unknown-name refusal (:891). `Auditing <n> skill(s)...`
        // (:893) is the only line that says the scanner ran; the empty-hub
        // line (:887) is a legitimate no-op. Both byte-identical back to
        // v2026.6.19. The button re-runs the security scanner — the banner
        // says "re-scanned", never "reloaded".
        hubMessage = Self.auditOutcome(exitCode: result.exitCode, output: result.output).succeeded
            ? "Skills re-scanned"
            : "Re-scan failed"
        isHubLoading = false
        await load()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.hubMessage = nil
        }
    }

    /// `skills uninstall` gained `--yes` at v0.20.5
    /// (`HermesCapabilities.hasSkillsUninstallYes`). Below that floor the
    /// verb only confirms through an interactive `input("Confirm [y/N]: ")`
    /// that reads EOF as "n", so the caller pipes a `"y"` line instead —
    /// and argparse there exits 2 on the flag, which is why this is gated
    /// rather than always sent. `--` keeps a skill name starting with `-`
    /// from being read as a flag.
    nonisolated static func uninstallArgs(
        _ identifier: String, capabilities: HermesCapabilities = .empty
    ) -> [String] {
        var args = ["skills", "uninstall"]
        if capabilities.hasSkillsUninstallYes { args.append("--yes") }
        args += ["--", identifier]
        return args
    }

    /// The stdin to feed `uninstallArgs`. `nil` on a host that takes
    /// `--yes`: piping a stray "y" into a command that no longer prompts
    /// leaves it on the next reader's stdin.
    nonisolated static func uninstallStdin(capabilities: HermesCapabilities = .empty) -> String? {
        capabilities.hasSkillsUninstallYes ? nil : "y\n"
    }

    /// argv for `hermes skills install`.
    ///
    /// **Flags first, then `--`, then the positional.** The identifier is
    /// registry text Scarf does not control — a browse.sh slug, a GitHub
    /// `owner/skills/name` path, or a user-pasted URL — and argparse reads a
    /// leading `-` as a flag and exits 2 before `do_install` ever runs.
    /// `skills install` takes exactly one positional (`identifier`,
    /// `hermes_cli/subcommands/skills.py:54-63` at `v2026.9.7`), so
    /// everything after `--` is unambiguous.
    ///
    /// `--yes` (`add_yes_flag`, `:63`) skips the confirmation prompt Scarf
    /// has no TTY to answer; `--category` / `--name` are the direct-URL
    /// overrides (`:58-61`).
    nonisolated static func installArgs(
        _ identifier: String,
        category: String? = nil,
        name: String? = nil
    ) -> [String] {
        var args = ["skills", "install", "--yes"]
        if let category, !category.isEmpty { args += ["--category", category] }
        if let name, !name.isEmpty { args += ["--name", name] }
        args += ["--", identifier]
        return args
    }

    /// `skills update` has no `--yes` flag (argparse exits 2 if passed) and
    /// never prompts — `do_update` in hermes_cli/skills_hub.py runs straight
    /// through. Omitting the optional `name` positional updates all outdated
    /// skills.
    nonisolated static let updateAllArgs = ["skills", "update"]

    public func uninstallHubSkill(_ identifier: String) {
        let bin = context.paths.hermesBinary
        let xport = transport
        Task { [weak self] in
            guard let caps = await self?.resolvedCapabilities() else { return }
            await Task.detached { [weak self] in
                let result = await Self.runHermes(
                    executable: bin,
                    args: Self.uninstallArgs(identifier, capabilities: caps),
                    transport: xport,
                    timeout: 60,
                    stdin: Self.uninstallStdin(capabilities: caps)
                )
                await self?.finishUninstall(exitCode: result.exitCode, output: result.output)
            }.value
        }
    }

    /// `skills uninstall` exits 0 whether or not it removed anything —
    /// "Error: 'x' is not a hub-installed skill" comes back with exit 0
    /// (verified at v0.21.0) — so the exit code alone cannot be the
    /// verdict (charter C5). A rejection is an `Error:` line in the output.
    /// `do_uninstall` (hermes_cli/skills_hub.py:909-918) is also `-> None`: a declined
    /// confirmation returns silently, and `_report_pair` (:144-150) prints
    /// `Error: …` for a refusal — both at exit 0. Success is the green
    /// `Uninstalled '<name>' from <path>` line
    /// (tools/skills_hub_install.py:220).
    nonisolated static func uninstallOutcome(exitCode: Int32, output: String) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.skillsUninstallSuccess,
            failureMarkers: HermesCLIMarkers.skillsUninstallFailure,
            // `_report_pair` prints it at column 0 (hermes_cli/skills_hub.py:146).
            successAnchored: true
        )
    }

    nonisolated static func uninstallSucceeded(exitCode: Int32, output: String) -> Bool {
        uninstallOutcome(exitCode: exitCode, output: output).succeeded
    }

    /// The CLI's own one-line reason for a refused uninstall, for the banner.
    nonisolated static func uninstallFailureReason(output: String) -> String? {
        uninstallOutcome(exitCode: 0, output: output).detail
    }

    public func checkForUpdates() {
        isHubLoading = true
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            let result = await Self.runHermes(
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
    /// **Flags first, then `--`, then the positional** — the same shape as
    /// `installArgs`/`uninstallArgs`. `--force` must come BEFORE the `--`:
    /// argparse treats everything after the first `--` as positional, so
    /// `skills update -- <name> --force` exits 2 with
    /// `unrecognized arguments: --force`. `skills update` takes exactly one
    /// optional positional (`name`, `nargs="?"`) plus `--force`
    /// (`hermes_cli/subcommands/skills.py:79-83` @ `v2026.9.7`), so
    /// everything after `--` is unambiguous.
    nonisolated static func forceUpdateArgs(_ name: String) -> [String] {
        ["skills", "update", "--force", "--", name]
    }

    public func updateAll() {
        let bin = context.paths.hermesBinary
        let xport = transport
        Task.detached { [weak self] in
            let result = await Self.runHermes(
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
            let result = await Self.runHermes(
                executable: bin,
                args: Self.forceUpdateArgs(name),
                transport: xport,
                timeout: 300
            )
            let report = HermesSkillsHubParser.parseUpdateReport(result.output)
            await self?.finishForceUpdate(
                name: name,
                exitCode: result.exitCode,
                report: report
            )
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

    /// The verdict on `hermes skills audit` — see `rescanSkills()`.
    nonisolated static func auditOutcome(exitCode: Int32, output: String) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.skillsAuditSuccess,
            failureMarkers: HermesCLIMarkers.skillsAuditFailure,
            // Both lines are printed at column 0 (hermes_cli/skills_hub.py:887, :893),
            // and the per-skill scan reports that follow can quote anything.
            successAnchored: true
        )
    }

    /// `hermes skills install` is `do_install(...) -> None`
    /// (hermes_cli/skills_hub.py:645-648 at v2026.9.7): a pinned-source
    /// refusal, an unresolved short name, a fetch failure, an
    /// already-installed skill, an invalid path, a blocked security scan and a
    /// declined confirmation all `print()` and `return`, which Python exits 0.
    /// Every one of those rendered as "Installed <x>" until this judged the
    /// emitter's output instead (charter C5).
    nonisolated static func installOutcome(exitCode: Int32, output: String) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.skillsInstallSuccess,
            failureMarkers: HermesCLIMarkers.skillsInstallFailure,
            // `Installed:` is printed at column 0 (hermes_cli/skills_hub.py:720), and
            // anchoring matters most here: `_print_tier1_advisory` (:704)
            // quotes SKILL.md-derived findings into the report BEFORE
            // `install_from_quarantine` can raise (:714-720), so a bare
            // substring let a skill's own text claim the install succeeded.
            successAnchored: true
        )
    }

    /// Three branches, not two (the ``HermesMemoryResetVerdict/failureSummary``
    /// shape, round-6 P54b/P59). `.unconfirmed` is gated on the CONFIDENCE
    /// ALONE — never on whether there is a line to quote. A two-way `if`
    /// reaches the honest sentence only when the output was EMPTY, so an
    /// exit-0 run that printed something the verdict does not recognise had
    /// its unrelated tail line rendered as the install's refusal: a sentence
    /// Hermes never said, presented as its reason.
    nonisolated static func installFailureSummary(outcome: HermesCLIOutcome) -> String {
        if outcome.confidence == .unconfirmed {
            let verb = "hermes skills install"
            return String(localized: "\(verb) printed no result. Check the host.")
        }
        if let detail = outcome.detail, !detail.isEmpty { return "Install failed — \(detail)" }
        return "Install failed"
    }

    /// Three branches, not two (the ``HermesMemoryResetVerdict/failureSummary``
    /// shape, round-6 P54b/P59). `.unconfirmed` is gated on the CONFIDENCE
    /// ALONE — never on whether there is a line to quote. A two-way `if`
    /// reaches the honest sentence only when the output was EMPTY, so an
    /// exit-0 run that printed something the verdict does not recognise had
    /// its unrelated tail line rendered as the uninstall's refusal: a sentence
    /// Hermes never said, presented as its reason.
    ///
    /// The exit code is NOT quoted on the unconfirmed arm: the verdict
    /// reaches `.unconfirmed` only at exit 0, so "(exit 0)" was a number that
    /// the verdict had already declared meaningless, printed beside a claim
    /// of failure.
    nonisolated static func uninstallFailureSummary(
        outcome: HermesCLIOutcome,
        exitCode: Int32
    ) -> String {
        if outcome.confidence == .unconfirmed {
            let verb = "hermes skills uninstall"
            return String(localized: "\(verb) printed no result. Check the host.")
        }
        if let detail = outcome.detail, !detail.isEmpty { return "Uninstall failed — \(detail)" }
        return "Uninstall failed (exit \(exitCode))"
    }

    @MainActor
    private func finishInstall(identifier: String, exitCode: Int32, output: String) async {
        isHubLoading = false
        let outcome = Self.installOutcome(exitCode: exitCode, output: output)
        if outcome.succeeded {
            hubMessage = "Installed \(identifier)"
        } else {
            hubMessage = Self.installFailureSummary(outcome: outcome)
        }
        await load()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hubMessage = nil
    }

    @MainActor
    private func finishUninstall(exitCode: Int32, output: String) async {
        let outcome = Self.uninstallOutcome(exitCode: exitCode, output: output)
        if outcome.succeeded {
            hubMessage = "Uninstalled"
        } else {
            hubMessage = Self.uninstallFailureSummary(outcome: outcome, exitCode: exitCode)
        }
        await load()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        hubMessage = nil
    }

    @MainActor
    private func finishCheckForUpdates(updates rows: [HermesSkillUpdate]) async {
        isHubLoading = false
        self.updates = rows.filter { $0.status.isActionable }
        self.updateFaults = rows.filter { $0.status.faultDescription != nil }
        hubMessage = updates.isEmpty ? "No updates available" : "\(updates.count) update(s)"
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hubMessage = nil
    }

    /// `hermes skills update` is `do_update(...) -> None`
    /// (hermes_cli/skills_hub.py:831-832 at v2026.9.7), so the exit code is 0
    /// whatever happened (charter C5) — and its own summary line is no better:
    /// `Updated {len(updates) - len(skipped_local)} skill(s).` (:872) is
    /// printed after the loop regardless of what each nested `do_install`
    /// did, so it counts ATTEMPTS.
    ///
    /// The honest per-skill signal is `do_install`'s own `Installed:` line
    /// (:720), printed only once `install_from_quarantine` has returned. So:
    /// `Installed:` lines are successes, `Updating:` lines (:864) are
    /// attempts, and an attempt with no matching success says "attempted",
    /// never "updated". All three lines are byte-identical back to
    /// v2026.6.19, so a pre-target host is judged the same way (C1).
    @MainActor
    private func finishUpdateAll(exitCode: Int32, report: HermesSkillsUpdateReport) async {
        skippedLocalEdits = exitCode == 0 ? report.skipped : []
        let keptClause = report.skipped.isEmpty
            ? ""
            : " · \(report.skipped.count) kept local edits"
        if exitCode != 0 {
            hubMessage = "Update failed"
        } else if report.noUpdatesAvailable {
            hubMessage = "No updates available"
        } else if report.installedCount > 0 {
            hubMessage = report.skipped.isEmpty && report.installedCount == report.attemptedCount
                ? "Updated"
                : "Updated \(report.installedCount)\(keptClause)"
        } else if report.attemptedCount > 0 {
            // Every skill it tried failed inside `do_install` — which prints
            // its refusal and returns, leaving `Updated N skill(s).` to claim
            // the opposite.
            hubMessage = report.failureDetail.map { "Update attempted — \($0)" }
                ?? "Update attempted; nothing was updated"
        } else if !report.skipped.isEmpty {
            // Everything actionable had local edits.
            hubMessage = "0 updated · \(report.skipped.count) kept local edits"
        } else {
            // Exit 0 with none of `do_update`'s lines: not a success (C5).
            hubMessage = "Update reported nothing"
        }
        await load()
        checkForUpdates()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hubMessage = nil
    }

    /// Verdict for `skills update <name> --force`, read from the OUTPUT and
    /// not from the exit code — exactly as `finishUpdateAll` does.
    ///
    /// `do_update` is `-> None` (`hermes_cli/skills_hub.py:831-832`) and so is
    /// the `do_install(force=True)` it nests (`:868`), so a refusal is printed
    /// and returned from at exit 0: a blocked scan verdict reaches
    /// `_install_blocked` and prints `Installation blocked: …` (`:699`, printed at
    /// `:498`), and an invalid bundle path reaches `_invalid_path` (`:692`). Judging this by
    /// exit code made the ONE action that destroys the user's local edits
    /// announce that it had succeeded when nothing was written (C5).
    ///
    /// The skill only leaves `skippedLocalEdits` when `Installed:` — the one
    /// honest success line — actually appeared for it, so the "kept your local
    /// edits" badge survives a force update that did not land.
    /// The verdict itself, as a pure function so it can be driven from a test
    /// with a real `do_update` transcript — the exit-code version shipped
    /// green because nothing could exercise it.
    ///
    /// - Returns: the status line to show, and whether the skill's local-edits
    ///   badge may be cleared (only when it really was rewritten, or when
    ///   there was nothing to rewrite).
    public static func forceUpdateVerdict(
        name: String,
        exitCode: Int32,
        report: HermesSkillsUpdateReport
    ) -> (message: String, clearSkipped: Bool) {
        if exitCode != 0 {
            return (report.failureDetail.map { "Update failed for \(name) — \($0)" }
                ?? "Update failed for \(name)", false)
        }
        if report.installedCount > 0 {
            return ("Updated \(name) (local edits discarded)", true)
        }
        if report.noUpdatesAvailable {
            // `--force` discards local edits; it does not invent a new
            // revision. Nothing to do is a truthful, non-destructive answer —
            // and the skill is no longer "kept back", it is simply current.
            return ("No updates available for \(name)", true)
        }
        if report.attemptedCount > 0 {
            return (report.failureDetail.map { "Update attempted — \($0)" }
                ?? "Update attempted; \(name) was not updated", false)
        }
        // Exit 0 with none of `do_update`'s lines: not a success (C5).
        return ("Update reported nothing for \(name)", false)
    }

    @MainActor
    private func finishForceUpdate(
        name: String,
        exitCode: Int32,
        report: HermesSkillsUpdateReport
    ) async {
        isHubLoading = false
        let verdict = Self.forceUpdateVerdict(name: name, exitCode: exitCode, report: report)
        hubMessage = verdict.message
        if verdict.clearSkipped {
            skippedLocalEdits.removeAll { $0 == name }
        }
        await load()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hubMessage = nil
    }

    // MARK: - Transport helpers

    /// Split-stream CLI runner. Use this for any answer that is parsed as
    /// JSON: the combined runner below concatenates stderr onto stdout, and
    /// one warning line containing a `]` is enough for a "first `[` … last
    /// `]`" slice to cut the payload short.
    nonisolated static func runHermesSplit(
        executable: String,
        args: [String],
        transport: any ServerTransport,
        timeout: TimeInterval,
        stdin: String? = nil
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        do {
            // Round-6 decision 11: the `async` seam (charter C10).
            let result = try await transport.asyncRunProcess(
                executable: executable,
                args: args,
                stdin: stdin.flatMap { $0.data(using: .utf8) },
                timeout: timeout
            )
            return (result.exitCode, result.stdoutString, result.stderrString)
        } catch let error as TransportError {
            return (-1, "", error.diagnosticStderr.isEmpty
                ? (error.errorDescription ?? "transport error")
                : error.diagnosticStderr)
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }

    /// Combined stdout+stderr CLI runner. Mirrors the legacy
    /// `HermesFileService.runHermesCLI` shape so callers grepping
    /// through `output` keep working.
    nonisolated private static func runHermes(
        executable: String,
        args: [String],
        transport: any ServerTransport,
        timeout: TimeInterval,
        stdin: String? = nil
    ) async -> (exitCode: Int32, output: String) {
        do {
            // Round-6 decision 11: the `async` seam (charter C10).
            let result = try await transport.asyncRunProcess(
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

    /// The load that arms (or disarms) the editor.
    ///
    /// **Guarded (GW-E2c).** This used to return `""` for every failure —
    /// an unreadable file, a dropped SSH round-trip, a non-UTF-8 byte — and
    /// the editor happily armed Save over that empty buffer, publishing an
    /// empty file over a skill whose text exists nowhere else. The fix is
    /// not a check inside the writer: it is making the unsavable state
    /// unrepresentable. A failed load now leaves `loadedContent` NIL, and
    /// `saveSkillContent` has no path that can write without one.
    /// `nonisolated static` so the detached hop below can call it without
    /// capturing `self` (the view model is `@Observable`, not `Sendable`).
    nonisolated private static func loadSkillContent(
        path: String, transport: any ServerTransport, logger: Logger
    ) -> GuardedTextFile.Loaded? {
        do {
            return try GuardedTextFile(transport: transport, label: "SKILL.md")
                .load(path, maxBytes: Self.maxSkillFileBytes)
        } catch {
            logger.error("loadSkillContent(\(path, privacy: .public)) refused: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Load the selected file's contents OFF the main actor (GW-F6 / audit
    /// PERF H1) and apply the result back on it.
    ///
    /// This was a synchronous `applyLoad(loadSkillContent(...))` in a
    /// SwiftUI row-selection action — over SSH, up to four
    /// timeout-bounded spawns (`cat`, then the proof probe's `stat` +
    /// retry) on the main thread, i.e. minutes of beachball against a dead
    /// remote (charter C10). `KanbanToolsetEnabler.applyPlan` is the in-repo
    /// shape being copied: ONE `Task.detached` around the whole guarded
    /// read, `await`ed, with every piece of `@Observable` state written
    /// back here on the main actor.
    ///
    /// **Last-selection-wins.** A user clicking down a skill list starts one
    /// of these per row, and they can finish out of order. `contentToken`
    /// stamps each attempt; a result whose stamp is no longer current is
    /// dropped rather than painting a stale file's text under the current
    /// file's name.
    private func loadSelectedFile(path: String) async {
        contentToken &+= 1
        let token = contentToken
        isLoadingContent = true
        // Blank the previous file's text immediately: the row selection has
        // already changed, and leaving the last skill's contents on screen
        // under the new skill's name is a worse lie than an empty viewer.
        // The proof token goes with it, so Save is impossible until this
        // load lands (the GW-E2c invariant, unchanged).
        loadedContent = nil
        skillContent = ""
        contentError = nil
        let transport = self.transport
        let logger = self.logger
        // Containment is a pure string check on already-held state; keeping
        // it on this side means the detached hop is exactly the I/O.
        let contained = isValidSkillPath(path)
        let loaded = await Task.detached(priority: .userInitiated) { () -> GuardedTextFile.Loaded? in
            guard contained else { return nil }
            return Self.loadSkillContent(path: path, transport: transport, logger: logger)
        }.value
        guard token == contentToken else { return }
        isLoadingContent = false
        applyLoad(loaded, path: path)
    }

    /// Apply a load to the editor's state. A refused load blanks the
    /// viewer, records the reason, and drops the proof token — which is
    /// exactly what makes Save impossible until a successful load replaces
    /// it.
    private func applyLoad(_ loaded: GuardedTextFile.Loaded?, path: String) {
        loadedContent = loaded
        skillContent = loaded?.text ?? ""
        if loaded == nil {
            contentError = "\(path) couldn't be read. Editing is disabled so an empty file can't be saved over it."
        } else {
            contentError = nil
        }
    }

    /// Publish the editor buffer OFF the main actor (GW-F6 / audit PERF H1),
    /// same shape and same reasoning as ``loadSelectedFile(path:)`` — the
    /// guarded write is up to two transport writes (`.bak`, then the file),
    /// which over SSH is two spawns this used to take on the main thread.
    ///
    /// The proof token, the refusal messages and the byte content are all
    /// unchanged; only where the I/O runs moved. Nothing between the check
    /// and the write can be reordered by the hop: `loaded` is captured
    /// before it, and `SKILL.md` is a per-skill file with a single
    /// user-driven writer, which is why `GuardedTextFile` gives it no lock
    /// (see that type's `lockContext`).
    private func saveSkillContent(path: String, content: String) async {
        // A bare `return` here was a SILENT SUCCESS (GW-F2, audit DI M11):
        // `saveEdit` reads `contentError == nil` as "it saved", so a path
        // rejected by containment closed the editor and dropped the user's
        // edits with a confirmation. The rejection now surfaces through the
        // same channel every other refusal uses.
        guard isValidSkillPath(path) else {
            contentError = "Not saved — \(path) is outside the skills directory."
            return
        }
        // No proof token ⇒ the buffer on screen was never the file's real
        // contents ⇒ there is nothing legitimate to save.
        guard let loaded = loadedContent else {
            logger.error("saveSkillContent(\(path, privacy: .public)) refused: no successful load backs this buffer")
            contentError = "Not saved — \(path) was never read successfully."
            return
        }
        let transport = self.transport
        let failure = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try GuardedTextFile(transport: transport, label: "SKILL.md")
                    .write(content, to: path, after: loaded)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure {
            logger.error("saveSkillContent(\(path, privacy: .public)) failed: \(failure, privacy: .public)")
            contentError = "Couldn't save \(path): \(failure)"
            return
        }
        // The token now describes what is actually on disk, so a second
        // save in the same sitting backs up the version it replaces
        // rather than the one two saves ago.
        loadedContent = GuardedTextFile.Loaded(
            text: content,
            exists: true,
            inspection: GuardedJSONStore.Inspection(
                state: .present, bytes: Data(content.utf8)
            )
        )
        contentError = nil
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
