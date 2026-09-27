import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Hermes v0.21.5 audit remediation, phase R03 — the app-target halves.

@Suite struct AuxiliaryTaskRowsR03Tests {
    private func keys(_ line: String?) -> [String] {
        AuxiliaryTab.tasks(capabilities: line.map(HermesCapabilities.parseLine)).map { $0.key }
    }

    /// S05-F1: Hermes stopped reading `auxiliary.session_search.*` at
    /// v2026.5.28 (0.15.0), so the row must be gone from then on.
    @Test func sessionSearchIsHiddenOnCurrentHosts() {
        let current = keys("Hermes Agent v0.21.5 (2026.9.24)")
        #expect(!current.contains("session_search"))
        #expect(current == ["vision", "compression", "skills_hub", "approval", "mcp", "curator"])
    }

    /// Older hosts render the rows they always did, in the historical order.
    @Test func olderHostsKeepTheirRowsAndOrder() {
        #expect(keys("Hermes Agent v0.14.0 (2026.5.16)") == [
            "vision", "web_extract", "compression", "session_search",
            "skills_hub", "approval", "mcp", "curator",
        ])
        #expect(keys("Hermes Agent v0.15.0 (2026.5.28)") == [
            "vision", "web_extract", "compression",
            "skills_hub", "approval", "mcp", "curator",
        ])
        #expect(keys("Hermes Agent v0.11.0 (2026.4.23)") == [
            "vision", "web_extract", "compression", "session_search",
            "skills_hub", "approval", "mcp", "flush_memories",
        ])
    }

    @Test func unprobedHostShowsTheBaseRowsOnly() {
        #expect(keys(nil) == ["vision", "compression", "skills_hub", "approval", "mcp"])
    }
}
