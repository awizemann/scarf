import Testing
import Foundation
@testable import scarf

/// P49 / round-5 decision 9 — the Mac app's five `hasACPSetSessionModel`
/// consumers.
///
/// `set_session_model` is defined in `acp_adapter/server.py` at the earliest
/// adapter tag (`:466` @ `v2026.3.17` = 0.3.0), at Scarf's v0.6.0 supported
/// floor (`:482` @ `v2026.3.30`, with a working body) and at the target
/// (`:929` @ `v2026.9.7`) — so the v0.13 gate hid four working surfaces from
/// every 0.6.0–0.12 host.
///
/// Each surface lives inside a `View` body or a `private var` on a view, so
/// there is no value to read back: the assertion is that the gate is gone
/// from the source and the surface is emitted unconditionally. Watched
/// failing against the pre-fix tree, where every one of these matched.
@Suite("P49 · the model surfaces are ungated")
struct ModelSurfaceUngatingP49Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf (the Xcode project dir)
            .deletingLastPathComponent()   // repo root
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Non-comment lines only: the files keep a comment explaining WHY the
    /// gate went, and that comment names the flag.
    private static func codeLines(_ source: String) -> [String] {
        source.components(separatedBy: "\n").filter {
            let bare = $0.trimmingCharacters(in: .whitespaces)
            return !(bare.hasPrefix("//") || bare.hasPrefix("*"))
        }
    }

    @Test("the chat header's model chip renders on any host that wires it")
    func sessionInfoBarChipIsUngated() throws {
        let source = try Self.source("scarf/scarf/Features/Chat/Views/SessionInfoBar.swift")
        #expect(!Self.codeLines(source).contains { $0.contains("hasACPSetSessionModel") })
        #expect(source.contains("if modelPreset != nil || onSwitchModel != nil {"))
    }

    @Test("a project's bound preset is applied at session boot on every host")
    func chatViewModelAppliesTheBoundPreset() throws {
        let source = try Self.source("scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift")
        #expect(!Self.codeLines(source).contains { $0.contains("hasACPSetSessionModel") })
        // The old early return logged and dropped the preset.
        #expect(!source.contains("preset '\\(preset.name)' bound but not applied"))
    }

    @Test("the project chat-settings sheet always shows the model section")
    func chatSettingsSheetModelSectionIsUngated() throws {
        let source = try Self.source("scarf/scarf/Features/Projects/Views/ProjectChatSettingsSheet.swift")
        #expect(!Self.codeLines(source).contains { $0.contains("hasACPSetSessionModel") })
        // The v0.15 auto-accept gate is a genuine floor and must survive.
        #expect(source.contains("capabilities.hasSessionEditAutoApproval"))
    }

    @Test("the Models sidebar entry is part of Configure unconditionally")
    func modelsSidebarEntryIsUngated() throws {
        let source = try Self.source("scarf/scarf/Navigation/SidebarView.swift")
        #expect(!Self.codeLines(source).contains { $0.contains("hasACPSetSessionModel") })
        #expect(source.contains(".profiles, .models]"))
        // The sibling capability gates in the same builder are untouched.
        #expect(source.contains("caps?.hasHermesProxy ?? false"))
        #expect(source.contains("caps?.hasPeerRunCommands ?? false"))
    }

    @Test("the projects well always offers Chat Settings…")
    func chatSettingsMenuItemIsUngated() throws {
        let source = try Self.source("scarf/scarf/Navigation/SidebarProjectsWell.swift")
        let code = Self.codeLines(source)
        #expect(!code.contains { $0.contains("hasACPSetSessionModel") })
        #expect(!code.contains { $0.contains("hasSessionEditAutoApproval") })
        #expect(source.contains("projects.contextMenu.chatSettings"))
    }

    @Test("the compression chip keeps its flag, and its comment stops claiming a v0.13 host sends one")
    func compressionChipCommentIsCorrected() throws {
        let source = try Self.source("scarf/scarf/Features/Chat/Views/SessionInfoBar.swift")
        // The gate stays (the plumbing is a landing pad, not dead code), but
        // no Hermes tag puts a compression count in the ACP usage payload —
        // `acp_adapter/server.py:1050-1059` @ v2026.5.7, `:917-924` @ v2026.9.7.
        #expect(source.contains("capabilities.hasContextCompressionCount && acpCompressionCount > 0"))

        // P49 corrected the CONSUMER comment, which is the only place that
        // claimed a v0.13 host sends the field. The old text must be gone…
        #expect(!source.contains("v0.13: Hermes surfaces a running count"))
        #expect(!source.contains("sees the chip the first time the agent compacts"))
        #expect(!source.contains("(which always reports 0) sees no chip"))
        // …and the corrected fact, with its citations, must be present.
        #expect(source.contains("NO Hermes tag sends a compaction"))
        #expect(source.contains("`acp_adapter/server.py:1050-1059` @ v2026.5.7"))
        #expect(source.contains("`:917-924` @"))
        #expect(source.contains("`_build_usage_update` carries none"))
        #expect(source.contains("the `> 0` test — not the capability flag — is"))
    }
}
