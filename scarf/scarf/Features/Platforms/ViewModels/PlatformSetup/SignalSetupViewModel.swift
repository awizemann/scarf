import Foundation
import ScarfCore

/// Signal setup. Users must install `signal-cli` externally (needs Java), link
/// their account via `signal-cli link -n ...`, and run a daemon on an HTTP port
/// that hermes talks to. We expose an embedded terminal for both the link and
/// daemon commands.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/signal
@Observable
@MainActor
final class SignalSetupViewModel: PlatformSetupForm {
    let context: ServerContext
    /// C10 test seam — nil in production. See ``PlatformSetupForm``.
    let cliRunner: HermesCLIRunner?
    /// Load/save in-flight flags owned by ``PlatformSetupForm``.
    var isLoading = false
    var isSaving = false
    init(context: ServerContext = .local, cliRunner: HermesCLIRunner? = nil) {
        self.context = context
        self.cliRunner = cliRunner
    }

    var httpURL: String = "http://127.0.0.1:8080"
    var account: String = ""            // E.164 phone, e.g. +15551234567
    var allowedUsers: String = ""
    var groupAllowedUsers: String = ""
    var homeChannel: String = ""
    var allowAllUsers: Bool = false
    /// Hermes v0.15 — `platforms.signal.extra.require_mention`. Group-only:
    /// in group chats, only respond when @mentioned.
    var requireMention: Bool = false

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false

    let terminalController = EmbeddedSetupTerminalController()
    var signalCLIInstalled: Bool = false
    var activeTask: SignalTerminalTask = .none

    enum SignalTerminalTask: Equatable {
        case none
        case link
        case daemon
    }

    /// Off the main actor (C10) — see ``PlatformSetupForm``.
    func load() {
        loadSnapshot { [weak self] snapshot in
            guard let self else { return }
            let env = snapshot.env
            httpURL = env["SIGNAL_HTTP_URL"] ?? "http://127.0.0.1:8080"
            account = env["SIGNAL_ACCOUNT"] ?? ""
            allowedUsers = env["SIGNAL_ALLOWED_USERS"] ?? ""
            groupAllowedUsers = env["SIGNAL_GROUP_ALLOWED_USERS"] ?? ""
            homeChannel = env["SIGNAL_HOME_CHANNEL"] ?? ""
            allowAllUsers = PlatformSetupHelpers.parseEnvBool(env["SIGNAL_ALLOW_ALL_USERS"])
            if let cfg = snapshot.config?.signal { requireMention = cfg.requireMention }
            signalCLIInstalled = Self.detectSignalCLI()
        }
    }

    /// Best-effort `signal-cli` binary lookup on the login-shell PATH.
    private static func detectSignalCLI() -> Bool {
        let env = HermesFileService.enrichedEnvironment()
        let paths = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in paths {
            if FileManager.default.isExecutableFile(atPath: dir + "/signal-cli") {
                return true
            }
        }
        return false
    }

    func save() {
        let envPairs: [String: String] = [
            "SIGNAL_HTTP_URL": httpURL,
            "SIGNAL_ACCOUNT": account,
            "SIGNAL_ALLOWED_USERS": allowAllUsers ? "" : allowedUsers,
            "SIGNAL_GROUP_ALLOWED_USERS": groupAllowedUsers,
            "SIGNAL_HOME_CHANNEL": homeChannel,
            "SIGNAL_ALLOW_ALL_USERS": allowAllUsers ? "true" : ""
        ]
        let configKV: [String: String] = [
            "platforms.signal.extra.require_mention": PlatformSetupHelpers.envBool(requireMention)
        ]
        commitSave(envPairs: envPairs, configKV: configKV)
    }

    /// Run `signal-cli link -n HermesAgent` to generate a QR code.
    func startLink() {
        guard signalCLIInstalled else {
            showSaveFailure(String(localized: "signal-cli not found on PATH — install it first"))
            return
        }
        activeTask = .link
        terminalController.onExit = { [weak self] _ in
            self?.activeTask = .none
            self?.applySaveOutcome(.success(String(localized: "Link step exited — save credentials and start the daemon next")))
        }
        terminalController.start(executable: "/usr/bin/env", arguments: ["signal-cli", "link", "-n", "HermesAgent"])
    }

    /// Run the signal-cli daemon. Users can stop it by closing the panel.
    func startDaemon() {
        guard !account.isEmpty else {
            showSaveFailure(String(localized: "Enter your Signal account (E.164 format) first"))
            return
        }
        guard signalCLIInstalled else {
            showSaveFailure(String(localized: "signal-cli not found on PATH"))
            return
        }
        activeTask = .daemon
        let bind = httpURL.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
        terminalController.onExit = { [weak self] _ in
            self?.activeTask = .none
        }
        terminalController.start(
            executable: "/usr/bin/env",
            arguments: ["signal-cli", "--account", account, "daemon", "--http", bind]
        )
    }

    func stopTerminal() {
        terminalController.stop()
        activeTask = .none
    }
}
