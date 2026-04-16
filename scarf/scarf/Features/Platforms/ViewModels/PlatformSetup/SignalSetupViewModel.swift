import Foundation

/// Signal setup. Users must install `signal-cli` externally (needs Java), link
/// their account via `signal-cli link -n ...`, and run a daemon on an HTTP port
/// that hermes talks to. We expose an embedded terminal for both the link and
/// daemon commands.
///
/// Field reference: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/signal
@Observable
@MainActor
final class SignalSetupViewModel {
    var httpURL: String = "http://127.0.0.1:8080"
    var account: String = ""            // E.164 phone, e.g. +15551234567
    var allowedUsers: String = ""
    var groupAllowedUsers: String = ""
    var homeChannel: String = ""
    var allowAllUsers: Bool = false

    var message: String?

    let terminalController = EmbeddedSetupTerminalController()
    var signalCLIInstalled: Bool = false
    var activeTask: SignalTerminalTask = .none

    enum SignalTerminalTask: Equatable {
        case none
        case link
        case daemon
    }

    func load() {
        let env = HermesEnvService().load()
        httpURL = env["SIGNAL_HTTP_URL"] ?? "http://127.0.0.1:8080"
        account = env["SIGNAL_ACCOUNT"] ?? ""
        allowedUsers = env["SIGNAL_ALLOWED_USERS"] ?? ""
        groupAllowedUsers = env["SIGNAL_GROUP_ALLOWED_USERS"] ?? ""
        homeChannel = env["SIGNAL_HOME_CHANNEL"] ?? ""
        allowAllUsers = PlatformSetupHelpers.parseEnvBool(env["SIGNAL_ALLOW_ALL_USERS"])
        signalCLIInstalled = Self.detectSignalCLI()
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
        message = PlatformSetupHelpers.saveForm(envPairs: envPairs, configKV: [:])
        clearMessageAfterDelay()
    }

    /// Run `signal-cli link -n HermesAgent` to generate a QR code.
    func startLink() {
        guard signalCLIInstalled else {
            message = "signal-cli not found on PATH — install it first"
            clearMessageAfterDelay()
            return
        }
        activeTask = .link
        terminalController.onExit = { [weak self] _ in
            self?.activeTask = .none
            self?.message = "Link step exited — save credentials and start the daemon next"
            self?.clearMessageAfterDelay()
        }
        terminalController.start(executable: "/usr/bin/env", arguments: ["signal-cli", "link", "-n", "HermesAgent"])
    }

    /// Run the signal-cli daemon. Users can stop it by closing the panel.
    func startDaemon() {
        guard !account.isEmpty else {
            message = "Enter your Signal account (E.164 format) first"
            clearMessageAfterDelay()
            return
        }
        guard signalCLIInstalled else {
            message = "signal-cli not found on PATH"
            clearMessageAfterDelay()
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

    private func clearMessageAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.message = nil
        }
    }
}
