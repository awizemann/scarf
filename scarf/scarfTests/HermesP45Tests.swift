import Testing
import Foundation
import ScarfCore
@testable import scarf

// MARK: - P45 finding 16: the env-var-only managed host

/// Round-4 decision 1 has two halves, and this is the seam between them.
///
/// `get_managed_system` reads TWO signals (`hermes_cli/config.py:276-290` @
/// `v2026.9.7`): the `HERMES_MANAGED` environment variable and a `.managed`
/// marker in `HERMES_HOME`. Scarf can only see the marker — the env var
/// belongs to the service Hermes runs under, not to the shell Scarf's
/// transport opens — so a host managed ONLY by the env var renders writable
/// and every write it makes is refused at exit 0.
///
/// That is the designed fall-through, and this is the end-to-end proof that
/// it lands where decision 1 says: the probe says not-managed, the pane has
/// no pre-emptive banner, the write really runs, and the OUTPUT verdict is
/// what fails it. Nothing here can report a save over a write that did not
/// happen.
@Suite("P45 — the env-var-only managed host", .serialized)
@MainActor
struct HermesEnvVarOnlyManagedP45Tests {

    private typealias CLILog = HermesP35ApprovalsHostDefaultTests.CLILog

    /// Verbatim `format_managed_message("set configuration values")`
    /// (`hermes_cli/config.py:445-450`), which `set_config_value` prints to
    /// stderr before a bare `return` (`:3450-3452`) — exit 0.
    static let refusal = """
    Cannot set configuration values: this Hermes installation is managed by nixos.
    Use your package manager to upgrade or reinstall Hermes.
    """

    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p45-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    @Test func anEnvVarOnlyManagedHostFailsTheWriteWithNoPreEmptiveBanner() async throws {
        let ctx = Self.scratchContext()
        // Premise: no `.managed` marker on disk, so the probe — the only half
        // of `get_managed_system` Scarf can see — answers "not managed".
        #expect(!FileManager.default.fileExists(atPath: ctx.paths.managedMarker))
        #expect(HermesManagedInstall.system(
            fromMarker: nil, readsMarkerContents: true) == nil)

        let log = CLILog(output: Self.refusal, exitCode: 0)
        let vm = SettingsViewModel(context: ctx, cliRunner: log.runner())
        #expect(vm.isManagedHost == false, "no marker: the pane must render writable")
        #expect(vm.managedBannerText == nil,
                "a pre-emptive banner would have skipped the write entirely")

        vm.setSetting("display.streaming", value: "true")
        await vm.writeChain?.value

        // The write RAN — this is the fall-through, not the short-circuit.
        let call = try #require(log.calls.first)
        #expect(call == ["config", "set", "--", "display.streaming", "true"])
        // …and the output verdict is what caught it, at exit 0.
        #expect(vm.saveMessageIsFailure, "an exit-0 managed refusal was reported as a save")
        #expect(vm.message?.contains("managed by nixos") == true,
                "the banner did not quote Hermes's own reason: \(vm.message ?? "nil")")
        // The probe is unchanged by the refusal: Scarf does not infer the
        // marker from a refusal it read, so the pane stays writable.
        #expect(vm.isManagedHost == false)
    }
}

// MARK: - P45 finding 6: the Kanban provider-override badge's help string

/// `.help(…)` takes a `LocalizedStringKey`, so a literal with no catalog
/// entry renders English on every localized host — silently. The badge was
/// added with its help text and without its entry.
@Suite("P45 — the Kanban provider-override help string")
struct KanbanProviderHelpCatalogP45Tests {

    static let key = "Inference provider paired with the per-task model override, "
        + "set at create time. Read-only — Hermes has no update verb."

    @Test("the badge's help string is in the catalog, in all six locales")
    func theHelpStringIsLocalized() throws {
        let catalog = LocalizationCatalogTests.catalog
        let locales = try #require(catalog.strings[Self.key],
                                   "the help string has no catalog entry at all")
        let missing = LocalizationCatalogTests.shippedLocales.subtracting(locales.keys).sorted()
        #expect(missing.isEmpty, Comment(rawValue: "missing locales: \(missing.joined(separator: ","))"))
    }

    /// The literal has to still be at the call site under exactly this
    /// spelling, or the catalog entry is dead weight.
    @Test("the call site still passes that exact literal")
    func theCallSiteMatches() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // …/scarfTests
            .deletingLastPathComponent()          // …/scarf
            .appendingPathComponent("scarf/Features/Kanban/Views/KanbanInspectorPane.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(src.contains(".help(\"\(Self.key)\")"),
                "the badge's help literal was reworded without the catalog")
    }
}

// MARK: - P45 finding 13: the sentinel row says HERMES default

/// The empty `agent.reasoning_effort` row used to read "Provider default".
/// P44b walked the consumers: an absent or unrecognised value leaves
/// `agent.reasoning_config` nil, and the chat-completions transport then
/// substitutes `medium` EXPLICITLY (`agent/transports/chat_completions.py:420-422`
/// @ `v2026.9.7`) — only the Anthropic adapter leaves the choice to the model
/// (`agent/anthropic_adapter.py:570`). The default is Hermes's, not the
/// provider's, and the image-gen row is the same shape: an empty
/// `image_gen.model` falls through to the PLUGIN's own default
/// (`plugins/image_gen/_common.py:70-90`).
@Suite("P45 — the Hermes-default sentinel label")
struct HermesDefaultSentinelP45Tests {

    @Test("the relabelled key is in the catalog, in all six locales")
    func theNewKeyIsLocalized() throws {
        let catalog = LocalizationCatalogTests.catalog
        let locales = try #require(catalog.strings["Hermes default"])
        let missing = LocalizationCatalogTests.shippedLocales.subtracting(locales.keys).sorted()
        #expect(missing.isEmpty, Comment(rawValue: "missing locales: \(missing.joined(separator: ","))"))
        #expect(catalog.strings["Provider default"] == nil,
                "the retired key is still in the catalog, looking live")
    }

    @Test("no call site still passes the retired literal")
    func noCallSiteUsesTheOldLabel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
        var offenders: [String] = []
        for relative in ["scarf/Features/Settings", "Scarf iOS/Settings"] {
            let dir = root.appendingPathComponent(relative)
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            while let url = walker.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (i, line) in src.components(separatedBy: "\n").enumerated()
                where line.contains("\"Provider default\"") {
                    offenders.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue:
            "still labelling the sentinel row \"Provider default\": "
            + offenders.joined(separator: ", ")))
    }
}
