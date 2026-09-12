import Foundation
import Testing
import ScarfCore
@testable import scarf

// MARK: - P46b finding 1: the picker binding, at the call sites

/// ``HermesReasoningEffort/pickerSelection(for:)`` only fixes the blank
/// control if the views actually bind through it. Three pickers ask this
/// question and P46 answered it at the OPTIONS for all three, which is why a
/// source pin is what stops the fourth from being missed.
@Suite("P46b · every effort picker binds through pickerSelection")
struct EffortPickerBindingP46bTests {

    private static let sites: [(String, Int)] = [
        ("scarf/scarf/Features/Settings/Views/Tabs/AgentTab.swift", 4),
        ("scarf/scarf/Features/Settings/Views/Tabs/AuxiliaryTab.swift", 1),
    ]

    @Test func everyEffortPickerNormalisesItsSelection() throws {
        for (relative, expected) in Self.sites {
            let src = try String(
                contentsOf: P46bRepo.root.appendingPathComponent(relative), encoding: .utf8
            )
            let uses = src.components(separatedBy: "HermesReasoningEffort.pickerSelection(").count - 1
            // A FLOOR, not an equality: the point is that no picker in the
            // file is left binding a raw stored value, and a later edit that
            // adds another `pickerSelection` call is not a regression.
            #expect(uses >= expected,
                    Comment(rawValue: "\(relative) binds \(uses) picker selections "
                            + "through `pickerSelection`, expected at least \(expected)"))
        }
    }

    /// The per-model override rows had no sentinel row at all, so an empty
    /// override had no tag to select. The row is prepended in
    /// `effortOptions(current:)`.
    @Test func theOverrideRowsHaveAConditionalSentinelRow() throws {
        let src = try String(
            contentsOf: P46bRepo.root.appendingPathComponent(
                "scarf/scarf/Features/Settings/Views/Tabs/AgentTab.swift"),
            encoding: .utf8
        )
        #expect(src.contains(#"? [""] + levels"#),
                "the override picker offers no row for an empty stored value")
        #expect(src.contains("HermesReasoningEffort.pickerSelection(for: current).isEmpty"),
                "the sentinel row is unconditional — an always-offered empty value is refused by the writer")
        // …and selecting it REMOVES the override rather than writing an
        // empty value, which `setReasoningOverrides` refuses outright.
        #expect(src.contains("save(sortedOverrides.filter { $0.key != pattern })"))
        #expect(HermesReasoningEffort.isValid("") == false,
                "if an empty value became writable, the removal arm is the wrong answer")
    }
}

// MARK: - P46b finding 2: the toggle's key, as the form spells it

/// `GatewayBehaviorViewModel` spells the key bare, and that is deliberate —
/// the shared executor resolves it onto the bridge source. This pins both
/// halves: the form's literal spelling (which is what keeps it visible to the
/// write/read parity gate) and the resolution it now gets.
@Suite("P46b · the gateway restart toggle resolves onto the bridge")
struct GatewayRestartKeyP46bTests {

    private static let modern = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")

    @Test func theFormStillSpellsTheKeyBare() {
        #expect(GatewayBehaviorViewModel.restartNotificationKey(
            platform: "slack", capabilities: Self.modern) == "slack.gateway_restart_notification")
    }

    /// …and the executor moves it, so the save creates no top-level block on
    /// a nested-only host and un-bridges nothing beside it.
    @Test func theExecutorMovesItOntoTheNestedSection() {
        let key = GatewayBehaviorViewModel.restartNotificationKey(
            platform: "slack", capabilities: Self.modern)
        let out = HermesPlatformSharedKeys.resolved(
            [key: "false"],
            configText: "platforms:\n  slack:\n    require_mention: false\n"
        )
        #expect(out["platforms.slack.gateway_restart_notification"] == "false",
                "the toggle still writes a top-level block: \(out)")
    }
}

/// The repo root, from this file's own path.
enum P46bRepo {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // scarfTests
        .deletingLastPathComponent()    // scarf
        .deletingLastPathComponent()    // repo root
}
