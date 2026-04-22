import Foundation

/// Connection-probe contract used by the iOS onboarding flow. The real
/// implementation lives in `ScarfIOS/CitadelSSHService` and uses
/// Citadel to perform a single SSH exec; tests use a mock that
/// scripts success / failure.
///
/// Kept in ScarfCore (not ScarfIOS) so `OnboardingViewModel` can be
/// constructed and exercised by tests on any platform — Linux CI can
/// verify the onboarding state-machine without an SSH server or the
/// iOS Keychain.
public protocol SSHConnectionTester: Sendable {
    /// Open an SSH session to `(config, key)` and run a no-op command
    /// (`echo ok`). Returns normally on success. Throws
    /// `SSHConnectionTestError` with a user-presentable reason
    /// otherwise.
    ///
    /// Implementations should apply a short connection timeout (~10s)
    /// — a slow remote shouldn't hang the onboarding UI.
    func testConnection(
        config: IOSServerConfig,
        key: SSHKeyBundle
    ) async throws
}

public enum SSHConnectionTestError: Error, LocalizedError {
    case hostUnreachable(host: String, underlying: String)
    case authenticationFailed(host: String, detail: String)
    case hostKeyMismatch(host: String, detail: String)
    case commandFailed(exitCode: Int, stderr: String)
    case timeout(seconds: TimeInterval)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .hostUnreachable(let host, let msg):
            return "Can't reach \(host): \(msg)"
        case .authenticationFailed(let host, let detail):
            return "SSH authentication to \(host) failed. \(detail)"
        case .hostKeyMismatch(let host, let detail):
            return "Host key for \(host) doesn't match a previous connection. \(detail)"
        case .commandFailed(let code, let stderr):
            return "Remote command exited \(code). \(stderr.prefix(120))"
        case .timeout(let secs):
            return "Connection timed out after \(Int(secs))s."
        case .other(let msg):
            return msg
        }
    }
}

/// Test helper — scripts success / failure behaviour deterministically
/// so `OnboardingViewModel` tests don't need a live SSH server.
public actor MockSSHConnectionTester: SSHConnectionTester {
    public enum Behavior: Sendable {
        case success
        case failure(SSHConnectionTestError)
    }

    private var behavior: Behavior
    public private(set) var callCount = 0

    public init(behavior: Behavior = .success) {
        self.behavior = behavior
    }

    public func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    public func testConnection(
        config: IOSServerConfig,
        key: SSHKeyBundle
    ) async throws {
        callCount += 1
        switch behavior {
        case .success:
            return
        case .failure(let err):
            throw err
        }
    }
}
