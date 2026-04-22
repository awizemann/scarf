import Foundation
import ScarfCore
import AppKit

/// Drives the Add Server sheet. Exposed state maps 1:1 to form fields, plus
/// a reachability test that runs `ssh host 'command -v hermes && ls .hermes/state.db'`
/// and surfaces stderr inline on failure.
@Observable
@MainActor
final class AddServerViewModel {
    /// Name shown in the server picker (defaults to host if the user leaves
    /// it blank).
    var displayName: String = ""
    var host: String = ""
    var user: String = ""
    var port: String = ""
    var identityFile: String = ""
    /// Override for `~/.hermes` on the remote. Empty = default.
    var remoteHome: String = ""

    var isTesting: Bool = false
    /// Outcome of the most recent Test Connection run. `nil` = not yet run.
    var testResult: TestResult?

    enum TestResult: Equatable {
        /// `suggestedRemoteHome` is non-nil when the probe didn't find
        /// state.db at the configured (or default) path but did find a
        /// `state.db` at one of the well-known alternates (e.g. a systemd
        /// install in `/var/lib/hermes/.hermes`). UI offers a one-click
        /// fill so the user doesn't have to know the convention.
        case success(hermesPath: String, dbFound: Bool, suggestedRemoteHome: String?)
        /// `command` is the full ssh invocation we attempted (so the user can
        /// paste it into Terminal to see what their shell does with it).
        /// `stderr` is whatever ssh / the remote shell wrote to stderr.
        case failure(message: String, stderr: String, command: String)
    }

    /// The config the form currently represents — built on demand, not
    /// persisted until the user clicks Save.
    var draftConfig: SSHConfig {
        SSHConfig(
            host: host.trimmingCharacters(in: .whitespaces),
            user: nonEmpty(user),
            port: Int(port),
            identityFile: nonEmpty(identityFile),
            remoteHome: nonEmpty(remoteHome),
            hermesBinaryHint: nil
        )
    }

    /// Hostname or alias is the only required field; everything else
    /// defaults to `~/.ssh/config` / ssh-agent.
    var canSave: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return host.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Identity file picker

    func pickIdentityFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose an SSH private key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Default to ~/.ssh so users land in the right place.
        if let sshDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .deletingLastPathComponent().appendingPathComponent(".ssh", isDirectory: true) {
            panel.directoryURL = sshDir
        }
        if panel.runModal() == .OK, let url = panel.url {
            identityFile = url.path
        }
    }

    // MARK: - Test Connection

    /// Run a single ssh round-trip to verify auth + discover the remote
    /// hermes binary. Populates `testResult` with either a success (so the
    /// user knows the binary was found and the DB is readable) or a
    /// failure with stderr for debugging.
    ///
    /// Uses `ssh -v` for the test probe so we capture the full handshake
    /// trace — even if auth fails before the remote shell starts, ssh's
    /// own diagnostic output gives the user (and us) something to act on.
    func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        let config = draftConfig
        let probe = TestConnectionProbe(config: config)
        testResult = await probe.run()
    }

    /// If the test succeeded, we prefer to save the probed binary path into
    /// `hermesBinaryHint` so subsequent calls don't need to re-resolve it.
    func configForSave() -> SSHConfig {
        var cfg = draftConfig
        if case .success(let path, _, _) = testResult {
            cfg.hermesBinaryHint = path
        }
        return cfg
    }

    // MARK: - Helpers

    private func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
