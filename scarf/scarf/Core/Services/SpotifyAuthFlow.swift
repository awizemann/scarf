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
    func start() {
        cancel()
        output = ""
        state = .starting

        let proc = context.makeTransport().makeProcess(
            executable: context.paths.hermesBinary,
            args: ["auth", "spotify"]
        )
        if !context.isRemote {
            var env = HermesFileService.enrichedEnvironment()
            // Force unbuffered Python stdout so the auth URL flushes
            // immediately. Same reasoning as NousAuthFlow.
            env["PYTHONUNBUFFERED"] = "1"
            proc.environment = env
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
            return
        }

        // Stream both pipes into `output`; URL detection on every chunk.
        // Empty `availableData` is EOF. Unhook there rather than waiting for
        // `cancel()`: a handler left installed on a closed descriptor keeps
        // Foundation's reader alive and keeps this pipe's fd out of reach of
        // the close, and `handleTermination` — the other end of a successful
        // run — never calls `cancel()` at all. `NousAuthFlow:105-109` already
        // had this shape; these two were the pair that did not.
        func streamHandler(_ handle: FileHandle) {
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.absorb(text)
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = streamHandler
        stderrPipe.fileHandleForReading.readabilityHandler = streamHandler

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                self?.handleTermination(exitCode: terminated.terminationStatus)
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
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        try? stdoutPipe?.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
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
        guard exitCode == 0 else {
            // Cancelled by us, or hermes returned non-zero.
            if state == .starting || state == .verifying {
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
