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
    /// The hop that resolves the login-shell environment before a LOCAL
    /// spawn (C10, round-6 P58). `enrichedEnvironment()` reads a `static let`
    /// whose initialiser is two `zsh` probes at 5 s + 3 s behind a
    /// `swift_once`, so a main-actor reader arriving during the launch
    /// warm-up blocks the window for up to eight seconds — on the click that
    /// opens this sheet. Held so `stop()` can retire a start that has not
    /// reached `proc.run()` yet.
    private var startTask: Task<Void, Never>?
    private var stdoutPipe: Pipe?
    /// Everything the reader has decoded but the main actor has not consumed
    /// yet, plus whether the reader has seen EOF. Reads land on the pipe's own
    /// queue and each one schedules an independent `Task { @MainActor }`;
    /// those hops are NOT ordered relative to one another, so the text has to
    /// be sequenced where it is produced rather than where it is applied.
    ///
    /// ONE PER RUN, captured by that run's reader closure. A single instance
    /// reset per run re-opened P21's drain race: the reader's `append` /
    /// `markEOF` carry no generation check (they run on the pipe's queue,
    /// where `generation` is not readable), so a retired run's reader wrote
    /// into the replacement run's buffer — and could `markEOF` it — and the
    /// new run's verdict was then judged on the old run's text, or before its
    /// own output had drained. That is exactly the success-reported-as-failure
    /// bug P21 fixed. With a fresh inbox per run, a stale reader writes into a
    /// buffer nothing will ever drain.
    private var inbox = ProcessOutputInbox()
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
        let inbox = ProcessOutputInbox()
        self.inbox = inbox
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

        // `isRunning` is raised HERE, before the environment hop, not in
        // `launch`: its whole point is that the sheet shows the run as live
        // FROM THE CLICK, and the hop can take a second on a cold
        // `swift_once` (round-6 P58). `stop()` lowers it.
        isRunning = true

        // C10: resolve the login-shell environment OFF the main actor
        // before spawning — see ``startTask``. An injected process or a
        // remote context needs none of it (ssh forwards no environment, so
        // the remote branch wraps the command in `env PYTHONUNBUFFERED=1 …`).
        guard makeLoginProcess == nil, !context.isRemote else {
            launch(args: args, server: server, inbox: inbox, localEnvironment: nil)
            return
        }
        startTask = Task { [weak self] in
            let env = await OffPool.run { HermesFileService.enrichedEnvironment() }
            guard let self, !Task.isCancelled else { return }
            self.launch(args: args, server: server, inbox: inbox, localEnvironment: env)
        }
    }

    /// Build and spawn the run. `localEnvironment` is the pre-resolved
    /// login-shell environment for a local, non-injected run; `nil` otherwise.
    private func launch(
        args: [String],
        server: String,
        inbox: ProcessOutputInbox,
        localEnvironment: [String: String]?
    ) {
        let proc = makeLoginProcess?(args)
            ?? defaultProcess(args, localEnvironment: localEnvironment)

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

        // C10: `Process.run()` is a fork/exec, and on a remote context it is
        // an `ssh` spawn — neither belongs on the main actor. The P21
        // EOF-then-judge sequencing is untouched: both handlers are installed
        // ABOVE, before the process can produce a byte, and `pump()` still
        // judges only once EOF and the exit status are both in.
        //
        // `isRunning` was raised in `start()`, before the environment hop —
        // raising it in the spawn continuation could re-raise it after a fast
        // process had already finished.
        let spawnGeneration = generation
        Task { [weak self] in
            // `OffPool.run`, not `Task.detached`: `run()` blocks on the
            // fork/exec (and on `ssh` for a remote context), and a blocking
            // call on the cooperative pool is the shape the P52 sweep exists
            // to catch. P58 moved `HermesProxyService`'s identical spawn and
            // left these three on the pool — round-6 lesson 3, the siblings.
            let spawnError: (any Error)? = await OffPool.run {
                do { try proc.run(); return nil } catch { return error }
            }
            guard let self else { return }
            guard self.generation == spawnGeneration else {
                // `stop()` retired this run while it was still spawning, so it
                // saw a nil `process`/`stdoutPipe` and could retire neither the
                // process nor its reader. Do both here: an uncleared
                // `readabilityHandler` keeps decoding this dead run's output
                // for as long as the pipe is open.
                outPipe.fileHandleForReading.readabilityHandler = nil
                if spawnError == nil {
                    proc.terminationHandler = nil
                    proc.terminate()
                    if self.context.isRemote { self.reapRemoteLogin(server: server) }
                }
                return
            }
            if let spawnError {
                self.isRunning = false
                self.runningServer = nil
                self.errorMessage = "Failed to start hermes: \(spawnError.localizedDescription)"
                self.logger.error("mcp login failed to start: \(spawnError.localizedDescription)")
                return
            }
            // A fast-exiting login (an unknown server name prints its refusal
            // and exits) can be FINISHED before the spawn continuation
            // resumes. `finish()` nils `process`/`stdoutPipe` precisely so a
            // later `stop()` does not spend two SSH round trips reaping a
            // process that has exited; re-publishing them here would hand
            // `stop()` a live-looking `process` and do exactly that.
            guard !self.didFinish else { return }
            self.process = proc
            self.stdoutPipe = outPipe
        }
    }

    /// The production `Process` for a login run.
    ///
    /// Same PYTHONUNBUFFERED reasoning as OAuthFlowController: without it
    /// Python block-buffers when stdout is a pipe, and the device prompt —
    /// the entire point of the sheet — arrives only once the process is done
    /// waiting, i.e. too late to be used.
    private func defaultProcess(
        _ args: [String], localEnvironment: [String: String]?
    ) -> Process {
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
        // Pre-resolved off the main actor by the caller (C10, P58); the
        // `?? [:]` arm is unreachable on the local branch this sits in.
        var env = localEnvironment ?? [:]
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env
        return proc
    }

    /// Terminate an in-flight login. Safe when nothing is running — the sheet
    /// calls this on dismiss so a device flow doesn't keep polling the token
    /// endpoint after the user walked away.
    func stop() {
        startTask?.cancel()
        startTask = nil
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
    /// (`tools/mcp_oauth_device.py:132-144` at `v2026.9.7`), writes nothing
    /// until it is done, and so never takes a SIGPIPE. It keeps hitting the
    /// provider's token endpoint until its own deadline —
    /// `min(expires_in, timeout)`, default 300 s (`:124-125`) — long after the
    /// user dismissed the sheet.
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
    /// What is left is an explicit best-effort reap over the same transport,
    /// scoped three ways so it can only ever signal this controller's own
    /// process:
    ///
    /// * **By owner.** `pkill` without `-u` matches every user on the box.
    ///   On a shared host, one person dismissing a login sheet would kill a
    ///   colleague's login to the same server. `-u` restricts to an
    ///   EFFECTIVE uid on both platforms Scarf reaches — `-u euid` on
    ///   macOS/BSD `pkill(1)`, `-u, --euid` on Linux procps — so the same
    ///   argv is correct on either, and the uid comes from an `id -u` on
    ///   the remote rather than a guess at the SSH username (`~/.ssh/config`
    ///   can rewrite it). If that probe fails there is no way to scope the
    ///   kill, and the reap is ABANDONED: leaving a polling loop to hit its
    ///   own 300 s deadline is strictly better than signalling a process
    ///   that may not be ours.
    /// * **By command line**, which must carry `mcp login` and end with this
    ///   server's name after the `--`, every ERE metacharacter in the name
    ///   escaped (`regexEscaped`).
    /// * **Away from the `bash -lc` wrapper**, for free, by that `$` anchor:
    ///   `SSHTransport.composedRemoteCommand` runs every token through
    ///   `remotePathArg`, which double-quotes UNCONDITIONALLY
    ///   (`SSHTransport.swift:303-322`), so the shell's own command line ends
    ///   `… "--" "github"` — a literal `"` after the name — while the
    ///   `hermes` it execs has had the quotes removed. Only the second one
    ///   matches. `MCPOAuthAndTransportP24Tests` pins that with the real
    ///   `grep -E`, because it is a property of ANOTHER file that this one
    ///   silently depends on.
    ///
    /// `pkill` may be absent (its exit code says so) — the reap is advisory,
    /// and its failure is logged, never surfaced: the login is already over
    /// as far as the user is concerned.
    private func reapRemoteLogin(server: String) {
        let xport = context.makeTransport()
        let pattern = Self.reapPattern(server: server)
        let logger = self.logger
        Task.detached {
            do {
                // C10: off the main actor, with a timeout, like every other
                // spawn Scarf makes.
                let whoami = try xport.runProcess(
                    executable: "id", args: ["-u"], stdin: nil, timeout: 10)
                let uid = whoami.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard whoami.exitCode == 0, !uid.isEmpty,
                      uid.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                    logger.info("remote mcp login reap skipped: could not resolve the remote uid")
                    return
                }
                let result = try xport.runProcess(
                    executable: "pkill", args: ["-u", uid, "-f", pattern], stdin: nil, timeout: 10)
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

    /// The `pkill -f` ERE for one server's login. Pure, so a test can assert
    /// what it does and does not match.
    nonisolated static func reapPattern(server: String) -> String {
        "mcp login .*-- " + regexEscaped(server) + "$"
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
