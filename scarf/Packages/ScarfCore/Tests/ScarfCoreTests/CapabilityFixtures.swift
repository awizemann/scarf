import Foundation
@testable import ScarfCore

/// Shared host fixtures for capability-gated suites.
///
/// Four suites had each grown their own private `caps(_:)` plus its own
/// spelling of the same version lines; a version line typo'd in one of them
/// silently produced an UNDETECTED snapshot, which reads as "every flag
/// off" and makes a gating test pass for the wrong reason.
enum HermesHost {
    /// A `hermes --version` line, parsed exactly as the app parses it.
    static func caps(_ line: String) -> HermesCapabilities {
        HermesCapabilities.parseLine(line)
    }

    /// The version line each tagged release actually prints.
    static let v0204 = caps("Hermes Agent v0.20.4 (2026.8.18)")
    static let v0205 = caps("Hermes Agent v0.20.5 (2026.8.19)")
    static let v0206 = caps("Hermes Agent v0.20.6 (2026.8.27)")
    static let v021 = caps("Hermes Agent v0.21.0 (2026.8.31)")
    static let v0211 = caps("Hermes Agent v0.21.1 (2026.9.7)")
    /// A later patch: gates never roll back.
    static let v0212 = caps("Hermes Agent v0.21.2 (2026.9.20)")
    /// No probe answered yet — the state every gate must treat as "older".
    static let undetected = HermesCapabilities.empty
}
