import Foundation
import Observation

/// iOS Settings view-state. Loads `~/.hermes/config.yaml` via the
/// transport, parses it into a `HermesConfig` with the ScarfCore
/// YAML port, and exposes the parsed struct plus a copy of the raw
/// text for users who want to see the source.
///
/// **M6 is read-only by design.** Editing config.yaml safely requires
/// either (a) a round-trip preserving YAML parser (comments, key
/// order, whitespace) or (b) delegating to `hermes config set` via
/// ACP. Either is more work than fits in M6; the Mac app's Settings
/// uses (a) via HermesFileService's manipulators. A later phase can
/// port the write side.
@Observable
@MainActor
public final class IOSSettingsViewModel {
    public let context: ServerContext

    /// Parsed config. Falls back to `.empty` when the file is missing
    /// or malformed; `lastError` carries the reason so the UI can
    /// surface it.
    public private(set) var config: HermesConfig = .empty
    /// Raw YAML text. Useful for the "View source" disclosure, and
    /// for diagnosing parse failures (our parser is forgiving but
    /// lossy on malformed input).
    public private(set) var rawYAML: String = ""

    public private(set) var isLoading: Bool = true
    public private(set) var lastError: String?

    /// Whether this host is a package-manager-managed Hermes — the iOS twin
    /// of `SettingsViewModel.managedInstall` (round-4 decision 1, second
    /// half; the round-4 review found iOS had taken the verdicts and not the
    /// probe).
    ///
    /// Probed once per home from `$HERMES_HOME/.managed` through the SAME
    /// process-wide cache the Mac uses, so a phone and a Mac pointed at one
    /// host read one marker the same way. `.notManaged` until it lands: the
    /// editor renders writable and then locks, never the reverse flash.
    /// `internal(set)` so ScarfCore tests can stand the managed state up
    /// without a host; production writes it only from ``load()``.
    public internal(set) var managedInstall: HermesManagedInstall = .notManaged

    public var isManagedHost: Bool { managedInstall.isManaged }

    /// The one banner, word for word the Mac's — the situation is the same
    /// one and two spellings of it would be two facts to keep true.
    public var managedBannerText: String? {
        guard let system = managedInstall.system else { return nil }
        return String(localized: "This Hermes is managed by \(system). Settings are read-only here — edit them through your package manager's configuration and re-deploy.")
    }

    public init(context: ServerContext) {
        self.context = context
    }

    public func load() async {
        isLoading = true
        lastError = nil
        let ctx = context
        let path = ctx.paths.configYAML

        // Direct file read, then the `cat "$(hermes config path)"`
        // wrapper fallback — covers HERMES_HOME overrides and wrappers
        // whose config lives somewhere the default path guess misses
        // (gh#112).
        let text: String? = await Task.detached {
            HermesConfigReader.readRawConfig(context: ctx)
        }.value

        // One `.managed` stat+read per home, off the main actor, memoized
        // process-wide. Capabilities decide how the marker is read — below
        // v0.20.5 `get_managed_system` never opens it and any marker means
        // managed (`hermes_cli/config.py:327-330` @ v2026.6.19).
        // P60: `capabilitiesSync` SPAWNS `hermes --version` and waits on a
        // cold cache, and the marker read is a transport stat+read behind
        // it — two blocking round trips, so this is `OffPool.run` rather
        // than `Task.detached`, which would park a pool thread through both
        // (charter C10).
        managedInstall = await OffPool.run {
            let caps = HermesVersionCache.shared.capabilitiesSync(for: ctx)
            return HermesManagedInstallCache.shared.managedInstall(for: ctx, capabilities: caps)
        }

        guard let text else {
            // Neither read found the file. If the Hermes CLI still
            // answers, the install is containerized (Docker et al.) —
            // the file exists only inside the container, invisible to
            // the file transport. Populate what the CLI can tell us
            // (the model section) and explain the topology instead of
            // the misleading "not found" (gh#112 failure 2).
            let probed: HermesConfig? = await Task.detached {
                HermesConfigReader.probeModelConfig(context: ctx)
            }.value
            config = probed ?? .empty
            rawYAML = ""
            if probed != nil {
                lastError = "Hermes answers on \(ctx.displayName), but its config.yaml isn't visible over the file transport — it likely lives inside a container. Model settings above were read via the Hermes CLI. To unlock full Settings, bind-mount the container's Hermes home to `~/.hermes` on this host (or add the server again with Advanced → Remote home pointed at the mounted path)."
            } else {
                // Even the CLI probe failed. Name the reason instead of
                // the misleading "not found" — for the gh#112 topology
                // (Docker-only hermes, no host-side wrapper) the message
                // must teach the wrapper fix, not shrug (see the v2.16.1
                // report: fallbacks shipped, user saw zero change).
                let diagnosis: HermesConfigReader.CLIProbeDiagnosis? = await Task.detached {
                    HermesConfigReader.diagnoseProbeFailure(context: ctx)
                }.value
                lastError = Self.unreachableConfigMessage(
                    path: path, host: ctx.displayName, diagnosis: diagnosis)
            }
            isLoading = false
            return
        }

        rawYAML = text
        config = HermesConfig(yaml: text)
        isLoading = false
    }

    /// The Settings banner when neither the file transport nor the Hermes
    /// CLI could produce a config. Static + pure so tests can pin each
    /// topology's guidance (gh#112).
    static func unreachableConfigMessage(
        path: String,
        host: String,
        diagnosis: HermesConfigReader.CLIProbeDiagnosis?
    ) -> String {
        switch diagnosis {
        case .cliNotFound:
            return "`\(path)` not found on \(host), and no `hermes` command is reachable over SSH. If Hermes runs inside a container (Docker), SSH can't see it: create a host-side wrapper — e.g. `/usr/local/bin/hermes` containing `#!/bin/sh` and `exec docker compose exec -T hermes hermes \"$@\"` — or set Advanced → Hermes binary to your wrapper's path when editing this server. (Shell aliases from `.bashrc` don't apply to SSH commands.)"
        case .commandFailed(let exitCode, let detail):
            let suffix = detail.isEmpty ? "." : ": \(detail)"
            return "`hermes` exists on \(host), but `hermes config show` failed (exit \(exitCode))\(suffix)"
        case .outputUnparsed:
            return "`hermes config show` answered on \(host), but Scarf couldn't find a model line in its output — this Hermes version may format it differently. Please open a GitHub issue with the output of `hermes config show`."
        case .transportFailed(let detail):
            return "Couldn't reach \(host) to read the config: \(detail)"
        case nil:
            return "`\(path)` not found on \(host). Once Hermes is configured on this host, Settings will light up."
        }
    }

    /// Set a dotted config key on the remote via `hermes config set`.
    /// Hermes owns the YAML round-trip (preserves comments, key
    /// order, formatting); Scarf just picks the value. Reloads the
    /// parsed config on success so the UI reflects the change
    /// immediately.
    ///
    /// Pass-1 M9 #4.3 — lets on-the-go users flip `model.default`,
    /// `agent.approval_mode`, `display.show_cost` etc. without going
    /// back to the Mac app. Scope intentionally narrow: a curated
    /// list of keys in the editor sheet, not a generic YAML writer.
    ///
    /// Throws on non-zero exit or connection failure. Callers should
    /// surface the error to the user (usually a banner on the editor
    /// sheet) and leave the sheet open for retry.
    public func saveValue(key: String, value: String) async throws {
        // A managed host refuses this write at exit 0 with a stderr line
        // nobody sees. The editor is already locked when this is true, so
        // reaching here means a programmatic call got past it: refuse with
        // the banner's own sentence instead of spawning a doomed process.
        if let refusal = managedBannerText {
            throw SettingsSaveError.commandFailed(exitCode: 0, message: refusal)
        }
        isSaving = true
        defer { isSaving = false }

        let ctx = context
        let hermes = ctx.paths.hermesBinary
        // Pass through the same PATH-prefix trick ACPClient+iOS uses
        // (pass-1 M7 #5) so remote non-interactive shells find hermes
        // even when it's in ~/.local/bin or /opt/homebrew/bin.
        let argv = HermesConfigSet.argv(key: key, value: value).map(shellEscape).joined(separator: " ")
        let script = "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH\" \(hermes) \(argv)"

        // Round-6 decision 11: the `async` seam, so the wait is a suspension
        // rather than a cooperative-pool thread blocked on the exec that runs
        // on that same pool (charter C10).
        let result: ProcessResult = try await ctx.makeTransport().asyncRunProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            stdin: nil,
            timeout: 15
        )

        // P39: judged by OUTPUT, exactly like `unsetValue` below and for the
        // same reason — `set_config_value`'s managed-install arm prints to
        // stderr and `return`s (`hermes_cli/config.py:3450-3452` @ v2026.9.7),
        // i.e. exits 0. See ``HermesConfigSet``.
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let outcome = HermesConfigSet.judge(output: combined, exitCode: result.exitCode)
        guard outcome.succeeded else {
            throw SettingsSaveError.commandFailed(
                exitCode: result.exitCode,
                message: outcome.detail ?? "hermes config set \(key) did not confirm the value was written"
            )
        }

        // Reload so the UI reflects the just-written value.
        await load()
    }

    /// Write `voice.voice_chat_mode` (chained | gpt-live), which makes Live
    /// Voice available on a v0.21.3+ host (`hasGPTLiveVoice`). Same verified
    /// `config set` argv and output verdict as ``saveValue(key:value:)``
    /// (see ``VoiceChatMode``). Below the floor Hermes has no such
    /// mode, so this refuses without spawning anything (charter C1).
    public func saveVoiceChatMode(_ mode: VoiceChatMode, capabilities: HermesCapabilities) async throws {
        guard capabilities.hasGPTLiveVoice else {
            throw SettingsSaveError.commandFailed(
                exitCode: 0,
                message: String(localized: "Live Voice needs Hermes 0.21.3 or newer on this server."))
        }
        try await saveValue(key: "voice.voice_chat_mode", value: mode.configValue)
    }

    /// Remove a dotted config key on the remote via `hermes config unset`.
    ///
    /// Not `saveValue(key:value:"")`: `hermes config set <key> ''` writes an
    /// EMPTY SCALAR, and for `approvals.mode` that is not absence —
    /// `_coerce_config_set_value` keeps the string verbatim for a str-typed
    /// key (`hermes_cli/config.py:3306-3312` @ v2026.9.7) and
    /// `_normalize_approval_mode("")` resolves it to `manual`
    /// (`tools/approval_context.py:197-214`), while Scarf's own reader drops
    /// it and renders "Host default" over the top. Only `config unset`
    /// actually clears the key (round-3 decision 10).
    ///
    /// Judged by OUTPUT, not exit code: `unset_config_value`'s managed-install
    /// arm prints its refusal and `return`s (`hermes_cli/config.py:3549-3551`),
    /// i.e. exits 0. Callers must gate on `HermesCapabilities.hasConfigUnset`;
    /// the verb does not exist below v0.19.0.
    public func unsetValue(key: String) async throws {
        // A managed host refuses this write at exit 0 with a stderr line
        // nobody sees. The editor is already locked when this is true, so
        // reaching here means a programmatic call got past it: refuse with
        // the banner's own sentence instead of spawning a doomed process.
        if let refusal = managedBannerText {
            throw SettingsSaveError.commandFailed(exitCode: 0, message: refusal)
        }
        isSaving = true
        defer { isSaving = false }

        let ctx = context
        let hermes = ctx.paths.hermesBinary
        let argv = HermesConfigUnset.argv(key: key).map(shellEscape).joined(separator: " ")
        let script = "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH\" \(hermes) \(argv)"

        // Round-6 decision 11: the `async` seam, so the wait is a suspension
        // rather than a cooperative-pool thread blocked on the exec that runs
        // on that same pool (charter C10).
        let result: ProcessResult = try await ctx.makeTransport().asyncRunProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            stdin: nil,
            timeout: 15
        )

        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let outcome = HermesConfigUnset.judge(output: combined, exitCode: result.exitCode)
        guard outcome.succeeded else {
            throw SettingsSaveError.commandFailed(
                exitCode: result.exitCode,
                message: outcome.detail ?? "hermes config unset \(key) did not confirm the key was removed"
            )
        }

        await load()
    }

    /// True while a `saveValue(...)` call is in flight. Sheet uses
    /// this to disable the Save button + show a ProgressView.
    public private(set) var isSaving: Bool = false

    /// Single-quote-escape a shell argument. Handles embedded single
    /// quotes via the standard `'"'"'` trick. Used to quote both the
    /// key and the value on the remote command line.
    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// Errors surfaced by `IOSSettingsViewModel.saveValue`. Kept public
/// so SettingEditorSheet (ScarfGo) can narrow on commandFailed to
/// show the stderr payload inline instead of just the generic text.
public enum SettingsSaveError: Error, LocalizedError {
    case commandFailed(exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(_, let message): return message
        }
    }
}
