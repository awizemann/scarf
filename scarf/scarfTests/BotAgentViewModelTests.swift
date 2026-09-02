import Foundation
import Testing
import ScarfCore
@testable import scarf

/// Phase B P1 — the bot editor's Agent area.
///
/// Everything here runs against a scripted backend, so the assertions are
/// about the view model's own discipline: does a pin round-trip and show the
/// right ORIGIN, does an unreadable `config.yaml` ever get called "Hermes
/// default", does a reload clobber unsaved `SOUL.md`, does a refused toggle
/// leave the row lying.
@Suite("Bot agent configuration (Phase B P1)")
@MainActor
struct BotAgentViewModelTests {

    // MARK: - Scripted backend

    /// Sync + `Sendable` because the protocol is called from a detached task.
    /// A lock rather than an actor: the methods are synchronous by design
    /// (they model blocking transport I/O).
    final class MockBackend: BotAgentBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var _model: String?
        private var _provider: String?
        private var _soul: String?
        /// (name, explicit `enabled:` value) — `nil` means the key is ABSENT,
        /// which Hermes reads as enabled.
        private var _mcpEnabled: [(name: String, enabled: Bool?)] = []
        private var _toolsets: [String: Bool] = [:]

        /// Written verbatim to `configReadable`; `false` means "we could not
        /// look", not "nothing is pinned".
        var configReadable = true
        var configExists = true
        /// Non-nil makes the next matching write fail with this CLI text.
        var toolsetFailure: String?
        var mcpFailure: String?
        var pinFailure: String?
        /// Simulates someone else editing SOUL.md between load and save.
        var soulUnreadable = false
        private(set) var writtenSouls: [String] = []
        private(set) var unsetKeys: [String] = []

        init(
            model: String? = nil,
            provider: String? = nil,
            soul: String? = nil,
            mcp: [(name: String, enabled: Bool?)] = [],
            toolsets: [String: Bool] = [:]
        ) {
            _model = model
            _provider = provider
            _soul = soul
            _mcpEnabled = mcp
            _toolsets = toolsets
        }

        /// Stand in for an external editor touching the file.
        func externallySetSoul(_ text: String?) {
            lock.lock(); defer { lock.unlock() }
            _soul = text
        }

        var canWriteSkillEnablement: Bool { false }
        func soulPath(forProfile name: String) -> String { "/home/.hermes/profiles/\(name)/SOUL.md" }

        func readAgentConfig(forProfile name: String) throws -> BotAgentConfig {
            lock.lock(); defer { lock.unlock() }
            return BotAgentConfig(
                profileName: name,
                configPath: "/home/.hermes/profiles/\(name)/config.yaml",
                configExists: configExists,
                configReadable: configReadable,
                model: BotConfigValue(pinned: configReadable ? _model : nil),
                provider: BotConfigValue(pinned: configReadable ? _provider : nil),
                modelBaseURL: nil,
                disabledSkills: [],
                platformToolsets: [:],
                mcpServers: _mcpEnabled
                    .sorted { $0.name < $1.name }
                    .map { BotMCPServerState(name: $0.name, explicitlyEnabled: $0.enabled) }
            )
        }

        func listToolsets(forProfile name: String, platform: String) throws -> ProcessResult {
            lock.lock(); defer { lock.unlock() }
            let lines = _toolsets.keys.sorted().map { key in
                "\(_toolsets[key] == true ? "✓ enabled" : "✗ disabled")  \(key)  🔧 the \(key) toolset"
            }
            return Self.ok(lines.joined(separator: "\n"))
        }

        func readSoul(forProfile name: String) throws -> String? {
            if soulUnreadable { throw BotsError.unsafeToRead(path: soulPath(forProfile: name)) }
            lock.lock(); defer { lock.unlock() }
            return _soul
        }

        func writeSoul(forProfile name: String, content: String) throws {
            lock.lock(); defer { lock.unlock() }
            _soul = content
            writtenSouls.append(content)
        }

        func setModelPin(forProfile name: String, provider: String?, model: String?) throws -> [ProcessResult] {
            if let pinFailure { return [Self.fail(pinFailure)] }
            lock.lock(); defer { lock.unlock() }
            if let provider { _provider = provider }
            if let model { _model = model }
            return [Self.ok(), Self.ok()]
        }

        func clearModelPin(forProfile name: String) throws -> [ProcessResult] {
            lock.lock(); defer { lock.unlock() }
            var results: [ProcessResult] = []
            for key in ["model.default", "model.provider"] {
                unsetKeys.append(key)
                let wasSet = key == "model.default" ? _model != nil : _provider != nil
                results.append(wasSet ? Self.ok() : Self.fail("Config key not set: \(key)"))
            }
            _model = nil
            _provider = nil
            return results
        }

        func setToolsetEnabled(forProfile name: String, toolset: String, platform: String, enabled: Bool) throws -> ProcessResult {
            if let toolsetFailure { return Self.fail(toolsetFailure) }
            lock.lock(); defer { lock.unlock() }
            _toolsets[toolset] = enabled
            return Self.ok()
        }

        func setMCPServerEnabled(forProfile name: String, server: String, enabled: Bool) throws -> ProcessResult {
            if let mcpFailure { return Self.fail(mcpFailure) }
            lock.lock(); defer { lock.unlock() }
            if let idx = _mcpEnabled.firstIndex(where: { $0.name == server }) {
                _mcpEnabled[idx].enabled = enabled
            } else {
                _mcpEnabled.append((name: server, enabled: enabled))
            }
            return Self.ok()
        }

        static func ok(_ stdout: String = "") -> ProcessResult {
            ProcessResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
        }
        static func fail(_ stderr: String) -> ProcessResult {
            ProcessResult(exitCode: 1, stdout: Data(), stderr: Data(stderr.utf8))
        }
    }

    private static func makeViewModel(_ backend: MockBackend) -> BotAgentViewModel {
        BotAgentViewModel(
            profileName: "research",
            capabilities: HermesCapabilities(
                versionLine: "hermes 0.21.0",
                semver: .init(major: 0, minor: 21, patch: 0),
                dateVersion: nil
            ),
            backend: backend
        )
    }

    /// Poll until `condition` holds — the view model's writes finish on
    /// detached tasks it does not hand back.
    private static func settle(
        _ condition: @MainActor () -> Bool,
        _ comment: Comment = "timed out"
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record(comment)
    }

    // MARK: - Origin rendering (pure)

    @Test("an unpinned bot reads as Hermes' default, never as the root profile's model")
    func unpinnedRendersAsHermesDefault() {
        let config = BotAgentConfig(
            profileName: "research", configPath: "/p/config.yaml",
            configExists: true, configReadable: true,
            model: BotConfigValue(pinned: nil), provider: BotConfigValue(pinned: nil),
            modelBaseURL: nil, disabledSkills: [], platformToolsets: [:], mcpServers: []
        )
        #expect(BotAgentViewModel.modelPinState(config) == .hermesDefault)
        #expect(BotAgentViewModel.modelSummary(config) == "Hermes default")
    }

    @Test("a pinned bot names the provider and the model")
    func pinnedRendersBoth() {
        let config = BotAgentConfig(
            profileName: "research", configPath: "/p/config.yaml",
            configExists: true, configReadable: true,
            model: BotConfigValue(pinned: "anthropic/claude-opus-4.6"),
            provider: BotConfigValue(pinned: "openrouter"),
            modelBaseURL: nil, disabledSkills: [], platformToolsets: [:], mcpServers: []
        )
        #expect(BotAgentViewModel.modelSummary(config) == "Pinned: openrouter/anthropic/claude-opus-4.6")
    }

    /// The whole reason `configReadable` exists. An existing-but-unparseable
    /// file yields the same all-nil snapshot as an absent one; calling that
    /// "Hermes default" would tell the user their bot runs on defaults when it
    /// may be pinned to anything.
    @Test("an unreadable config.yaml never renders as 'Hermes default'")
    func unreadableConfigIsItsOwnState() {
        let config = BotAgentConfig(
            profileName: "research", configPath: "/p/config.yaml",
            configExists: true, configReadable: false,
            model: BotConfigValue(pinned: nil), provider: BotConfigValue(pinned: nil),
            modelBaseURL: nil, disabledSkills: [], platformToolsets: [:], mcpServers: []
        )
        #expect(BotAgentViewModel.modelPinState(config) == .unreadable(path: "/p/config.yaml"))
        let summary = BotAgentViewModel.modelSummary(config)
        #expect(summary.contains("Couldn't read /p/config.yaml"))
        #expect(!summary.contains("Hermes default"))
    }

    @Test("a missing config.yaml IS trustworthy — the bot really is on Hermes' defaults")
    func absentConfigIsTrustworthy() {
        let config = BotAgentConfig(
            profileName: "research", configPath: "/p/config.yaml",
            configExists: false, configReadable: true,
            model: BotConfigValue(pinned: nil), provider: BotConfigValue(pinned: nil),
            modelBaseURL: nil, disabledSkills: [], platformToolsets: [:], mcpServers: []
        )
        #expect(BotAgentViewModel.modelPinState(config) == .hermesDefault)
    }

    // MARK: - Pin round-trip

    @Test("pinning then clearing round-trips through the origin")
    func pinClearRoundTrip() async {
        let backend = MockBackend()
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.config != nil }
        #expect(vm.modelPinState == .hermesDefault)
        #expect(!vm.isPinned)

        vm.setModelPin(model: "kimi-k2", provider: "moonshot")
        await Self.settle { vm.isPinned }
        #expect(vm.modelSummary == "Pinned: moonshot/kimi-k2")
        #expect(vm.errorMessage == nil)

        vm.clearModelPin()
        await Self.settle { !vm.isPinned && !vm.isPinBusy }
        #expect(vm.modelPinState == .hermesDefault)
        // Both keys are unset even though only one may have been pinned.
        #expect(backend.unsetKeys == ["model.default", "model.provider"])
        // `config unset` on an unpinned key exits non-zero with "Config key
        // not set" — a success from the user's point of view, never an error.
        #expect(vm.errorMessage == nil)
    }

    @Test("clearing an already-unpinned bot reports no error")
    func clearingUnpinnedIsNotAFailure() async {
        let backend = MockBackend()
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.config != nil }
        vm.clearModelPin()
        await Self.settle { !vm.isPinBusy && vm.config != nil }
        #expect(vm.errorMessage == nil)
    }

    @Test("a refused pin surfaces the CLI's own text verbatim")
    func pinFailureIsVerbatim() async {
        let backend = MockBackend()
        backend.pinFailure = "Error: config is managed by /etc/hermes/config.yaml and cannot be changed"
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.config != nil }
        vm.setModelPin(model: "kimi-k2", provider: "moonshot")
        await Self.settle { vm.errorMessage != nil }
        #expect(vm.errorMessage == "Error: config is managed by /etc/hermes/config.yaml and cannot be changed")
    }

    @Test("writes are refused while the snapshot can't be trusted")
    func untrustworthySnapshotDisablesWrites() async {
        let backend = MockBackend(model: "kimi-k2")
        backend.configReadable = false
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.config != nil }
        #expect(!vm.canEditConfig)
        vm.setModelPin(model: "gpt-5", provider: "openai")
        // No write may be issued blind against a file Scarf never read.
        #expect(!vm.isPinBusy)
        #expect(vm.modelPinState == .unreadable(path: "/home/.hermes/profiles/research/config.yaml"))
    }

    // MARK: - SOUL.md

    @Test("a reload never clobbers an unsaved SOUL.md buffer")
    func reloadPreservesDirtyBuffer() async {
        let backend = MockBackend(soul: "You are a careful researcher.")
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.hasLoadedSoul }
        #expect(vm.soulText == "You are a careful researcher.")
        #expect(!vm.isSoulDirty)

        vm.soulText = "You are a careful researcher.\nNever guess."
        #expect(vm.isSoulDirty)

        vm.load(force: true)
        await Self.settle { !vm.isLoading }
        #expect(vm.soulText == "You are a careful researcher.\nNever guess.")
        #expect(vm.isSoulDirty)
    }

    @Test("saving refuses when the file changed under the buffer, and overwrite is explicit")
    func saveDetectsExternalEdit() async {
        let backend = MockBackend(soul: "original")
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.hasLoadedSoul }

        vm.soulText = "my edit"
        backend.externallySetSoul("someone else's edit")

        vm.saveSoul()
        await Self.settle { vm.soulConflict }
        // Nothing was written — a stale whole-file save would have silently
        // dropped the other edit.
        #expect(backend.writtenSouls.isEmpty)
        #expect(vm.soulError?.contains("changed on disk") == true)

        vm.saveSoul(force: true)
        await Self.settle { !backend.writtenSouls.isEmpty }
        #expect(backend.writtenSouls == ["my edit"])
    }

    @Test("a clean save updates the merge base so the buffer stops reading dirty")
    func cleanSaveRebases() async {
        let backend = MockBackend(soul: "original")
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.hasLoadedSoul }
        vm.soulText = "revised"
        vm.saveSoul()
        await Self.settle { !vm.isSavingSoul && !vm.isSoulDirty }
        #expect(backend.writtenSouls == ["revised"])
        #expect(vm.soulBaseline == "revised")
        #expect(!vm.soulConflict)
    }

    @Test("an unreadable SOUL.md disables saving instead of offering an empty editor")
    func unreadableSoulRefusesToSave() async {
        let backend = MockBackend(soul: "real identity prompt")
        backend.soulUnreadable = true
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.config != nil }
        #expect(vm.soulUnreadable)
        #expect(!vm.canSaveSoul)
        vm.soulText = ""
        vm.saveSoul()
        #expect(backend.writtenSouls.isEmpty)
    }

    @Test("an absent SOUL.md is an empty editor, not an error")
    func absentSoulIsEditable() async {
        let backend = MockBackend(soul: nil)
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.hasLoadedSoul }
        #expect(!vm.soulExists)
        #expect(!vm.soulUnreadable)
        #expect(vm.soulText.isEmpty)
        #expect(vm.soulError == nil)
    }

    @Test("a buffer over the 256KB cap can't be saved")
    func oversizedBufferIsRefused() async {
        let backend = MockBackend(soul: "small")
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.hasLoadedSoul }
        vm.soulText = String(repeating: "x", count: BotAgentConfigService.maxSoulBytes + 1)
        #expect(vm.soulOverLimit)
        #expect(!vm.canSaveSoul)
    }

    @Test("reverting drops the edits and clears the dirty flag")
    func revertRestoresBaseline() async {
        let backend = MockBackend(soul: "original")
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { vm.hasLoadedSoul }
        vm.soulText = "scratch"
        vm.revertSoul()
        #expect(vm.soulText == "original")
        #expect(!vm.isSoulDirty)
    }

    // MARK: - Toolsets

    @Test("a refused toolset toggle snaps the row back and shows the CLI text")
    func toolsetFailureRecovers() async {
        let backend = MockBackend(toolsets: ["web": true, "shell": false])
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { !vm.toolsets.isEmpty }
        #expect(vm.toolsets.map(\.name) == ["shell", "web"])
        #expect(vm.toolsets.first { $0.name == "web" }?.enabled == true)

        backend.toolsetFailure = "Unknown toolset 'web' for platform cli"
        guard let web = vm.toolsets.first(where: { $0.name == "web" }) else {
            Issue.record("no web toolset"); return
        }
        vm.setToolset(web, enabled: false)
        await Self.settle { vm.rowErrors["web"] != nil }
        #expect(vm.rowErrors["web"] == "Unknown toolset 'web' for platform cli")
        await Self.settle { vm.toolsets.first { $0.name == "web" }?.enabled == true }
    }

    @Test("a successful toolset toggle persists through the re-read")
    func toolsetToggleRoundTrips() async {
        let backend = MockBackend(toolsets: ["web": true])
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { !vm.toolsets.isEmpty }
        guard let web = vm.toolsets.first else { Issue.record("no toolset"); return }
        vm.setToolset(web, enabled: false)
        await Self.settle { vm.toolsets.first?.enabled == false && vm.busyToolsets.isEmpty }
        #expect(vm.rowErrors["web"] == nil)
    }

    // MARK: - MCP

    @Test("an MCP server with no enabled: key renders as on BY DEFAULT, not as a choice")
    func mcpAbsentMeansEnabled() async {
        let backend = MockBackend(mcp: [("github", nil), ("linear", true), ("notion", false)])
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { !vm.mcpServers.isEmpty }
        let github = vm.mcpServers.first { $0.name == "github" }
        #expect(github?.isEnabled == true)
        #expect(github?.origin == BotConfigOrigin.hermesDefault)
        #expect(vm.mcpServers.first { $0.name == "linear" }?.origin == BotConfigOrigin.pinned)
        #expect(vm.mcpServers.first { $0.name == "notion" }?.isEnabled == false)
    }

    @Test("switching an MCP server off writes the key explicitly")
    func mcpToggleWritesExplicitly() async {
        let backend = MockBackend(mcp: [("github", nil)])
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { !vm.mcpServers.isEmpty }
        guard let github = vm.mcpServers.first else { Issue.record("no server"); return }
        vm.setMCPServer(github, enabled: false)
        await Self.settle { vm.mcpServers.first?.isEnabled == false }
        #expect(vm.mcpServers.first?.origin == BotConfigOrigin.pinned)
    }

    @Test("a refused MCP toggle surfaces the CLI text and leaves the row truthful")
    func mcpFailureIsVerbatim() async {
        let backend = MockBackend(mcp: [("github", nil)])
        backend.mcpFailure = "Error: invalid config key mcp_servers.github.enabled"
        let vm = Self.makeViewModel(backend)
        vm.load()
        await Self.settle { !vm.mcpServers.isEmpty }
        guard let github = vm.mcpServers.first else { Issue.record("no server"); return }
        vm.setMCPServer(github, enabled: false)
        await Self.settle { vm.rowErrors["github"] != nil }
        #expect(vm.rowErrors["github"] == "Error: invalid config key mcp_servers.github.enabled")
        // Never optimistically flipped — the row still shows what the file says.
        #expect(vm.mcpServers.first?.isEnabled == true)
    }

    // MARK: - Skills

    @Test("skills enablement is stated as read-only rather than offered as a dead toggle")
    func skillsAreReadOnly() {
        let vm = Self.makeViewModel(MockBackend())
        #expect(!vm.canWriteSkillEnablement)
    }

    // MARK: - Error text

    @Test("a failure with only stdout still surfaces something actionable")
    func failureTextFallsBackToStdout() {
        let result = ProcessResult(exitCode: 2, stdout: Data("Config key not set".utf8), stderr: Data())
        #expect(BotAgentViewModel.failureText(result) == "Config key not set")
        let silent = ProcessResult(exitCode: 3, stdout: Data(), stderr: Data())
        #expect(BotAgentViewModel.failureText(silent) == "hermes exited with code 3.")
    }
}
