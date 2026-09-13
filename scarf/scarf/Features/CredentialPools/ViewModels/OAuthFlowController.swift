import Foundation
import ScarfCore
import AppKit
import os

/// Drives the `hermes auth add <provider> --type oauth` flow via `Process` +
/// pipes instead of SwiftTerm. The embedded terminal approach turned out to
/// have two problems:
///
///   1. Python's `webbrowser.open` called from a subprocess doesn't reliably
///      open the user's browser — the macOS `open` command can fail silently
///      depending on how the parent app was launched.
///   2. Even when it works, users can't easily copy the URL from a terminal
///      emulator to click or share.
///
/// This controller runs hermes with `--no-browser`, captures stdout/stderr,
/// regex-extracts the authorization URL, and exposes it to the UI as a plain
/// string. The UI shows a real "Open in Browser" button (via NSWorkspace) and
/// a code input text field. Submitting writes the code + newline to hermes's
/// stdin pipe, which Python's `input()` reads normally — verified in shell
/// testing that hermes accepts piped stdin when a TTY isn't available.
///
/// Hermes exits 0 even on "login did not return credentials" failures, so we
/// detect success by scanning output for failure markers AND by letting the
/// calling VM reload `auth.json` to see whether a new credential actually
/// landed.
@Observable
@MainActor
final class OAuthFlowController {
    private let logger = Logger(subsystem: "com.scarf", category: "OAuthFlowController")
    let context: ServerContext

    init(context: ServerContext = .local, makeAuthProcess: ProcessFactory? = nil) {
        self.context = context
        self.makeAuthProcess = makeAuthProcess
    }


    // MARK: - Observable state

    /// Accumulated terminal output for display. Grows monotonically during
    /// the flow; cleared on `start(...)`.
    var output: String = ""

    /// Authorization URL extracted from hermes's output. Shown as a prominent
    /// "Open in Browser" button once detected.
    var authorizationURL: String?

    /// True once hermes has printed the "Authorization code:" prompt. Gates
    /// the code submit button so users can't submit too early.
    var awaitingCode: Bool = false

    /// True between `start(...)` and process termination.
    var isRunning: Bool = false

    /// Set when the process exits with a success signal (both zero exit AND
    /// no failure marker in output). The VM checks this + reloads auth.json.
    var succeeded: Bool = false

    /// Human-readable error message if start/submit failed mid-flow.
    var errorMessage: String?

    /// Fired when the process exits, with the raw exit code. Use this to
    /// trigger a UI reload or close the sheet.
    var onExit: ((Int32) -> Void)?

    // MARK: - Private state

    private var process: Process?
    /// The hop that resolves the login-shell environment before a LOCAL
    /// spawn (C10, round-6 P58). `enrichedEnvironment()` reads a `static let`
    /// whose initialiser is two `zsh` probes at 5 s + 3 s behind a
    /// `swift_once`, so a main-actor reader arriving during the launch
    /// warm-up blocks the window for up to eight seconds — on the click that
    /// opens this sheet. Held so `stop()` can retire a start that has not
    /// reached `proc.run()` yet.
    private var startTask: Task<Void, Never>?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    /// Everything the reader has decoded but the main actor has not consumed
    /// yet, plus whether the reader has seen EOF. ONE PER RUN — see
    /// ``ProcessOutputInbox``.
    private var inbox = ProcessOutputInbox()
    /// The exit status, once the termination handler has reported it. Nil
    /// until then, and the verdict waits for BOTH this and EOF.
    private var pendingExit: Int32?
    /// Set by `handleTermination`, so a late pump can't judge the same run
    /// twice.
    private var didFinish = false
    /// Bumped by `stop()` (and so by every `start()`, which calls it first).
    /// Output and exits from a retired run are dropped rather than attributed
    /// to the run that replaced it.
    private var generation: UInt64 = 0

    /// Builds the `Process` for one OAuth run, given the `hermes` argv.
    ///
    /// Injectable for the same reason ``MCPLoginController/ProcessFactory``
    /// is: the interesting behaviour here is the drain/termination race, and
    /// there is no way to provoke a specific interleaving through a real
    /// `hermes`. Production always uses `defaultProcess(_:)`; the caller must
    /// NOT set `standardOutput`/`standardError`/`standardInput` — `start`
    /// owns the pipes.
    typealias ProcessFactory = @MainActor (_ args: [String]) -> Process

    private let makeAuthProcess: ProcessFactory?

    // MARK: - Lifecycle

    /// Start the OAuth flow. Any prior in-flight flow is terminated first.
    func start(provider: String, label: String) {
        stop()

        output = ""
        authorizationURL = nil
        awaitingCode = false
        succeeded = false
        errorMessage = nil

        // Pass --no-browser so hermes doesn't try (and potentially fail) to
        // launch the browser itself — we do it explicitly with the button.
        var args = ["auth", "add", provider, "--type", "oauth", "--no-browser"]
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        if !trimmedLabel.isEmpty {
            args += ["--label", trimmedLabel]
        }

        // One inbox per run (``ProcessOutputInbox``): a stale reader from a
        // retired run must not be able to write into — or `markEOF` — the
        // buffer this run's verdict is taken from.
        let inbox = ProcessOutputInbox()
        self.inbox = inbox
        pendingExit = nil
        didFinish = false

        // `isRunning` is raised HERE, before the environment hop, not in
        // `launch`: its whole point is that the sheet shows the run as live
        // FROM THE CLICK, and the hop can take a second on a cold
        // `swift_once` (round-6 P58). `stop()` lowers it.
        isRunning = true

        // C10: resolve the login-shell environment OFF the main actor
        // before spawning — see ``startTask``. An injected process or a
        // remote context needs none of it (ssh forwards no environment, so
        // the remote branch wraps the command in `env PYTHONUNBUFFERED=1 …`).
        guard makeAuthProcess == nil, !context.isRemote else {
            launch(args: args, inbox: inbox, localEnvironment: nil)
            return
        }
        startTask = Task { [weak self] in
            let env = await OffPool.run { HermesFileService.enrichedEnvironment() }
            guard let self, !Task.isCancelled else { return }
            self.launch(args: args, inbox: inbox, localEnvironment: env)
        }
    }

    /// Build and spawn the run. `localEnvironment` is the pre-resolved
    /// login-shell environment for a local, non-injected run; `nil` otherwise.
    private func launch(
        args: [String],
        inbox: ProcessOutputInbox,
        localEnvironment: [String: String]?
    ) {
        let proc = makeAuthProcess?(args)
            ?? defaultProcess(args, localEnvironment: localEnvironment)

        let outPipe = Pipe()
        let inPipe = Pipe()
        // Merge stderr into stdout: hermes prints the URL + prompt to stdout,
        // but diagnostic messages can land on stderr; we want both interleaved
        // in display order.
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        proc.standardInput = inPipe

        // A read can land mid-codepoint: `availableData` is a byte count, not
        // a character boundary, and `String(data:encoding:.utf8)` returns nil
        // for a truncated sequence — which used to drop the WHOLE chunk. The
        // authorization URL disappearing because a multi-byte glyph straddled
        // a read is not recoverable by the user. Reads are serialised on the
        // pipe's own queue, so the decoder needs no lock; the decoded text
        // goes into `inbox`, which does have one.
        let decoder = IncrementalUTF8Decoder()
        let generation = self.generation
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                // EOF. Anything the decoder still holds is a TRUNCATED final
                // sequence — there will be no next read to complete it, so
                // flush it lossily rather than dropping the process's last
                // bytes, which can be the whole reason a failure was reported
                // the way it was.
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
                // INSTALLED here. Clearing it on termination is the bug
                // `t-bd119897` reported: `hermes auth add --type oauth` writes
                // `login did not return credentials` / `Token exchange failed`
                // just before it exits, and on the losing side of that race
                // the chunk carrying it was never read — so `succeeded`, which
                // is `exitCode == 0 && !outputFailed`, failed toward TRUE. The
                // pipe stays live until it reports EOF; `pump` judges only
                // once BOTH signals are in.
                guard let self, self.generation == generation else { return }
                self.pendingExit = code
                self.pump()
                self.scheduleDrainDeadline(generation: generation)
            }
        }

        // C10: `Process.run()` is a fork/exec, and on a remote context it is
        // an `ssh` spawn — neither belongs on the main actor. Both handlers
        // are installed ABOVE, before the process can produce a byte, so the
        // EOF-then-judge sequencing is untouched.
        //
        // The pipes are published SYNCHRONOUSLY: `submitCode` needs
        // `stdinPipe` the moment the prompt appears, and the prompt can only
        // appear after the spawn.
        stdinPipe = inPipe
        stdoutPipe = outPipe
        // `isRunning` was raised in `start()`, before the environment hop.
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
                // saw a nil `process` and could retire neither the process nor
                // its reader. Do both here: an uncleared `readabilityHandler`
                // keeps decoding this dead run's output while the pipe is open.
                outPipe.fileHandleForReading.readabilityHandler = nil
                if spawnError == nil {
                    proc.terminationHandler = nil
                    proc.terminate()
                }
                return
            }
            if let spawnError {
                self.isRunning = false
                self.process = nil
                self.stdinPipe = nil
                self.stdoutPipe = nil
                self.errorMessage = "Failed to start hermes: \(spawnError.localizedDescription)"
                self.logger.error("Failed to start hermes: \(spawnError.localizedDescription)")
                return
            }
            // A fast-exiting run can be FINISHED before this continuation
            // resumes; `handleTermination` nils `process` precisely so a later
            // `stop()` does not terminate a process that has exited.
            guard !self.didFinish else { return }
            self.process = proc
        }
    }

    /// The production `Process` for one OAuth run.
    ///
    /// PYTHONUNBUFFERED forces line-buffered Python stdout so the URL banner
    /// reaches us before `input("Authorization code: ")` blocks. PKCE
    /// *usually* recovers because `input()` flushes, but certain providers
    /// print preamble lines AFTER the prompt that we still want streamed in
    /// real time. Local: set on `proc.environment`. Remote: ssh doesn't
    /// forward arbitrary env vars without `SendEnv` configured, so wrap the
    /// command in `env PYTHONUNBUFFERED=1 …` to inject it on the remote side.
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

    /// A process can exit while something else still holds the write end of
    /// the pipe (the browser helper `webbrowser.open` spawned, say), and then
    /// EOF never arrives. Waiting for the reader is right; waiting forever is
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
        if !text.isEmpty { handleOutputChunk(text) }
        guard sawEOF, let code = pendingExit, !didFinish else { return }
        didFinish = true
        handleTermination(exitCode: code)
    }

    /// Terminate the in-flight process (if any). Safe to call when nothing is running.
    func stop() {
        startTask?.cancel()
        startTask = nil
        // Retire this run BEFORE terminating it: `terminate()` fires the
        // termination handler asynchronously, and without the generation bump
        // (and without clearing the handler on the process itself) run A's
        // SIGTERM exit would land on run B and mark the retried flow failed.
        generation &+= 1
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        isRunning = false
        awaitingCode = false
    }

    /// Send the authorization code to hermes's stdin. Called when the user
    /// taps "Submit" in the sheet's code input field.
    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Authorization code is empty"
            return
        }
        guard let stdinPipe else {
            errorMessage = "Process is no longer accepting input"
            return
        }
        let payload = trimmed + "\n"
        guard let data = payload.data(using: .utf8) else {
            errorMessage = "Could not encode code"
            return
        }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            // After writing, we don't close stdin — hermes might prompt again
            // on failure. Instead we flip `awaitingCode` off so the UI can
            // dim the submit button until another prompt appears.
            awaitingCode = false
        } catch {
            errorMessage = "Failed to send code: \(error.localizedDescription)"
        }
    }

    /// Explicitly open the detected authorization URL in the default browser.
    /// Does nothing if no URL has been detected yet.
    func openURLInBrowser() {
        guard let url = authorizationURL, let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
    }

    // MARK: - Output handling

    private func handleOutputChunk(_ chunk: String) {
        output += chunk

        if authorizationURL == nil, let url = Self.extractAuthURL(from: output) {
            authorizationURL = url
            // Auto-open the browser on first detection, since that's what a
            // well-behaved hermes would have done. We keep the manual button
            // available for retries / copy-paste.
            if let parsed = URL(string: url) {
                NSWorkspace.shared.open(parsed)
            }
        }

        // The prompt may arrive in the same chunk as the URL. Checking
        // cumulative output (rather than just this chunk) is safer.
        if !awaitingCode, output.contains("Authorization code:") {
            awaitingCode = true
        }
    }

    private func handleTermination(exitCode: Int32) {
        isRunning = false
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        // Nothing can read stdin any more; `submitCode` says so rather than
        // writing into a pipe whose reader is gone.
        stdinPipe = nil
        awaitingCode = false
        let outputFailed = Self.outputSaysFailed(output)
        succeeded = exitCode == 0 && !outputFailed
        if !succeeded, errorMessage == nil {
            if outputFailed {
                errorMessage = "OAuth did not complete — check the output above for details"
            } else if exitCode != 0 {
                errorMessage = "hermes exited with code \(exitCode)"
            }
        }
        onExit?(exitCode)
    }

    // MARK: - The failure verdict

    /// The refusal lines this flow's emitter prints at **column 0**, matched
    /// with `hasPrefix` on ``HermesCLIVerdict/unglyphed(_:)`` rather than as
    /// free substrings anywhere in the blob.
    ///
    /// The argv is `auth add <provider> --type oauth --no-browser [--label …]`
    /// (see ``start(provider:label:)``), which `auth_command`
    /// (`hermes_cli/auth_commands.py:766-771` @ v2026.9.7) routes to
    /// `auth_add_command` (`:333`) → `_add_credential` (`:361`) →
    /// `_OAUTH_ADD_SPECS[provider].login`. For the default Anthropic provider
    /// that is `_anthropic_oauth_login` (`:181-186`) →
    /// `agent/anthropic_credentials.py`'s `run_hermes_oauth_login_pure`, whose
    /// three refusal lines are all bare `print()`s at column 0:
    ///
    /// | line | printed |
    /// | --- | --- |
    /// | `anthropic_credentials.py:546` | `No code entered.` |
    /// | `:560` | `Token exchange failed: {exc}` |
    /// | `:563` | `No access token in response.` |
    ///
    /// Each returns `None`, and the caller then raises
    /// `SystemExit("Anthropic OAuth login did not return credentials.")`
    /// (`auth_commands.py:185`) — exit 1. So the exit code already covers
    /// every one of them; these markers exist to put Hermes's own reason in
    /// the banner instead of "hermes exited with code 1".
    nonisolated static let anchoredFailureMarkers = [
        "Token exchange failed",
        "No code entered.",
        "No access token in response.",
    ]

    /// The one marker that is genuinely MID-LINE, and why.
    ///
    /// `SystemExit`'s message is printed verbatim by the interpreter, and the
    /// sentence leads with the provider's display name —
    /// `Anthropic OAuth login did not return credentials.`
    /// (`hermes_cli/auth_commands.py:185`). The stable half is the tail, so
    /// anchoring it would match nothing. It stays a substring.
    ///
    /// Two markers were retired here (P40b). `HTTP Error` only ever reaches
    /// the output interpolated INTO `Token exchange failed: {exc}` —
    /// `_post_oauth_token` raises `urllib`'s `HTTPError`, whose `str` is
    /// `HTTP Error 400: Bad Request` — so the anchored marker above already
    /// catches it, while as a bare case-insensitive substring it would match
    /// any provider page or scan text quoted into the log. `OAuth login
    /// failed` has exactly one emitter at the tag, `hermes_cli/setup_tts.py:105`
    /// (`xAI Grok OAuth login failed: {exc}`), which is the TTS setup wizard
    /// and not on this argv at all.
    nonisolated static let substringFailureMarkers = [
        "did not return credentials",
    ]

    /// True when the run PRINTED a refusal. Line-scoped and case-SENSITIVE:
    /// Hermes's spelling is fixed, and `localizedCaseInsensitiveContains` over
    /// the whole blob matched these phrases wherever they appeared — including
    /// inside the provider's own HTML error page, which this flow echoes.
    nonisolated static func outputSaysFailed(_ output: String) -> Bool {
        let lines = HermesCLIVerdict.significantLines(output)
        return lines.contains { line in
            if substringFailureMarkers.contains(where: { line.contains($0) }) { return true }
            let head = HermesCLIVerdict.unglyphed(line)
            return anchoredFailureMarkers.contains { head.hasPrefix($0) }
        }
    }

    // MARK: - URL extraction

    /// Extract the OAuth authorization URL from hermes's output. Hermes prints
    /// it on its own line in a Rich-rendered box; we want a plain https URL
    /// that looks like a provider OAuth endpoint.
    ///
    /// Priority order:
    ///   1. URLs containing `client_id=` — real OAuth auth URLs always have this.
    ///   2. URLs containing `/authorize` — fallback for providers that don't
    ///      include client_id in the query (unusual but possible).
    ///   3. URLs containing `/oauth/` — last resort.
    ///
    /// Docs URLs and generic callback URLs are filtered out by these checks.
    nonisolated static func extractAuthURL(from text: String) -> String? {
        let pattern = #"https://[^\s\)\]\"'`<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let urls: [String] = regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
        // Prefer the strongest signal so we don't accidentally surface the
        // redirect callback URL when both appear unencoded in output.
        if let url = urls.first(where: { $0.contains("client_id=") }) { return url }
        if let url = urls.first(where: { $0.contains("/authorize") }) { return url }
        if let url = urls.first(where: { $0.contains("/oauth/") }) { return url }
        return nil
    }
}
