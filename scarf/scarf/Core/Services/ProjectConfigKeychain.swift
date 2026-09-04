import Foundation
import ScarfCore

/// Lifted into `ScarfCore` (`ScarfCore/Services/ProjectConfigKeychain.swift`)
/// so the `scarf-projects` MCP server's `project_set_config` tool routes
/// secrets through the exact same Keychain calls as this app's
/// Configuration UI — one implementation, not two that could drift. This
/// typealias keeps every existing call site in the app target unchanged.
typealias ProjectConfigKeychain = ScarfCore.ProjectConfigKeychain
