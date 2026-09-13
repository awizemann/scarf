import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P55 / round-6 decision 3 — the Mac half of dropping the `/goal` and
/// `/subgoal` optimistic mirrors.
///
/// `ChatViewModel.sendViaACP`'s slash switch had a `case "goal"` and a
/// `case "subgoal"` arm that wrote a local goal pill, a subgoal list and a
/// "Goal locked: …" toast for names the ACP adapter has never dispatched at
/// any tag (`_COMMANDS`, `acp_adapter/commands.py:44-66` @ `v2026.9.7`;
/// `_SLASH_COMMANDS`, `acp_adapter/server.py:163-173` @ `v2026.5.7` — nine
/// names in both, neither of them these). An unknown name falls through to
/// the model (`commands.py:94-95`), so the text was always an ordinary
/// prompt and the pill was state Scarf invented. Both arms are gone; the
/// `default:` arm says what was actually sent.
@Suite("Hermes P55 — the Mac /goal arm is the default arm")
struct HermesP55GoalArmTests {

    /// A never-started `ACPClient`, the shape `ChatViewModelSendDedupTests`
    /// uses: the synchronous switch is what's under test and the async
    /// prompt task fails fast.
    @MainActor
    static func deadClient() -> ACPClient {
        ACPClient(context: .local) { _ in throw CocoaError(.featureUnsupported) }
    }

    /// Keep the kanban teaching sheet's detector from spawning during the
    /// test: it is raised from the arm under test and probes the host.
    @MainActor
    static func suppressKanbanOnboarding(for context: ServerContext) {
        UserDefaults.standard.set(
            true,
            forKey: "scarf.kanbanOnboarding.dismissed.\(context.id.uuidString)"
        )
    }

    @MainActor
    @Test("a typed /goal gets the ordinary-prompt notice and no goal toast")
    func typedGoalTakesTheDefaultArm() throws {
        let chatVM = ChatViewModel(context: .local)
        Self.suppressKanbanOnboarding(for: chatVM.context)
        let rich = chatVM.richChatViewModel
        rich.setSessionId("s")
        rich.publishCapabilities(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"))

        chatVM.sendViaACP(client: Self.deadClient(), text: "/goal ship v2.9")

        let hint = try #require(rich.transientHint)
        #expect(hint == RichChatViewModel.acpUnhandledSlashNotice(name: "goal"))
        // The pre-P55 toast is gone, not merely different.
        #expect(!hint.contains("Goal locked"))
        // It is an ordinary, interruptive turn: the working indicator is on.
        #expect(chatVM.acpStatus == ChatViewModel.ACPPhase.agentWorking)
    }

    @MainActor
    @Test("a typed /subgoal gets its own notice, not a subgoal toast")
    func typedSubgoalTakesTheDefaultArm() throws {
        let chatVM = ChatViewModel(context: .local)
        Self.suppressKanbanOnboarding(for: chatVM.context)
        let rich = chatVM.richChatViewModel
        rich.setSessionId("s")
        rich.publishCapabilities(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"))

        chatVM.sendViaACP(client: Self.deadClient(), text: "/subgoal no regressions")

        let hint = try #require(rich.transientHint)
        #expect(hint == RichChatViewModel.acpUnhandledSlashNotice(name: "subgoal"))
        #expect(!hint.contains("Subgoal added"))
        #expect(chatVM.acpStatus == ChatViewModel.ACPPhase.agentWorking)
    }

    /// The mirror was ungated, so the notice must be too — a 0.12 host
    /// gets the same answer as the target tag.
    @MainActor
    @Test("the notice is the same on a pre-v0.13 host")
    func noticeIsUngated() throws {
        let chatVM = ChatViewModel(context: .local)
        Self.suppressKanbanOnboarding(for: chatVM.context)
        let rich = chatVM.richChatViewModel
        rich.setSessionId("s")
        rich.publishCapabilities(HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)"))

        chatVM.sendViaACP(client: Self.deadClient(), text: "/goal ship v2.9")

        #expect(rich.transientHint == RichChatViewModel.acpUnhandledSlashNotice(name: "goal"))
    }

    /// The kanban teaching moment rode on the dropped `/goal` arm and
    /// moved into the `default:` one. Its one surviving reader of a `/goal`
    /// argument decides only whether to raise the sheet.
    @Test("only a target-shaped /goal argument raises the kanban sheet")
    func goalArgumentClassification() {
        #expect(ChatViewModel.goalArgumentDescribesATarget("ship v2.9"))
        #expect(ChatViewModel.goalArgumentDescribesATarget("  ship v2.9  "))
        #expect(!ChatViewModel.goalArgumentDescribesATarget(""))
        #expect(!ChatViewModel.goalArgumentDescribesATarget("   "))
        #expect(!ChatViewModel.goalArgumentDescribesATarget("--clear"))
        #expect(!ChatViewModel.goalArgumentDescribesATarget("clear"))
        #expect(!ChatViewModel.goalArgumentDescribesATarget("  Clear "))
    }

    /// The iOS twin has no test target of its own, so the parity is pinned
    /// by reading its source: the same two arms are gone and the same
    /// notice is called from its `default:` arm (round-6 lesson 5).
    @Test("the iOS send path lost the same two arms and gained the notice")
    func iOSTwinMatches() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
        let src = try String(
            contentsOf: repoRoot.appendingPathComponent("scarf/Scarf iOS/Chat/ChatView.swift"),
            encoding: .utf8
        )
        #expect(!src.contains("case \"goal\":"))
        #expect(!src.contains("case \"subgoal\":"))
        #expect(!src.contains("Goal locked"))
        #expect(!src.contains("goalChip"))
        #expect(src.contains("RichChatViewModel.acpUnhandledSlashNotice(name: parsedSlash.name)"))
        // And the Mac side's `default:` arm calls the same helper.
        let mac = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift"
            ),
            encoding: .utf8
        )
        #expect(!mac.contains("case \"goal\":"))
        #expect(!mac.contains("case \"subgoal\":"))
        #expect(mac.contains("RichChatViewModel.acpUnhandledSlashNotice(name: parsed.name)"))
    }
}

/// P54b's lesson applied to P55's one new localized key: `String(localized:)`
/// is the extraction hook, not the translation. A wrapped key with no
/// `Localizable.xcstrings` row ships English on every locale, silently, and
/// the call-site test passes the whole time.
@Suite("Hermes P55 — the notice key has a catalogue row")
struct HermesP55CatalogueTests {

    static let locales = ["de", "es", "fr", "ja", "pt-BR", "zh-Hans"]

    /// The CATALOGUE spelling: `\(name)` resolves to `%@` at lookup time.
    static let key = "Hermes chat has no /%@ — sent as an ordinary prompt."

    @Test("the /goal notice is in the catalogue, translated in all six locales")
    func noticeKeyIsTranslated() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repoRoot.appendingPathComponent("scarf/scarf/Localizable.xcstrings")
        )
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        // A planted needle would pass a `!= nil` test against any dictionary;
        // the floor proves the catalogue actually decoded.
        #expect(strings.count > 1000, "catalogue decoded only \(strings.count) keys")
        let row = try #require(strings[Self.key] as? [String: Any], "no catalogue row")
        let localizations = try #require(row["localizations"] as? [String: Any])
        for locale in Self.locales {
            let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = unit?["value"] as? String
            #expect(value?.isEmpty == false, "\(Self.key) is untranslated in \(locale)")
        }
        // P44's sibling notice is a different key and must still be there.
        #expect(strings["This Hermes has no /%@ — sent as an ordinary prompt."] != nil)
    }

    /// P55b: deleting the pill left its three rows in the catalogue with no
    /// `String(localized:)` anywhere to extract them — dead weight that a
    /// later `contains` grep would read as "the pill is still there".
    @Test("the dropped goal-pill rows are gone from the catalogue")
    func retiredGoalRowsAreGone() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repoRoot.appendingPathComponent("scarf/scarf/Localizable.xcstrings")
        )
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        #expect(strings.count > 1000, "catalogue decoded only \(strings.count) keys")
        for key in ["Goal locked: %@", "Clear goal", "Goal · %lld"] {
            #expect(strings[key] == nil, "orphaned goal-pill row still in the catalogue: \(key)")
        }
        // Calibration: a key that IS present proves the lookup works, so the
        // four `== nil` expectations above are not vacuously green.
        #expect(strings[Self.key] != nil)
    }
}
