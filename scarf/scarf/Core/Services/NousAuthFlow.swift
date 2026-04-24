import Foundation
import AppKit
import os

/// Drives `hermes auth add nous --no-browser` for Nous Portal sign-in.
///
/// Nous uses OAuth 2.0 device-code flow, not PKCE. Hermes prints the
/// verification URL + user code to stdout, then long-polls the token
/// endpoint every ~1s until the user approves in their browser (or the
/// device code expires, currently 15 minutes).
///
/// The controller:
///
/// 1. Spawns hermes via `context.makeTransport().makeProcess(...)`.
/// 2. Streams stdout, regex-extracts the `verification_uri_complete` and
///    `user_code` from the lines hermes prints (auth.py:3282-3286).
/// 3. Auto-opens the verification URL in the default browser and
///    transitions to `.waitingForApproval` so the sheet can show the code.
/// 4. On subprocess exit, confirms success by re-reading `auth.json` via
///    `NousSubscriptionService` — hermes exit 0 alone isn't enough, we want
///    to see `providers.nous.access_token` actually landed.
/// 5. Detects the `subscription_required` failure (auth.py:3347-3356) and
///    surfaces the billing URL so the sheet can offer a Subscribe link.
///
/// The parser functions are `nonisolated static` so tests can feed fixture
/// buffers without standing up a real subprocess.
@Observable
@MainActor
final class NousAuthFlow {
    enum State: Equatable {
        case idle
        case starting
        case waitingForApproval(userCode: String, verificationURL: URL)
        case success
        case failure(reason: String, billingURL: URL?)
    }

    private(set) var state: State = .idle
    /// Accumulated subprocess output. Surfaced in the failure UI so the user
    /// can copy the tail for bug reports.
    private(set) var output: String = ""

    let context: ServerContext
    private let subscriptionService: NousSubscriptionService
    private let logger = Logger(subsystem: "com.scarf", category: "NousAuthFlow")

    private var process: Process?
    private var stdoutPipe: Pipe?

    init(context: ServerContext = .local) {
        self.context = context
        self.subscriptionService = NousSubscriptionService(context: context)
    }

    // MARK: - Lifecycle

    /// Start the sign-in flow. Any in-flight subprocess is terminated first.
    /// Safe to call repeatedly (e.g. user hits "Try again").
    func start() {
        cancel()
        output = ""
        state = .starting

        let proc = context.makeTransport().makeProcess(
            executable: context.paths.hermesBinary,
            args: ["auth", "add", "nous", "--no-browser"]
        )
        if !context.isRemote {
            // Only enrich env locally — remote ssh gets the remote login env
            // naturally, and exporting our local keys into it would be wrong.
            var env = HermesFileService.enrichedEnvironment()
            // Python block-buffers stdout when it's a pipe (not a TTY). The
            // device-code flow prints the verification URL + user code, then
            // enters a ~15-minute polling loop that never hits `input()` —
            // so nothing flushes and our readability handler never sees the
            // output. Users see the sheet spinning forever while hermes is
            // actually waiting for approval.
            //
            // PKCE doesn't have this problem because `input("Authorization
            // code: ")` flushes stdout before blocking, which is why
            // OAuthFlowController works without this setting.
            //
            // PYTHONUNBUFFERED forces line-buffered stdout for the whole
            // subprocess — tiny perf cost, huge UX win for device-code.
            env["PYTHONUNBUFFERED"] = "1"
            proc.environment = env
        }

        let outPipe = Pipe()
        // Merge stderr into stdout — hermes prints the device-code block to
        // stdout but may emit diagnostics on stderr; we want them interleaved
        // in display order so the failure-tail UI reads naturally.
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(data: data, encoding: .utf8) ?? ""
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
            stdoutPipe = outPipe
        } catch {
            logger.error("failed to spawn hermes: \(error.localizedDescription, privacy: .public)")
            state = .failure(
                reason: "Failed to start hermes: \(error.localizedDescription)",
                billingURL: nil
            )
        }
    }

    /// Terminate the in-flight subprocess. Idempotent. Does NOT clear state —
    /// the sheet dismisses on cancel via its own binding, and re-opening
    /// calls `start()` which does a fresh reset.
    func cancel() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
    }

    // MARK: - Output handling

    private func handleOutputChunk(_ chunk: String) {
        output += chunk
        // Only transition into waiting while we're still in .starting — once
        // we've already emitted the URL + code, subsequent "Waiting for
        // approval..." noise shouldn't re-fire NSWorkspace.open.
        guard case .starting = state else { return }
        if let result = Self.parseDeviceCode(from: output) {
            state = .waitingForApproval(
                userCode: result.userCode,
                verificationURL: result.verificationURL
            )
            NSWorkspace.shared.open(result.verificationURL)
        }
    }

    private func handleTermination(exitCode: Int32) {
        // Subscription-required is a specific failure path that hermes
        // signals both via an exit code and a unique billing-URL message.
        // It overrides other checks because we want the Subscribe affordance
        // in the UI regardless of exit code.
        if let billing = Self.parseSubscriptionRequired(from: output) {
            state = .failure(
                reason: "Your Nous Portal account does not have an active subscription.",
                billingURL: billing
            )
            return
        }
        if exitCode == 0 {
            // Hermes claims success. Confirm by reading auth.json — the
            // authoritative signal is that providers.nous has an access token
            // AND active_provider flipped to nous. Anything short of that is
            // a silent failure on the hermes side.
            let sub = subscriptionService.loadState()
            if sub.subscribed {
                state = .success
            } else if sub.present {
                state = .failure(
                    reason: "Signed in, but Nous isn't the active provider yet. Run `hermes model` and pick Nous Portal.",
                    billingURL: nil
                )
            } else {
                state = .failure(
                    reason: "Sign-in finished without writing credentials. Try again, or run `hermes auth add nous` in a terminal to see full diagnostics.",
                    billingURL: nil
                )
            }
        } else {
            let tail = Self.lastLines(of: output, count: 8)
            state = .failure(
                reason: tail.isEmpty
                    ? "hermes exited with code \(exitCode)"
                    : tail,
                billingURL: nil
            )
        }
    }

    // MARK: - Parsers (pure, testable)

    struct DeviceCodeResult: Equatable {
        let verificationURL: URL
        let userCode: String
    }

    /// Extract the device-code verification URL and user code from hermes's
    /// output. Anchored on the exact shape hermes prints (auth.py:3282-3286):
    ///
    ///     To continue:
    ///       1. Open: https://portal.nousresearch.com/device/XXXX-XXXX
    ///       2. If prompted, enter code: XXXX-XXXX
    ///
    /// Returns nil when either line is missing — the sheet stays on the
    /// `.starting` spinner until both are captured.
    nonisolated static func parseDeviceCode(from text: String) -> DeviceCodeResult? {
        let urlPattern = #"^\s*1\.\s*Open:\s*(https?://\S+)\s*$"#
        let codePattern = #"^\s*2\.\s*If prompted, enter code:\s*(\S+)\s*$"#
        guard
            let urlString = firstCapture(in: text, pattern: urlPattern),
            let userCode = firstCapture(in: text, pattern: codePattern),
            let url = URL(string: urlString)
        else {
            return nil
        }
        return DeviceCodeResult(verificationURL: url, userCode: userCode)
    }

    /// Detect the subscription-required failure and extract the billing URL
    /// hermes prints (auth.py:3347-3356). Scarf shows a "Subscribe" button
    /// linking to this URL so the user can resolve the blocker without
    /// hunting through logs.
    nonisolated static func parseSubscriptionRequired(from text: String) -> URL? {
        guard text.contains("Your Nous Portal account does not have an active subscription") else {
            return nil
        }
        guard
            let raw = firstCapture(in: text, pattern: #"Subscribe here:\s*(https?://\S+)"#),
            let url = URL(string: raw)
        else {
            return nil
        }
        return url
    }

    private nonisolated static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges >= 2,
            let r = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[r])
    }

    private nonisolated static func lastLines(of text: String, count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
