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

    init(context: ServerContext = .local) {
        self.context = context
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
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?

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

        // Use the transport so OAuth works against remote contexts too:
        // local spawns hermes directly, remote rounds through ssh -T while
        // preserving stdin (for the auth-code prompt) and stdout (for the
        // URL parser).
        let proc = context.makeTransport().makeProcess(
            executable: context.paths.hermesBinary,
            args: args
        )
        if !context.isRemote {
            // Only enrich env locally — the remote ssh process gets the
            // remote login env naturally, and exporting our local API keys
            // into it would be wrong.
            proc.environment = HermesFileService.enrichedEnvironment()
        }

        let outPipe = Pipe()
        let inPipe = Pipe()
        // Merge stderr into stdout: hermes prints the URL + prompt to stdout,
        // but diagnostic messages can land on stderr; we want both interleaved
        // in display order.
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        proc.standardInput = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF — the peer closed its write end. Drop the handler so
                // Foundation doesn't keep calling us with empty reads.
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            // Hop onto the main actor to mutate observable state.
            Task { @MainActor [weak self] in
                self?.handleOutputChunk(chunk)
            }
        }

        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor [weak self] in
                outPipe.fileHandleForReading.readabilityHandler = nil
                self?.handleTermination(exitCode: code)
            }
        }

        do {
            try proc.run()
            process = proc
            stdinPipe = inPipe
            stdoutPipe = outPipe
            isRunning = true
        } catch {
            errorMessage = "Failed to start hermes: \(error.localizedDescription)"
            logger.error("Failed to start hermes: \(error.localizedDescription)")
        }
    }

    /// Terminate the in-flight process (if any). Safe to call when nothing is running.
    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
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
        // Hermes exits 0 even on "login did not return credentials" — detect
        // that failure marker explicitly so we don't report false success.
        let failureMarkers = [
            "did not return credentials",
            "Token exchange failed",
            "OAuth login failed",
            "HTTP Error"
        ]
        let outputFailed = failureMarkers.contains { output.localizedCaseInsensitiveContains($0) }
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
