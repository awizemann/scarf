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

    /// Builds the `Process` for one login run, given the `hermes` argv.
    ///
    /// Injectable for the same reason `HermesCLIRunner` is (P11): the
    /// interesting behaviour here is the drain/termination race, and there is
    /// no way to provoke a specific interleaving through a real `hermes`.
    /// Production always uses `defaultProcess(args:)`; the caller must NOT set
    /// `standardOutput`/`standardError` — `start` owns the pipe.
    typealias ProcessFactory = @MainActor (_ args: [String]) -> Process

    private let makeLoginProcess: ProcessFactory?

    init(context: ServerContext = .local, makeLoginProcess: ProcessFactory? = nil) {
        self.context = context
        self.makeLoginProcess = makeLoginProcess
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
    /// Everything the reader has decoded but the main actor has not consumed
    /// yet, plus whether the reader has seen EOF. Reads land on the pipe's own
    /// queue and each one schedules an independent `Task { @MainActor }`;
    /// those hops are NOT ordered relative to one another, so the text has to
    /// be sequenced where it is produced rather than where it is applied.
    private let inbox = OutputInbox()
    /// The exit status, once the termination handler has reported it. Nil
    /// until then — and the verdict waits for BOTH this and EOF.
    private var pendingExit: Int32?
    /// Set by `finish`, so a late pump can't judge the same run twice.
    private var didFinish = false
    /// The server name of the run in flight, kept so `stop()` can reap the
    /// REMOTE half of it. Nil when nothing is running.
    private var runningServer: String?
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
        inbox.reset()
        pendingExit = nil
        didFinish = false

        var args = ["mcp", "login"]
        if let flow, !flow.isEmpty {
            args += ["--flow", flow]
        }
        // `--` ends the options: a server name is user-chosen text from
        // `mcp_servers`, and one starting with `-` would otherwise exit 2.
        args += ["--", server]
        runningServer = server

        let proc = (makeLoginProcess ?? defaultProcess)(args)

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        // A read can land mid-codepoint: `availableData` is a byte count,
        // not a character boundary, and `String(data:encoding:.utf8)`
        // returns nil for a truncated sequence — which used to drop the
        // WHOLE chunk. The device code or the verification URL disappearing
        // because a multi-byte glyph straddled a read is not recoverable by
        // the user. Keep the undecodable tail and prepend it to the next
        // read. Reads are serialised on the pipe's own queue, so the decoder
        // needs no lock; the decoded text goes into `inbox`, which does have
        // one because the main actor drains it concurrently.
        let decoder = IncrementalUTF8Decoder()
        let generation = self.generation
        let inbox = self.inbox
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                // EOF. Anything the decoder is still holding back is a
                // TRUNCATED final sequence — there will be no next read to
                // complete it, so flush it lossily rather than dropping the
                // process's last bytes, which can be the whole reason a
                // failure was reported the way it was.
                inbox.append(decoder.flush())
                inbox.markEOF()
            } else {
                inbox.append(decoder.decode(data))
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.pump()
            }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor [weak self] in
                // NB the reader's `readabilityHandler` is deliberately LEFT
                // INSTALLED here. Clearing it on termination is what made a
                // successful login report as a failure: the `✓ Authenticated`
                // line is written just before the process exits, and on the
                // losing side of that race the chunk carrying it was never
                // read — so the output the verdict judges did not contain it.
                // The pipe stays live until it reports EOF; `pump` judges only
                // once BOTH signals are in.
                guard let self, self.generation == generation else { return }
                self.pendingExit = code
                self.pump()
                self.scheduleDrainDeadline(generation: generation)
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

    /// The production `Process` for a login run.
    ///
    /// Same PYTHONUNBUFFERED reasoning as OAuthFlowController: without it
    /// Python block-buffers when stdout is a pipe, and the device prompt —
    /// the entire point of the sheet — arrives only once the process is done
    /// waiting, i.e. too late to be used.
    private func defaultProcess(_ args: [String]) -> Process {
        if context.isRemote {
            return context.makeTransport().makeProcess(
                executable: "env",
                args: ["PYTHONUNBUFFERED=1", context.paths.hermesBinary] + args
            )
        }
        let proc = context.makeTransport().makeProcess(
            executable: context.paths.hermesBinary,
            args: args
        )
        var env = HermesFileService.enrichedEnvironment()
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env
        return proc
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
        let wasRunning = process != nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        isRunning = false
        if wasRunning, let server = runningServer, context.isRemote {
            reapRemoteLogin(server: server)
        }
        runningServer = nil
    }

    /// Kill the REMOTE `hermes mcp login` that the local SIGTERM does not.
    ///
    /// `SSHTransport.makeProcess` builds `ssh -T … bash -lc '<cmd>'`
    /// (`SSHTransport.swift:693-716`). `-T` allocates no pty, so terminating
    /// the local `ssh` closes the channel but leaves the remote `hermes`
    /// running: it is in `_authorize`'s polling loop
    /// (`tools/mcp_oauth_device.py:131-140`), writes nothing until it is
    /// done, and so never takes a SIGPIPE. It keeps hitting the provider's
    /// token endpoint until its own deadline — `min(expires_in, timeout)`,
    /// default 300 s (`:123-124`) — long after the user dismissed the sheet.
    ///
    /// Two fixes were considered and rejected before this one:
    ///
    /// * **`ssh -tt`** (force a pty so the remote gets SIGHUP). It is not
    ///   safely reachable: `makeProcess` hard-codes `-T` for every consumer
    ///   (ACP JSON-RPC, log tails) and those need a binary-clean stream. Worse,
    ///   a pty makes Hermes's own output change — `hermes_cli/colors.py`'s
    ///   `should_use_color()` is `sys.stdout.isatty()`, so every `✓`/`✗` line
    ///   gains ANSI codes, and Rich starts wrapping at the pty's 80 columns,
    ///   which would fold the verification URL this sheet exists to show.
    ///   That is a user-visible change on a remote host for a stop-path fix —
    ///   exactly what charter C1 forbids.
    /// * **A shell wrapper that watches for stdin EOF.** `composedRemoteCommand`
    ///   quotes every token through `remotePathArg`, so no caller can inject a
    ///   shell operator into the remote command — by design, and worth keeping.
    ///
    /// What is left is an explicit best-effort reap over the same transport.
    /// The pattern matches only a command line that carries `mcp login` AND
    /// this server's name after the `--`, i.e. the process this controller
    /// started. `pkill` may be absent (its exit code says so) — the reap is
    /// advisory, and its failure is logged, never surfaced: the login is
    /// already over as far as the user is concerned.
    private func reapRemoteLogin(server: String) {
        let xport = context.makeTransport()
        let pattern = "mcp login .*-- " + Self.regexEscaped(server) + "$"
        let logger = self.logger
        Task.detached {
            do {
                // C10: off the main actor, with a timeout, like every other
                // spawn Scarf makes.
                let result = try xport.runProcess(
                    executable: "pkill", args: ["-f", pattern], stdin: nil, timeout: 10)
                // pkill exits 1 when nothing matched (the run had already
                // finished) and 127 when it is not installed. Neither is
                // actionable here.
                if result.exitCode != 0 {
                    logger.info("remote mcp login reap: pkill exit \(result.exitCode)")
                }
            } catch {
                logger.info("remote mcp login reap failed: \(error.localizedDescription)")
            }
        }
    }

    /// Escape every POSIX ERE metacharacter so a server name is matched
    /// literally by `pkill -f`. A name is user-chosen text from `mcp_servers`;
    /// an unescaped `.` or `|` in it would widen the pattern to processes this
    /// has no business signalling.
    nonisolated static func regexEscaped(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\^$.[]|()*+?{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
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

    /// A process can exit while something else still holds the write end of
    /// the pipe (a browser helper the login spawned, say), and then EOF never
    /// arrives. Waiting for the reader is right; waiting for it forever is
    /// not — the sheet would sit on its spinner with the verdict already
    /// knowable. After the grace period the drain is declared over and the
    /// verdict is taken on what did arrive.
    private func scheduleDrainDeadline(generation: UInt64) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.generation == generation, !self.didFinish else { return }
            self.inbox.markEOF()
            self.pump()
        }
    }

    /// Applies everything the reader has produced so far, then judges — but
    /// only once the reader has hit EOF AND the process has reported its exit
    /// status. Either can arrive first.
    private func pump() {
        let (text, sawEOF) = inbox.drain()
        if !text.isEmpty { append(text) }
        guard sawEOF, let code = pendingExit, !didFinish else { return }
        didFinish = true
        finish(exitCode: code)
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
            fallbackDetail: false,
            // `_success` prints `  ✓ Authenticated …` (mcp_config.py:34) —
            // column 0 once the indent and the glyph are stripped.
            successAnchored: true
        )
    }

    private func finish(exitCode: Int32) {
        isRunning = false
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        // The run is over on its own; a later `stop()` (the sheet closing)
        // must not spend an SSH round trip reaping a process that has exited.
        runningServer = nil
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

/// The reader side's hand-off buffer: text accumulates here in READ order on
/// the pipe's queue, and the main actor drains it whenever one of its hops
/// lands. Sequencing the text here rather than in the hops is what makes the
/// out-of-order `Task { @MainActor }` scheduling harmless.
private final class OutputInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var eof = false

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock(); pending += text; lock.unlock()
    }

    func markEOF() {
        lock.lock(); eof = true; lock.unlock()
    }

    /// Everything buffered since the last drain, plus whether the reader has
    /// reported EOF.
    func drain() -> (text: String, sawEOF: Bool) {
        lock.lock()
        defer { pending = ""; lock.unlock() }
        return (pending, eof)
    }

    func reset() {
        lock.lock(); pending = ""; eof = false; lock.unlock()
    }
}
