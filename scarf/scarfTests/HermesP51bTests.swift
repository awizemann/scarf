import Foundation
import Testing
import ScarfCore
@testable import scarf

// MARK: - P51b finding 6: the Mattermost form's early guard threw away a proven `.env`

/// P37 finding 5's mirror image, which P51 fixed in `NtfySetupViewModel` and
/// left standing in `MattermostSetupViewModel` in the SAME commit.
///
/// The form has two independently-proven reads: `.env`
/// (`MATTERMOST_REQUIRE_MENTION`) and config.yaml
/// (`mattermost.require_mention`). An early `guard let cfg =
/// snapshot.config?.mattermost else { return }` above the `.env` fallback
/// discarded the half that HAD been proved whenever config.yaml was
/// unreadable, so the toggle rendered the resolved default over a live `.env`
/// value the user had set.
@Suite("P51b · Mattermost keeps its proven .env half when config.yaml is unreadable")
@MainActor
struct MattermostEnvFallbackSurvivesP51bTests {

    private typealias CLILog = MainActorBlockingWritesP11Tests.CLILog

    /// A home whose `.env` is READABLE and whose config.yaml EXISTS and is
    /// not — the shape `GuardedTextFile` proves apart from an absent file.
    private static func contextWithUnreadableConfig() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p51b-mm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let ctx = ServerContext.local(home: home)
        try? "MATTERMOST_REQUIRE_MENTION=false\nMATTERMOST_URL=https://mm.example\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? "mattermost:\n  reply_mode: off\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: ctx.paths.configYAML)
        return ctx
    }

    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Fails before the fix: the guard returns and `requireMention` keeps the
    /// `true` default, contradicting the `.env` value Scarf just proved.
    @Test func theEnvFallbackSurvivesAnUnreadableConfig() async {
        let ctx = Self.contextWithUnreadableConfig()
        let log = CLILog()
        let vm = MattermostSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.requireMention = true

        vm.load()
        await Self.until(timeout: 10) { !vm.isLoading }

        #expect(vm.loadRefusal != nil, "premise: the config.yaml read must be refused")
        #expect(vm.serverURL == "https://mm.example", "premise: the `.env` half must be proved")
        #expect(vm.requireMention == false,
                "a refused config read discarded the proven MATTERMOST_REQUIRE_MENTION value")
    }
}

// MARK: - P51b finding 5: "all fifteen share one door" is true of the SETUP FORMS only

/// `commitSave` carries round-4 decision 9's control-character refusal and
/// its doc comment claimed every config write goes through it.
/// `GatewayBehaviorViewModel` does not — it calls
/// `PlatformSetupHelpers.saveForm` directly, because its save is two steps
/// and it is not a `PlatformSetupForm`. That is allowed (it sends booleans,
/// not free text) but it must stay the ONLY one, or the claim decays again.
@Suite("P51b · gateway behaviour is the only direct saveForm caller")
struct GatewayBehaviourIsTheOnlyDirectSaveFormCallerP51bTests {

    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // scarfTests
            .deletingLastPathComponent()      // scarf
            .appendingPathComponent("scarf")  // the app target
    }

    @Test func exactlyOneProductionCallerBypassesCommitSave() throws {
        let fm = FileManager.default
        var callers: [String] = []
        let root = Self.appRoot
        let walker = try #require(fm.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains("PlatformSetupHelpers.saveForm(")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") {
                callers.append(url.lastPathComponent)
            }
        }
        #expect(callers == ["GatewayBehaviorViewModel.swift"], """
            `PlatformSetupHelpers.saveForm` is called directly from \(callers). \
            Every setup form must go through `commitSave`, which carries the \
            latched-refusal and control-character guards; a new direct caller \
            either joins that door or documents why its batch carries no free \
            text.
            """)
    }
}
