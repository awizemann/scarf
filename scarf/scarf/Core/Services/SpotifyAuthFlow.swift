import Foundation
import AppKit
import os
import ScarfCore

/// Drives `hermes auth spotify` for the Spotify skill (Hermes v2026.4.23).
///
/// Spotify uses OAuth 2.0 authorization-code flow with a local-callback
/// listener: Hermes prints a `https://accounts.spotify.com/authorize?...`
/// URL, the user approves in their browser, Spotify redirects back to a
/// local server Hermes spun up, Hermes catches the code, exchanges it for
/// a token, and writes the result to `~/.hermes/auth.json`.
///
/// The flow:
///
/// 1. Spawn hermes via `context.makeTransport().makeProcess(...)`.
/// 2. Stream stdout/stderr; regex-detect the auth URL on whatever line
///    Hermes prints it (we're permissive — match any `accounts.spotify.com/authorize`
///    so log-format changes between minor versions don't break us).
/// 3. Auto-open the URL in the default browser; transition to
///    `.waitingForApproval` so the sheet can show a manual fallback.
/// 4. On subprocess exit 0, poll `~/.hermes/auth.json` for
///    `providers.spotify.access_token`. The exit code alone isn't
///    proof — auth could fail mid-callback and exit 0 anyway.
/// 5. Surface clear errors for cancellation / missing binary / token
///    not landing.
///
/// Mirrors `NousAuthFlow` in shape so future "auth provider X" sheets
/// can lift the pattern without re-deriving the lifecycle handling.
@Observable
@MainActor
final class SpotifyAuthFlow {
    enum State: Equatable {
        case idle
        case starting
        case waitingForApproval(authorizeURL: URL)
        case verifying
        case success
        case failure(reason: String)

        var isWaitingForApproval: Bool {
            if case .waitingForApproval = self { return true }
            return false
        }
    }

    private(set) var state: State = .idle
    /// Accumulated stdout/stderr — surfaced in the failure UI for bug reports.
    private(set) var output: String = ""

    let context: ServerContext
    private let logger = Logger(subsystem: "com.scarf", category: "SpotifyAuthFlow")

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pollTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    /// The hop that resolves the login-shell environment before the local
    /// spawn (C10, round-6 P58 — the literal twin of the `NousAuthFlow.start`
    /// fix in `c93c2287`). Held so ``cancel()`` can stop a start that has not
    /// reached `proc.run()` yet, which would otherwise leave a process nobody
    /// owns.
    private var startTask: Task<Void, Never>?

    /// The two readers' hand-off buffers, one per pipe, plus the exit status.
    /// The verdict needs BOTH EOFs and the status — see ``pump()``.
    private var stdoutInbox = ProcessOutputInbox()
    private var stderrInbox = ProcessOutputInbox()
    private var pendingExit: Int32?
    private var didFinish = true
    /// Bumped on every `start()`/`cancel()`. A retired run's reader hops and
    /// termination hop land on a live main actor and must not touch the
    /// replacement run's state.
    private var generation: UInt64 = 0

    /// Test seam: build the subprocess instead of spawning `hermes auth
    /// spotify` through the transport. Nil in production.
    var makeAuthProcess: (@Sendable () -> Process)?

    /// Test seam: the pid of the in-flight child, or 0.
    var runningPIDForTesting: Int32 { process?.processIdentifier ?? 0 }

    /// Whether this flow is still holding a run's `Process` and pipes.
    ///
    /// The observable half of `releaseProcess()`: a run that ended — finished,
    /// cancelled, or never launched at all — must not be holding either. The
    /// launch-failure arm used to return with both still hooked up (round-4
    /// P43b), which is what `SpawnDisciplineP43Tests` watches here.
    var retainsRunForTesting: Bool {
        process != nil || stdoutPipe != nil || stderrPipe != nil
    }

    /// C10: every subprocess has a timeout, including one that is waiting on
    /// a human in a browser.
    ///
    /// The number is Hermes's own, not a guess. `hermes auth spotify` waits
    /// for the local OAuth callback with `timeout_seconds: float = 180.0`
    /// (`hermes_cli/auth_spotify.py:154`, passed at `:420` @ v2026.9.7) and
    /// then exchanges the code with a 20 s HTTP timeout (`:433`), raising
    /// `spotify_callback_timeout` (`:180`) if the user never approves. So a
    /// healthy run ALWAYS ends by itself inside ~200 s, and this ceiling is
    /// reached only when the child cannot report that — a wedged SSH channel
    /// to a remote host, a `hermes` stopped in the debugger, a callback
    /// server that took the port and then hung. Without it the sheet sits on
    /// its spinner forever with no way out but quitting Scarf.
    static let authTimeout: TimeInterval = 240

    init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Lifecycle

    /// Start the sign-in flow. Cancels any in-flight subprocess first.
    ///
    /// **C10 (round-6 P58).** The local branch needs
    /// `HermesFileService.enrichedEnvironment()`, whose backing
    /// `enrichedShellEnv` is a `static let` initialised by two `zsh` probes at
    /// 5 s + 3 s. A `static let` initialiser is a `swift_once`, so a
    /// main-actor reader arriving while the launch warm-up is still running
    /// BLOCKS on it — up to eight seconds of frozen window, on the click that
    /// opens the Spotify sheet. It is resolved off the pool first and the
    /// spawn happens back on the main actor with the value in hand. This is
    /// the same split `NousAuthFlow` got in `c93c2287`; this flow was its
    /// literal twin and was missed.
    ///
    /// A remote context pays nothing: it wraps the command in
    /// `env PYTHONUNBUFFERED=1 …` because ssh forwards no environment, and an
    /// injected `makeAuthProcess` (the tests') brings its own.
    func start() {
        cancel()
        output = ""
        state = .starting

        generation &+= 1
        let stdoutInbox = ProcessOutputInbox()
        let stderrInbox = ProcessOutputInbox()
        self.stdoutInbox = stdoutInbox
        self.stderrInbox = stderrInbox
        pendingExit = nil
        didFinish = false

        guard makeAuthProcess == nil, !context.isRemote else {
            launch(localEnvironment: nil, stdoutInbox: stdoutInbox, stderrInbox: stderrInbox)
            return
        }
        startTask = Task { [weak self] in
            let env = await OffPool.run { HermesFileService.enrichedEnvironment() }
            guard let self, !Task.isCancelled else { return }
            self.launch(localEnvironment: env, stdoutInbox: stdoutInbox, stderrInbox: stderrInbox)
        }
    }

    /// Spawn `hermes auth spotify`. `localEnvironment` is the pre-resolved
    /// login-shell environment for a local, non-injected run and `nil`
    /// otherwise — see ``start()``.
    private func launch(
        localEnvironment: [String: String]?,
        stdoutInbox: ProcessOutputInbox,
        stderrInbox: ProcessOutputInbox
    ) {
        let generation = self.generation

        let proc: Process
        if let makeAuthProcess {
            proc = makeAuthProcess()
        } else {
            proc = context.makeTransport().makeProcess(
                executable: context.paths.hermesBinary,
                args: ["auth", "spotify"]
            )
            if !context.isRemote {
                var env = localEnvironment ?? [:]
                // Force unbuffered Python stdout so the auth URL flushes
                // immediately. Same reasoning as NousAuthFlow.
                env["PYTHONUNBUFFERED"] = "1"
                proc.environment = env
            }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        self.process = proc
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        do {
            try proc.run()
        } catch {
            state = .failure(reason: "Couldn't start `hermes auth spotify`: \(error.localizedDescription)")
            // Nothing spawned, so nothing will ever reach EOF or report an
            // exit: this run is over here, and its pipes go with it. (On this
            // path the write ends really are still the parent's — Foundation
            // only closes its copies as part of a spawn that happened.)
            didFinish = true
            releaseProcess()
            return
        }

        // Stream both pipes into their own inbox. Empty `availableData` is
        // EOF: unhook there rather than waiting for `cancel()` (a handler left
        // installed on a closed descriptor keeps Foundation's reader alive,
        // and `handleTermination` — the other end of a successful run — never
        // calls `cancel()` at all), latch the EOF, and close the handle the
        // reader owns.
        //
        // **The text is sequenced where it is PRODUCED, not where it is
        // applied.** Every read hops to the main actor in its own independent
        // `Task`, and those hops are unordered relative to each other and to
        // the termination hop — which is how the old shape judged a run before
        // the chunk carrying its last stderr line had been applied at all.
        // Same `ProcessOutputInbox` + `markEOF` + `pump()` shape as
        // `MCPLoginController` and `OAuthFlowController` (P40); round-4 P43b.
        //
        // A CLOSURE with `[weak self]`, not a local `func`: a local func
        // captures `self` strongly, and this one is stored on the pipe that
        // `self` owns — a retain cycle that would outlive the sheet.
        //
        // A read can land mid-codepoint, so each pipe decodes through its own
        // `IncrementalUTF8Decoder` — a truncated tail used to drop the WHOLE
        // chunk, and the authorize URL is exactly the thing that must not
        // vanish because a glyph straddled a read.
        func makeHandler(inbox: ProcessOutputInbox) -> @Sendable (FileHandle) -> Void {
            let decoder = IncrementalUTF8Decoder()
            return { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    inbox.append(decoder.flush())
                    inbox.markEOF()
                    // The reader owns the READ end and closes it here, once
                    // its own read has returned — never the main actor while
                    // this handler may still be in flight.
                    try? handle.close()
                } else {
                    inbox.append(decoder.decode(data))
                }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.pump()
                }
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = makeHandler(inbox: stdoutInbox)
        stderrPipe.fileHandleForReading.readabilityHandler = makeHandler(inbox: stderrInbox)

        proc.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            Task { @MainActor [weak self] in
                // The readers are deliberately LEFT INSTALLED: the last line
                // a failing `hermes auth spotify` prints is written just
                // before it exits, and on the losing side of that race the
                // chunk carrying it has not been read yet. `pump()` judges
                // only once both EOFs and the status are in.
                guard let self, self.generation == generation else { return }
                self.pendingExit = code
                self.pump()
                self.scheduleDrainDeadline(generation: generation)
            }
        }

        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.authTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.process === proc else { return }
            switch self.state {
            case .success, .failure, .idle:
                return
            case .starting, .waitingForApproval, .verifying:
                self.logger.warning("hermes auth spotify passed its \(Int(Self.authTimeout))s deadline; stopping it")
                self.cancel()
                let minutes = Int(Self.authTimeout) / 60
                self.state = .failure(
                    reason: String(
                        localized: "Spotify sign-in didn't finish within \(minutes) minutes, so Scarf stopped it. Try again, or run `hermes auth spotify` in a terminal on the host.",
                        comment: "Failure shown when the hermes auth spotify subprocess passes Scarf's deadline. The argument is the deadline in whole minutes."
                    )
                )
            }
        }
    }

    /// Cancel the in-flight subprocess, if any. Idempotent.
    ///
    /// **Stopping is bounded and escalates.** This used to be a bare
    /// `terminate()`: a `hermes` wedged in an uninterruptible wait, or one
    /// that ignores SIGTERM, survived it — and the 240 s deadline path calls
    /// this, so the one arm that exists BECAUSE the child would not stop had
    /// no way to insist. The reap goes through `waitUntilExit(timeout:)`
    /// (SIGTERM → bounded poll → SIGKILL → bounded poll) on a detached task:
    /// the helper is synchronous, and the main actor is the one thread that
    /// must never block on a child (charter C10).
    ///
    /// **It no longer closes the READ ends.** A `readabilityHandler` can be
    /// running on the pipe's own queue at this moment, and closing a handle
    /// out from under it is the raise `ProcessTimeout.swift` documents. The
    /// reader closes the handle it drained, at EOF; anything still open when
    /// the last reference here is dropped is closed by the `Pipe`'s own
    /// deinit. Only the write ends — which nobody else touches — are closed.
    func cancel() {
        startTask?.cancel()
        startTask = nil
        pollTask?.cancel()
        pollTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        // Retire this run: a reader hop or a termination hop already queued
        // must not land on the next one's state.
        generation &+= 1
        didFinish = true
        pendingExit = nil
        if let p = process, p.isRunning {
            p.terminationHandler = nil
            Self.reapDetached(p)
        }
        releaseProcess()
    }

    /// Stop `proc` off the main actor, with the helper's SIGTERM → SIGKILL
    /// escalation. `nonisolated` so the synchronous wait inside never runs on
    /// the main actor (charter C10 / the P22 sweep).
    ///
    /// A THREAD, not `Task.detached`. P43c named this site as "right for its
    /// own purpose (getting off the MAIN actor) and wrong for" the
    /// cooperative-pool one — and it was both at once: `Task.detached` is the
    /// same cooperative pool the caller was on, so the `Thread.sleep` poll
    /// inside parked a pool thread for up to the budget plus two signal
    /// graces. Round-5 P48's widened `ProcessAsyncWait` sweep, which now
    /// reads `Task { … }` closures, is what surfaced it.
    private nonisolated static func reapDetached(_ proc: Process) {
        Thread.detachNewThread {
            // A budget, not a grace: the child is being stopped, so the only
            // question is whether it goes quietly. `waitUntilExit(timeout:)`
            // escalates to SIGKILL by itself when it does not.
            _ = proc.waitUntilExit(timeout: 0.5)
        }
    }

    /// Drop this run's process and pipes, on the success path as well as the
    /// cancelled one — a finished run used to keep both pipes and the
    /// `Process` alive for as long as the sheet's view model did.
    ///
    /// Read ends are NOT closed here; see `cancel()`.
    private func releaseProcess() {
        process?.terminationHandler = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        // The write ends are the caller's half. After a successful `run()`
        // Foundation has already closed the parent's copy (measured: a
        // 50-spawn /dev/fd count is flat with or without this), but on a
        // `run()` that threw they are still open and this is the release.
        try? stdoutPipe?.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// A process can exit while something else still holds the write end of
    /// its pipes — then EOF never arrives and the verdict, already knowable,
    /// would never be taken. After this grace the drain is declared over and
    /// the run is judged on what did arrive.
    private func scheduleDrainDeadline(generation: UInt64) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.generation == generation, !self.didFinish else { return }
            self.stdoutInbox.markEOF()
            self.stderrInbox.markEOF()
            self.pump()
        }
    }

    /// Apply everything the two readers have produced, then judge — but only
    /// once BOTH pipes have reported EOF and the process has reported its exit
    /// status. Any of the three can arrive first.
    private func pump() {
        let out = stdoutInbox.drain()
        let err = stderrInbox.drain()
        if !out.text.isEmpty { absorb(out.text) }
        if !err.text.isEmpty { absorb(err.text) }
        guard out.sawEOF, err.sawEOF, let code = pendingExit, !didFinish else { return }
        didFinish = true
        handleTermination(exitCode: code)
    }

    // MARK: - Output handling

    private func absorb(_ text: String) {
        output += text
        // Detect the OAuth authorize URL on first sight.
        if case .starting = state, let url = Self.detectAuthorizeURL(in: output) {
            state = .waitingForApproval(authorizeURL: url)
            NSWorkspace.shared.open(url)
        }
    }

    /// Match any `accounts.spotify.com/authorize` URL in the buffer.
    /// Permissive on purpose — log-format changes between Hermes minors
    /// shouldn't break us. Returns nil if no match found yet.
    nonisolated static func detectAuthorizeURL(in text: String) -> URL? {
        let pattern = #"https://accounts\.spotify\.com/authorize\?[^\s)\"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let urlRange = Range(match.range, in: text)
        else { return nil }
        return URL(string: String(text[urlRange]))
    }

    // MARK: - Termination

    private func handleTermination(exitCode: Int32) {
        deadlineTask?.cancel()
        deadlineTask = nil
        // Both pipes are at EOF by the time `pump` calls this, so the process
        // and its pipes have nothing left to give.
        releaseProcess()
        guard exitCode == 0 else {
            // Cancelled by us, or hermes returned non-zero. `waitingForApproval`
            // counts: a run that printed the authorize URL and then failed —
            // the user closed the browser tab, the callback port was taken —
            // exits non-zero from THAT state, and leaving it out left the
            // sheet spinning on a run that was already over.
            if state == .starting || state == .verifying || state.isWaitingForApproval {
                state = .failure(reason: "Spotify auth exited with status \(exitCode). Last log:\n\(Self.tail(output, lines: 6))")
            }
            return
        }
        // Verify the token actually landed in auth.json.
        state = .verifying
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let path = context.paths.authJSON
            let transport = context.makeTransport()
            // Three quick polls — auth.json is written synchronously by
            // hermes before exit, so this almost always lands on the
            // first read; the retries cover NFS / SFTP write barriers.
            for _ in 0..<3 {
                if Task.isCancelled { return }
                if Self.authJSONHasSpotifyToken(path: path, transport: transport) {
                    state = .success
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            state = .failure(reason: "Hermes exited cleanly but no Spotify token landed in \(path).")
        }
    }

    /// Return true when `auth.json` contains a non-empty
    /// `providers.spotify.access_token`. False on read failure, parse
    /// failure, or absent token — caller treats as "not signed in".
    nonisolated static func authJSONHasSpotifyToken(
        path: String,
        transport: any ServerTransport
    ) -> Bool {
        guard let data = try? transport.readFile(path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["providers"] as? [String: Any],
              let spotify = providers["spotify"] as? [String: Any],
              let token = spotify["access_token"] as? String,
              !token.isEmpty
        else { return false }
        return true
    }

    /// Last `lines` lines of a string buffer, used in failure messages.
    nonisolated static func tail(_ s: String, lines: Int) -> String {
        let parts = s.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = parts.suffix(lines)
        return tail.joined(separator: "\n")
    }
}
