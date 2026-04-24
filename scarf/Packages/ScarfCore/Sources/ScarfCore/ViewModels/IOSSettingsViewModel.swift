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

    public init(context: ServerContext) {
        self.context = context
    }

    public func load() async {
        isLoading = true
        lastError = nil
        let ctx = context
        let path = ctx.paths.configYAML

        let text: String? = await Task.detached {
            ctx.readText(path)
        }.value

        guard let text else {
            config = .empty
            rawYAML = ""
            lastError = "`\(path)` not found on \(ctx.displayName). Once Hermes is configured on this host, Settings will light up."
            isLoading = false
            return
        }

        rawYAML = text
        config = HermesConfig(yaml: text)
        isLoading = false
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
        isSaving = true
        defer { isSaving = false }

        let ctx = context
        let hermes = ctx.paths.hermesBinary
        // Pass through the same PATH-prefix trick ACPClient+iOS uses
        // (pass-1 M7 #5) so remote non-interactive shells find hermes
        // even when it's in ~/.local/bin or /opt/homebrew/bin.
        let script = "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH\" \(hermes) config set \(shellEscape(key)) \(shellEscape(value))"

        let result: ProcessResult = try await Task.detached {
            try ctx.makeTransport().runProcess(
                executable: "/bin/sh",
                args: ["-c", script],
                stdin: nil,
                timeout: 15
            )
        }.value

        if result.exitCode != 0 {
            let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let combined = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
            throw SettingsSaveError.commandFailed(
                exitCode: result.exitCode,
                message: combined.isEmpty ? "hermes config set exited with code \(result.exitCode)" : combined
            )
        }

        // Reload so the UI reflects the just-written value.
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
