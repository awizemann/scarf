import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Regression coverage for the quick-commands dotted-name bug: a command
/// named "v1.2 deploy" used to corrupt `config.yaml` because
/// `hermes config set quick_commands.v1.2_deploy.type ...` split the dot
/// into a nested map, AND (fixed here) reading it back with a naive
/// `split(".", maxSplits: 2)` fabricated a bogus entry and dropped the
/// real one even once the write itself was correct.
///
/// These tests fix the config.yaml *shape* by hand — the shape Hermes
/// itself would produce after `hermes config set` runs `_set_nested` — so
/// they exercise `loadQuickCommands`'s parsing directly without spawning
/// the real CLI.
struct QuickCommandsViewModelTests {

    private func write(_ yaml: String, to home: TempHermesHome) throws {
        let path = home.context.paths.configYAML
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Baseline: a plain dot-free name must parse byte-identically to
    /// today — no regression from the suffix-peeling rewrite.
    @Test func dotFreeNameRoundTrips() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try write("""
        quick_commands:
          standup:
            type: exec
            command: ./scripts/standup.sh
        """, to: home)

        let commands = QuickCommandsViewModel.loadQuickCommands(context: home.context)
        #expect(commands.count == 1)
        #expect(commands.first?.name == "standup")
        #expect(commands.first?.type == "exec")
        #expect(commands.first?.command == "./scripts/standup.sh")
    }

    /// v0.21+ host: `hermes config set quick_commands.v1\.2_deploy.type
    /// exec` writes a REAL literal dot into the YAML key (the backslash
    /// only affects `_split_key_path`'s in-flight parsing of the CLI
    /// argument, not what lands on disk). The flattened path
    /// `parseNestedYAML` produces is therefore
    /// "quick_commands.v1.2_deploy.type" — indistinguishable by dot-count
    /// from a 4-level-deep key. `loadQuickCommands` must still recover
    /// the dotted name intact by peeling the known `.type`/`.command`
    /// suffix instead of blindly splitting.
    @Test func dottedNameRoundTripsOnNewHostShape() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try write("""
        quick_commands:
          v1.2_deploy:
            type: exec
            command: ./deploy.sh v1.2
        """, to: home)

        let commands = QuickCommandsViewModel.loadQuickCommands(context: home.context)
        #expect(commands.count == 1)
        #expect(commands.first?.name == "v1.2_deploy")
        #expect(commands.first?.type == "exec")
        #expect(commands.first?.command == "./deploy.sh v1.2")
    }

    /// Pre-v0.21 host shape: the write path strips dots out before ever
    /// reaching the CLI (`ConfigDottedKeySegment.escaped` with
    /// `hasConfigDottedKeyEscape == false`), so the on-disk key never
    /// contains a literal dot in the first place. Confirms the read path
    /// handles that shape too (single flat segment, no embedded dot).
    @Test func sanitizedNameRoundTripsOnOldHostShape() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try write("""
        quick_commands:
          v12_deploy:
            type: exec
            command: ./deploy.sh
        """, to: home)

        let commands = QuickCommandsViewModel.loadQuickCommands(context: home.context)
        #expect(commands.count == 1)
        #expect(commands.first?.name == "v12_deploy")
    }

    /// Multiple commands, one dotted and one plain, must not cross-pollute
    /// during parsing (the old 3-way split silently fabricated a
    /// short-named phantom entry alongside the real one).
    @Test func mixedDottedAndPlainNamesBothSurvive() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try write("""
        quick_commands:
          v1.2_deploy:
            type: exec
            command: ./deploy.sh
          standup:
            type: exec
            command: ./standup.sh
        """, to: home)

        let commands = QuickCommandsViewModel.loadQuickCommands(context: home.context)
        let names = Set(commands.map(\.name))
        #expect(names == ["v1.2_deploy", "standup"])
        // The old bug fabricated a bogus "v1" entry from the chopped split.
        #expect(!names.contains("v1"))
    }

    // MARK: - Write-side helper (mirrors QuickCommandsViewModel.addOrUpdate)

    @Test func writeSideEscapesDottedNameOnNewHost() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(ConfigDottedKeySegment.escaped("v1.2 deploy", capabilities: caps) == "v1\\.2_deploy")
    }

    @Test func writeSideStripsDottedNameOnOldHost() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")
        #expect(ConfigDottedKeySegment.escaped("v1.2 deploy", capabilities: caps) == "v12_deploy")
    }

    @Test func writeSideDotFreeNameUnchanged() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        #expect(ConfigDottedKeySegment.escaped("standup", capabilities: caps) == "standup")
    }
}
