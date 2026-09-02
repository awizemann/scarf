import Foundation
import ScarfCore
import os

// MARK: - Backend seam

/// Everything the per-bot Agent surface needs from the host, behind one
/// protocol — the same seam shape `BotsBackend` uses, and for the same
/// reason: the view model's pin/clear round-trip, origin rendering,
/// dirty-buffer discipline and toggle-failure recovery are all testable
/// without a Hermes home, an SSH transport or a `hermes` binary.
///
/// Every method is a thin forward to P1's `BotAgentConfigService` (P0). No
/// argv, no key names and no capability gate is re-derived here.
protocol BotAgentBackend: Sendable {
    var canWriteSkillEnablement: Bool { get }
    func soulPath(forProfile name: String) -> String
    func readAgentConfig(forProfile name: String) throws -> BotAgentConfig
    func listToolsets(forProfile name: String, platform: String) throws -> ProcessResult
    func readSoul(forProfile name: String) throws -> String?
    func writeSoul(forProfile name: String, content: String) throws
    func setModelPin(forProfile name: String, provider: String?, model: String?) throws -> [ProcessResult]
    func clearModelPin(forProfile name: String) throws -> [ProcessResult]
    func setToolsetEnabled(forProfile name: String, toolset: String, platform: String, enabled: Bool) throws -> ProcessResult
    func setMCPServerEnabled(forProfile name: String, server: String, enabled: Bool) throws -> ProcessResult
}

/// `BotAgentBackend` over a real host.
struct LiveBotAgentBackend: BotAgentBackend {
    private let service: BotAgentConfigService

    init(context: ServerContext, capabilities: HermesCapabilities) {
        self.service = BotAgentConfigService(context: context, capabilities: capabilities)
    }

    var canWriteSkillEnablement: Bool { service.canWriteSkillEnablement }
    func soulPath(forProfile name: String) -> String { service.soulPath(forProfile: name) }
    func readAgentConfig(forProfile name: String) throws -> BotAgentConfig {
        try service.readAgentConfig(forProfile: name)
    }
    func listToolsets(forProfile name: String, platform: String) throws -> ProcessResult {
        try service.run(forProfile: name, args: ["tools", "list", "--platform", platform])
    }
    func readSoul(forProfile name: String) throws -> String? { try service.readSoul(forProfile: name) }
    func writeSoul(forProfile name: String, content: String) throws {
        try service.writeSoul(forProfile: name, content: content)
    }
    func setModelPin(forProfile name: String, provider: String?, model: String?) throws -> [ProcessResult] {
        try service.setModelPin(forProfile: name, provider: provider, model: model)
    }
    func clearModelPin(forProfile name: String) throws -> [ProcessResult] {
        try service.clearModelPin(forProfile: name)
    }
    func setToolsetEnabled(forProfile name: String, toolset: String, platform: String, enabled: Bool) throws -> ProcessResult {
        try service.setToolsetEnabled(forProfile: name, toolset: toolset, platform: platform, enabled: enabled)
    }
    func setMCPServerEnabled(forProfile name: String, server: String, enabled: Bool) throws -> ProcessResult {
        try service.setMCPServerEnabled(forProfile: name, server: server, enabled: enabled)
    }
}

// MARK: - Snapshot

/// One consistent read of everything the Agent area renders. Built off the
/// MainActor in a single hop so the pane can never paint a model pin from one
/// read next to toolsets from another.
struct BotAgentSnapshot: Sendable {
    var config: BotAgentConfig
    var toolsets: [HermesToolset]
    /// Verbatim CLI text when `tools list` failed. The list is then empty and
    /// the pane says so rather than rendering "no toolsets".
    var toolsetsError: String?
    /// `nil` = the file does not exist (normal, and NOT the same as empty).
    var soul: String?
    /// The file exists but could not be turned into an editable buffer.
    /// Saving is refused in this state — see `BotAgentConfigService.readSoul`.
    var soulUnreadable: Bool
}

// MARK: - View model

/// The `agent` slot's view model: one bot's model pin, `SOUL.md`, skills,
/// toolsets and MCP servers.
///
/// Two invariants worth stating up front, both of which the tests pin:
///
/// 1. **A write always wins over an in-flight read.** Every mutation bumps
///    `generation` before it starts, and a load applies its result only if the
///    generation it captured is still current. Without that, a snapshot read
///    issued just before a pin write lands *after* it and repaints the old
///    origin — the classic "I pinned it and it flipped back" bug.
/// 2. **A reload never clobbers a dirty `SOUL.md` buffer.** The user's
///    unsaved text is the one piece of state on this surface that exists
///    nowhere else; re-reading the file over it would destroy work that has
///    no other copy. The buffer (and its merge base) are left untouched while
///    dirty, and the save path re-reads to detect an external edit.
@Observable
@MainActor
final class BotAgentViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "BotAgentViewModel")

    let profileName: String
    @ObservationIgnored private let injectedBackend: (any BotAgentBackend)?
    @ObservationIgnored private var backend: any BotAgentBackend
    @ObservationIgnored private let context: ServerContext?

    /// The platform the toolset toggles act on. Only `cli` is offered: the
    /// other platforms are gateway surfaces whose per-bot enablement Scarf
    /// has no verified read for, and a bot is a CLI/ACP agent.
    static let toolsetPlatform = "cli"

    /// Mirrored from the environment capability store by the view (the same
    /// async-probe race `BotsView` already handles). Rebuilds the live
    /// backend because P0's writers refuse below the Bot Mode floor.
    var capabilities: HermesCapabilities {
        didSet {
            guard injectedBackend == nil, capabilities != oldValue, let context else { return }
            backend = LiveBotAgentBackend(context: context, capabilities: capabilities)
        }
    }

    init(
        context: ServerContext = .local,
        profileName: String,
        capabilities: HermesCapabilities = .empty,
        backend: (any BotAgentBackend)? = nil
    ) {
        self.profileName = profileName
        self.capabilities = capabilities
        self.injectedBackend = backend
        self.context = backend == nil ? context : nil
        self.backend = backend ?? LiveBotAgentBackend(context: context, capabilities: capabilities)
    }

    // MARK: State

    private(set) var config: BotAgentConfig?
    private(set) var toolsets: [HermesToolset] = []
    private(set) var toolsetsError: String?
    private(set) var isLoading = false
    /// Verbatim failure text for a whole-pane failure. Hermes' own refusals
    /// ("Config key not set", "Unknown toolset 'x'") carry the remedy, so they
    /// are shown as-is rather than paraphrased.
    var errorMessage: String?

    private(set) var isPinBusy = false
    private(set) var busyToolsets: Set<String> = []
    private(set) var busyMCPServers: Set<String> = []
    /// Per-row verbatim failure, keyed by toolset / server name.
    private(set) var rowErrors: [String: String] = [:]

    // SOUL.md
    /// The editor buffer. Bound directly by the view.
    var soulText: String = ""
    /// What was on disk when the buffer was last loaded or saved — the merge
    /// base a save is checked against.
    private(set) var soulBaseline: String = ""
    private(set) var soulExists = false
    private(set) var soulUnreadable = false
    private(set) var isSavingSoul = false
    private(set) var soulError: String?
    /// Set when a save found the file changed underneath the buffer. Until the
    /// user resolves it, the save button is replaced by an explicit choice.
    private(set) var soulConflict = false
    private(set) var hasLoadedSoul = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasLoaded = false

    // MARK: Derived

    var hasBotMode: Bool { capabilities.hasBotMode }
    var canWriteSkillEnablement: Bool { backend.canWriteSkillEnablement }
    var soulPath: String { backend.soulPath(forProfile: profileName) }

    /// `true` while the buffer differs from what is on disk. Drives the save
    /// affordance and the navigation guard.
    var isSoulDirty: Bool { hasLoadedSoul && soulText != soulBaseline }

    /// UTF-8 length of the buffer, against P0's ceiling.
    var soulByteCount: Int { soulText.utf8.count }
    var soulByteLimit: Int { BotAgentConfigService.maxSoulBytes }
    var soulOverLimit: Bool { soulByteCount > soulByteLimit }

    /// Whether the buffer may be saved at all. An unreadable file is never
    /// savable — that is P0's refuse-degraded-merge-base rule reaching the UI.
    var canSaveSoul: Bool {
        hasBotMode && hasLoadedSoul && !soulUnreadable && !soulOverLimit && !isSavingSoul && isSoulDirty
    }

    /// How the model pin should be presented. `unreadable` is a distinct case
    /// on purpose: an existing `config.yaml` Scarf could not parse produces
    /// the same all-nil snapshot as an absent one, and calling that "Hermes
    /// default" would tell the user their bot runs on defaults when it may be
    /// pinned to anything (`BotAgentConfig.configReadable`).
    enum ModelPinState: Equatable {
        case unknown
        case unreadable(path: String)
        case pinned(model: String?, provider: String?)
        case hermesDefault
    }

    var modelPinState: ModelPinState { Self.modelPinState(config) }

    static func modelPinState(_ config: BotAgentConfig?) -> ModelPinState {
        guard let config else { return .unknown }
        guard config.isTrustworthy else { return .unreadable(path: config.configPath) }
        guard config.model.isPinned || config.provider.isPinned else { return .hermesDefault }
        return .pinned(model: config.model.pinned, provider: config.provider.pinned)
    }

    /// One line for the pin row. Never says "Hermes default" for a snapshot
    /// Scarf could not read.
    static func modelSummary(_ config: BotAgentConfig?) -> String {
        switch modelPinState(config) {
        case .unknown:
            return "Reading this bot's configuration…"
        case .unreadable(let path):
            return "Couldn't read \(path) — this bot's model can't be shown."
        case .hermesDefault:
            return "Hermes default"
        case .pinned(let model, let provider):
            switch (model, provider) {
            case let (model?, provider?): return "Pinned: \(provider)/\(model)"
            case let (model?, nil):       return "Pinned: \(model)"
            case let (nil, provider?):    return "Pinned: \(provider) (model left to Hermes)"
            case (nil, nil):              return "Hermes default"
            }
        }
    }

    var modelSummary: String { Self.modelSummary(config) }

    /// Writes are refused while the snapshot can't be trusted: they would be
    /// issued blind against a file Scarf never read.
    var canEditConfig: Bool { hasBotMode && (config?.isTrustworthy ?? false) }

    var isPinned: Bool {
        if case .pinned = modelPinState { return true }
        return false
    }

    /// Skills the bot has switched OFF, sorted for a stable list. `hermes-agent`
    /// is already dropped by P0 on hosts where Hermes ignores it (W3).
    var disabledSkills: [String] { (config?.disabledSkills).map { $0.sorted() } ?? [] }

    var mcpServers: [BotMCPServerState] { config?.mcpServers ?? [] }

    // MARK: - Loading

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        load()
    }

    func load(force: Bool = false) {
        guard hasBotMode else { return }
        guard !isLoading || force else { return }
        hasLoaded = true
        isLoading = true
        generation += 1
        let token = generation
        let backend = self.backend
        let name = profileName
        Task { [weak self] in
            let outcome: Result<BotAgentSnapshot, Error> = await Task.detached {
                do { return .success(try Self.snapshot(backend: backend, profile: name)) }
                catch { return .failure(error) }
            }.value
            guard let self else { return }
            // A write issued while this read was in flight already bumped the
            // generation; its own reload is the authoritative one.
            guard token == self.generation else { return }
            self.isLoading = false
            switch outcome {
            case .success(let snapshot):
                self.apply(snapshot)
            case .failure(let error):
                self.errorMessage = Self.describe(error)
            }
        }
    }

    nonisolated static func snapshot(backend: any BotAgentBackend, profile: String) throws -> BotAgentSnapshot {
        let config = try backend.readAgentConfig(forProfile: profile)
        var toolsets: [HermesToolset] = []
        var toolsetsError: String?
        do {
            let result = try backend.listToolsets(forProfile: profile, platform: toolsetPlatform)
            if result.exitCode == 0 {
                toolsets = HermesToolsList.parse(result.stdoutString)
            } else {
                toolsetsError = failureText(result)
            }
        } catch {
            toolsetsError = describe(error)
        }
        var soul: String?
        var soulUnreadable = false
        do { soul = try backend.readSoul(forProfile: profile) }
        catch { soulUnreadable = true }
        return BotAgentSnapshot(
            config: config,
            toolsets: toolsets,
            toolsetsError: toolsetsError,
            soul: soul,
            soulUnreadable: soulUnreadable
        )
    }

    private func apply(_ snapshot: BotAgentSnapshot) {
        config = snapshot.config
        toolsets = snapshot.toolsets
        toolsetsError = snapshot.toolsetsError
        soulExists = snapshot.soul != nil
        soulUnreadable = snapshot.soulUnreadable
        // INVARIANT 2: never overwrite unsaved work. The buffer stays, and so
        // does its merge base — `saveSoul` re-reads and reports the conflict
        // rather than this load silently rebasing onto someone else's edit.
        guard !isSoulDirty else { return }
        soulBaseline = snapshot.soul ?? ""
        soulText = soulBaseline
        hasLoadedSoul = true
        soulConflict = false
        soulError = snapshot.soulUnreadable
            ? "Couldn't read \(soulPath). It may be too large, or not text. Editing is disabled so a save can't replace it with an empty file."
            : nil
    }

    // MARK: - Model pin

    /// Pin from the shared `ModelPickerSheet` selection.
    func setModelPin(model: String, provider: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        // The picker can legitimately return an empty model (a subscription
        // overlay letting Hermes choose). Pass nil rather than "" — P0 refuses
        // empty values because `config set k ""` pins an empty string, which
        // is not the same as leaving the key unset.
        perform(pin: true) { backend, name in
            try backend.setModelPin(
                forProfile: name,
                provider: provider.isEmpty ? nil : provider,
                model: model.isEmpty ? nil : model
            )
        }
    }

    /// Drop both model keys — back to **Hermes' built-in default**, not to the
    /// root profile's model, which this bot never inherited.
    func clearModelPin() {
        perform(pin: true) { backend, name in
            // `config unset` exits non-zero with "Config key not set" for a
            // key that was never pinned, which is a success here — P0 returns
            // those rather than throwing, and the reload below is the truth.
            let results = try backend.clearModelPin(forProfile: name)
            return results.filter { !Self.isBenignUnset($0) }
        }
    }

    /// `hermes config unset` on an unpinned key. Not a failure to report.
    nonisolated static func isBenignUnset(_ result: ProcessResult) -> Bool {
        guard result.exitCode != 0 else { return true }
        let text = (result.stderrString + result.stdoutString).lowercased()
        return text.contains("not set")
    }

    private func perform(
        pin: Bool,
        _ work: @escaping @Sendable (any BotAgentBackend, String) throws -> [ProcessResult]
    ) {
        guard canEditConfig, !isPinBusy else { return }
        isPinBusy = true
        errorMessage = nil
        // INVARIANT 1: invalidate any read already in flight before writing.
        generation += 1
        let backend = self.backend
        let name = profileName
        Task { [weak self] in
            let message: String? = await Task.detached {
                do {
                    let results = try work(backend, name)
                    if let bad = results.first(where: { $0.exitCode != 0 }) {
                        return Self.failureText(bad)
                    }
                    return nil
                } catch {
                    return Self.describe(error)
                }
            }.value
            guard let self else { return }
            self.isPinBusy = false
            self.errorMessage = message
            // Re-read regardless of outcome: a partial pin (provider written,
            // model refused) must show what actually landed.
            self.load(force: true)
        }
    }

    // MARK: - Toolsets

    func setToolset(_ toolset: HermesToolset, enabled: Bool) {
        let name = toolset.name
        guard canEditConfig, !busyToolsets.contains(name) else { return }
        busyToolsets.insert(name)
        rowErrors[name] = nil
        // Optimistic flip, mirroring the root Tools screen — reverted below on
        // failure so a refused toggle never leaves the row lying.
        if let idx = toolsets.firstIndex(where: { $0.name == name }) {
            toolsets[idx].enabled = enabled
        }
        generation += 1
        let backend = self.backend
        let profile = profileName
        Task { [weak self] in
            let message: String? = await Task.detached {
                do {
                    let result = try backend.setToolsetEnabled(
                        forProfile: profile,
                        toolset: name,
                        platform: Self.toolsetPlatform,
                        enabled: enabled
                    )
                    return result.exitCode == 0 ? nil : Self.failureText(result)
                } catch {
                    return Self.describe(error)
                }
            }.value
            guard let self else { return }
            self.busyToolsets.remove(name)
            if let message {
                self.rowErrors[name] = message
                if let idx = self.toolsets.firstIndex(where: { $0.name == name }) {
                    self.toolsets[idx].enabled = !enabled
                }
            }
            self.load(force: true)
        }
    }

    // MARK: - MCP

    func setMCPServer(_ server: BotMCPServerState, enabled: Bool) {
        let name = server.name
        guard canEditConfig, !busyMCPServers.contains(name) else { return }
        busyMCPServers.insert(name)
        rowErrors[name] = nil
        generation += 1
        let backend = self.backend
        let profile = profileName
        Task { [weak self] in
            let message: String? = await Task.detached {
                do {
                    let result = try backend.setMCPServerEnabled(forProfile: profile, server: name, enabled: enabled)
                    return result.exitCode == 0 ? nil : Self.failureText(result)
                } catch {
                    return Self.describe(error)
                }
            }.value
            guard let self else { return }
            self.busyMCPServers.remove(name)
            self.rowErrors[name] = message
            // No optimistic flip here: the row's truth is the parsed
            // `enabled:` key (absent ⇒ enabled), which only a re-read knows.
            self.load(force: true)
        }
    }

    // MARK: - SOUL.md

    func revertSoul() {
        soulText = soulBaseline
        soulError = nil
        soulConflict = false
    }

    /// Save the buffer, refusing if the file changed on disk since it was
    /// loaded.
    ///
    /// P0's `writeSoul` re-checks that the file is *readable* immediately
    /// before replacing it, but it cannot know what the editor's merge base
    /// was — a whole-file write of a stale buffer would silently drop an edit
    /// made in a terminal (or by the agent itself) while the pane was open.
    /// That check has to live here, where the baseline is.
    func saveSoul(force: Bool = false) {
        guard force || canSaveSoul else { return }
        // `force` skips the conflict re-read, never the safety floor: an
        // unreadable file must not be replaced, and an oversized buffer would
        // be refused by P0's writer anyway (over-limit AND conflicted is a
        // reachable pair, so the Overwrite button has to honour both).
        guard !soulUnreadable, !soulOverLimit, !isSavingSoul else { return }
        isSavingSoul = true
        soulError = nil
        generation += 1
        let backend = self.backend
        let profile = profileName
        let content = soulText
        let baseline = soulBaseline
        Task { [weak self] in
            enum Outcome: Sendable { case saved, conflict, failed(String) }
            let outcome: Outcome = await Task.detached {
                do {
                    if !force {
                        let current = try backend.readSoul(forProfile: profile) ?? ""
                        if current != baseline { return .conflict }
                    }
                    try backend.writeSoul(forProfile: profile, content: content)
                    return .saved
                } catch {
                    return .failed(Self.describe(error))
                }
            }.value
            guard let self else { return }
            self.isSavingSoul = false
            switch outcome {
            case .saved:
                self.soulBaseline = content
                self.soulConflict = false
                self.soulExists = true
            case .conflict:
                self.soulConflict = true
                self.soulError = "\(self.soulPath) changed on disk since you opened it. Reload to see the new version (your edits are discarded), or overwrite it."
            case .failed(let message):
                self.soulError = message
            }
            self.load(force: true)
        }
    }

    /// Throw the buffer away and take what is on disk. The one path that is
    /// allowed to clobber a dirty buffer, because the user asked.
    func discardSoulAndReload() {
        soulConflict = false
        soulError = nil
        soulText = soulBaseline
        hasLoadedSoul = false
        soulBaseline = ""
        soulText = ""
        load(force: true)
    }

    // MARK: - Error text

    /// CLI failures are shown verbatim: `hermes config set`/`tools enable`
    /// print the remedy ("Unknown toolset 'x'", "Config is managed by …") and
    /// a Scarf paraphrase would throw it away.
    nonisolated static func failureText(_ result: ProcessResult) -> String {
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return "hermes exited with code \(result.exitCode)."
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case BotsError.unsupported:
            return "This Hermes is too old for Bot Mode configuration."
        case BotsError.profileMissing(let name):
            return "No profile directory for \"\(name)\"."
        case BotsError.unsafeToRead(let path):
            return "Couldn't read \(path). It may be too large, or not text."
        case BotsError.unsafeToWrite(let path):
            return "Refusing to write \(path) — it isn't in a shape Scarf can safely replace."
        case BotsError.invalidValue(let key):
            return "Refusing to write \(key): the value is empty or contains characters that would change which setting is written."
        default:
            return (error as NSError).localizedDescription
        }
    }
}
