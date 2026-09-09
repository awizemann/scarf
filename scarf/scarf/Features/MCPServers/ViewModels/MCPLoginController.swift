import Foundation
import ScarfCore
import AppKit
import os

/// Drives one `hermes mcp login <name> [--flow browser|device]` run (v0.21.1+)
/// and surfaces what it prints while it prints it.
///
/// This exists rather than reusing `OAuthFlowController` because that one is
/// wired to `auth add` — its argv, its "Authorization code:" stdin prompt and
/// its URL heuristics are all pooled-credential specific. What the two DO
/// share is the reason they are processes rather than a `runHermes` round
/// trip: the interesting output arrives while the command is still running,
/// and a login can sit waiting for a human for minutes.
///
/// Two details from `tools/mcp_oauth_device.py::_authorize` shape this:
///
/// * The device prompt is written to **stderr**. `standardError` is merged
///   into `standardOutput` here; capturing only stdout would show the user an
///   empty pane until the authorization expired.
/// * The prompt carries a user code that is not in the URL, so the sheet has
///   to render `HermesMCPDevicePrompt` rather than just open a link.
@Observable
@MainActor
final class MCPLoginController {
    private let logger = Logger(subsystem: "com.scarf", category: "MCPLoginController")
    let context: ServerContext

    init(context: ServerContext = .local) {
        self.context = context
    }

    /// Accumulated combined output, shown verbatim. Hermes's own wording is
    /// the source of truth for every failure this can hit (DCR 400s,
    /// unsupported token auth, an expired device authorization).
    private(set) var output: String = ""
    /// Parsed device prompt, once both of its lines have arrived.
    private(set) var devicePrompt: HermesMCPDevicePrompt?
    private(set) var isRunning: Bool = false
    /// Nil until the process exits. `true` only when the CLI printed its own
    /// `Authenticated …` line — NOT on a zero exit, which every OAuth failure
    /// also produces. See `loginOutcome`.
    private(set) var succeeded: Bool?
    private(set) var errorMessage: String?

    private var process: Process?
    private var stdoutPipe: Pipe?
    /// Bumped by `stop()` (and so by every `start()`, which calls it first).
    /// Output and exits from a retired run are dropped rather than attributed
    /// to the run that replaced it.
    private var generation: UInt64 = 0

    /// Start the login. `flow` is `nil` to let Hermes use the server's
    /// configured `oauth.flow`, or `"browser"` / `"device"` to override it —
    /// the only two values `mcp_config.py:640` accepts.
    ///
    /// Callers MUST be gated on `HermesCapabilities.hasMCPOAuthFlow` before
    /// passing a non-nil `flow`: `hermes mcp login` exists from v0.18, but
    /// `--flow` is v0.21.1, and an older argparse exits 2 on it.
    func start(server: String, flow: String?) {
        stop()
        output = ""
        devicePrompt = nil
        succeeded = nil
        errorMessage = nil

        var args = ["mcp", "login"]
        if let flow, !flow.isEmpty {
            args += ["--flow", flow]
        }
        // `--` ends the options: a server name is user-chosen text from
        // `mcp_servers`, and one starting with `-` would otherwise exit 2.
        args += ["--", server]

        // Same PYTHONUNBUFFERED reasoning as OAuthFlowController: without it
        // Python block-buffers when stdout is a pipe, and the device prompt —
        // the entire point of the sheet — arrives only once the process is
        // done waiting, i.e. too late to be used.
        let proc: Process
        if context.isRemote {
            proc = context.makeTransport().makeProcess(
                executable: "env",
                args: ["PYTHONUNBUFFERED=1", context.paths.hermesBinary] + args
            )
        } else {
            proc = context.makeTransport().makeProcess(
                executable: context.paths.hermesBinary,
                args: args
            )
            var env = HermesFileService.enrichedEnvironment()
            env["PYTHONUNBUFFERED"] = "1"
            proc.environment = env
        }

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        // A read can land mid-codepoint: `availableData` is a byte count,
        // not a character boundary, and `String(data:encoding:.utf8)`
        // returns nil for a truncated sequence — which used to drop the
        // WHOLE chunk. The device code or the verification URL disappearing
        // because a multi-byte glyph straddled a read is not recoverable by
        // the user. Keep the undecodable tail and prepend it to the next
        // read. Reads are serialised on the pipe's own queue, so the buffer
        // needs no lock beyond being owned by this run's closure.
        let decoder = IncrementalUTF8Decoder()
        let generation = self.generation
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = decoder.decode(data)
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.append(chunk)
            }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor [weak self] in
                outPipe.fileHandleForReading.readabilityHandler = nil
                // A run that `stop()` already retired must not report its
                // exit: a retried login would be marked failed by run A's
                // SIGTERM landing after run B started.
                guard let self, self.generation == generation else { return }
                self.finish(exitCode: code)
            }
        }

        do {
            try proc.run()
            process = proc
            stdoutPipe = outPipe
            isRunning = true
        } catch {
            errorMessage = "Failed to start hermes: \(error.localizedDescription)"
            logger.error("mcp login failed to start: \(error.localizedDescription)")
        }
    }

    /// Terminate an in-flight login. Safe when nothing is running — the sheet
    /// calls this on dismiss so a device flow doesn't keep polling the token
    /// endpoint after the user walked away.
    func stop() {
        // Retire this run BEFORE terminating it: `terminate()` fires the
        // termination handler asynchronously, and without the generation
        // bump (and without clearing the handler on the process itself)
        // run A's SIGTERM exit would land on run B and mark the retried
        // login failed.
        generation &+= 1
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        isRunning = false
    }

    func openVerificationURL() {
        guard let url = devicePrompt.flatMap({ URL(string: $0.verificationURL) }) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyUserCode() {
        guard let code = devicePrompt?.userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func append(_ chunk: String) {
        output += chunk
        // Re-parse cumulative output: the URL line and the code line can
        // arrive in different reads.
        if devicePrompt == nil {
            devicePrompt = HermesMCPDevicePrompt.parse(output)
        }
    }

    /// The verdict on a finished login run, judged by what the CLI printed.
    ///
    /// `cmd_mcp_login` (hermes_cli/mcp_config.py:709-713 at v2026.9.7) calls
    /// `_reauth_oauth_server(...)` and DISCARDS the `bool` it returns, so every
    /// failure exits 0: an unknown server name (`_lookup_server`, :104), a
    /// non-OAuth server (:631, :634), a bad `oauth.flow` (:641), a completed
    /// probe with no token (`:676-693` — the subtle one, where the server
    /// answers `tools/list` unauthenticated so the run LOOKS fine), and a
    /// raised exception (`Authentication failed:`, :705). Only `_success`
    /// (:34) prints `Authenticated — N tool(s) available` (:695) or
    /// `Authenticated (server reported no tools)` (:697), and both lines are
    /// byte-identical back to v2026.6.19:746, so an older host is judged the
    /// same way (charter C1, C5).
    ///
    /// `fallbackDetail` is off: the failure arms print multi-line remediation
    /// AFTER the reason (the config.yaml sample at :685-692, the
    /// `Then re-run …` hint at :692), so the LAST line is never the reason.
    nonisolated static func loginOutcome(exitCode: Int32, output: String) -> HermesCLIOutcome {
        HermesCLIVerdict.judge(
            output: output,
            exitCode: exitCode,
            successMarkers: HermesCLIMarkers.mcpLoginSuccess,
            failureMarkers: HermesCLIMarkers.mcpLoginFailure,
            fallbackDetail: false
        )
    }

    private func finish(exitCode: Int32) {
        isRunning = false
        let outcome = Self.loginOutcome(exitCode: exitCode, output: output)
        succeeded = outcome.succeeded
        if !outcome.succeeded, errorMessage == nil {
            // The CLI's own refusal line is the reason; the exit code alone
            // tells the user nothing actionable — and for the exit-0 failures
            // it is affirmatively misleading.
            errorMessage = outcome.detail
                ?? (exitCode == 0
                    ? "hermes mcp login exited without reporting authentication."
                    : "hermes exited with code \(exitCode)")
        }
    }
}
