import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P29 of the whole-surface audit — round three, i.e. the regressions the
/// round-two phases (P18–P28) introduced in the branch under review.
///
/// The tests that belong beside an existing phase suite live there; this file
/// holds the ones that need the MAC target because the thing being pinned is a
/// view or a Mac-only view model.
@Suite("P29 — round-three remediation")
struct HermesP29RoundThreeRemediationTests {

    /// `scarf/` project directory, for the source scans below.
    private static var projectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: projectDir.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - The `sessions rename` removal, pinned at the CONSUMER

    /// `HermesCapabilitiesTests.sessionsRenameIsUngated` claims to pin the
    /// absence of a gate, but its body only asserts an unrelated flag and
    /// `detected` — re-adding `hasSessionsRename` at a v0.16 floor and
    /// re-wrapping the menu item would leave that suite green. The ungating
    /// lives in a VIEW, so this is where it has to be checked.
    ///
    /// `sessions rename` exists at every tagged Hermes (`add_parser("rename", …)`
    /// at `hermes_cli/main.py:2373`, tag v2026.3.12 = 0.2.0, below Scarf's
    /// v0.6.0 minimum), so the correct outcome is no gate at all — the P15
    /// `--clear-skills` rule.
    ///
    /// Fails if the Rename item is ever wrapped in a capability check again:
    /// the `Button("Rename…")` must be a direct child of the `.contextMenu`,
    /// with no `if`/`guard`/`capabilit`/`has…` between the two.
    @Test func theRenameMenuItemIsRenderedUnconditionally() throws {
        let source = try Self.source("scarf/Features/Chat/Views/ChatSessionListPane.swift")

        guard let menu = source.range(of: ".contextMenu {"),
              let button = source.range(of: #"Button("Rename…")"#)
        else {
            Issue.record("the session row's rename context-menu item has moved or been renamed")
            return
        }
        #expect(menu.upperBound < button.lowerBound, "the rename item is outside the context menu")

        // Everything the view puts between the menu and the item. Comments are
        // stripped first: the deliberate explanation there NAMES the retired
        // flag, which is the whole point of it.
        let between = source[menu.upperBound..<button.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
        for token in ["if ", "guard ", "capabilit", "hasSessionsRename", "Capabilities"] {
            #expect(!between.contains(token),
                    "a `\(token)` gate reappeared around the rename item: \(between)")
        }

        // And no flag by that name exists anywhere in the app any more. (The
        // ScarfCore side cannot assert this: referencing the symbol would not
        // compile, which is exactly why its test could not see the consumer.)
        #expect(!source.contains("hasSessionsRename {"))
    }
}
