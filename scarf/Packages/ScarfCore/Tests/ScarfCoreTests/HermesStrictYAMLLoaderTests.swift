import Testing
import Foundation
@testable import ScarfCore

/// v0.21.6's strict config loader (`hermes_yaml.py`, ruamel under YAML 1.1):
/// a duplicate key in one mapping is a `DuplicateKeyError`, and bare
/// `y`/`Y`/`n`/`N` are booleans. Every expectation below was probed against
/// ruamel 0.18.16 in the v0.22.5 audit venv. Below the floor (and for an
/// undetected host) Scarf keeps PyYAML's reading: last-wins, `y`/`n` strings.
@Suite struct HermesStrictYAMLLoaderTests {

    static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")
    static let v0216 = HermesCapabilities.parseLine("Hermes Agent v0.21.6 (2026.9.24)")

    // MARK: - firstDuplicateKey

    @Test func topLevelRepeatIsNamedWithBothLines() {
        let dup = HermesYAML.firstDuplicateKey(in: "a: 1\nb: 2\na: 3\n")
        #expect(dup == YAMLDuplicateKey(path: "a", firstLine: 1, line: 3))
    }

    @Test func nestedRepeatCarriesItsPath() {
        let yaml = "agent:\n  max_turns: 10\n  reasoning_effort: low\n  max_turns: 20\n"
        #expect(HermesYAML.firstDuplicateKey(in: yaml)
                == YAMLDuplicateKey(path: "agent.max_turns", firstLine: 2, line: 4))
    }

    @Test func repeatedSectionHeaderIsADuplicate() {
        // The shape the pre-P19 writers produced on a BOM'd config.
        let yaml = "\u{FEFF}slack:\n  require_mention: true\nmodel:\n  default: x\nslack:\n  allowed_channels:\n    - C1\n"
        #expect(HermesYAML.firstDuplicateKey(in: yaml)?.path == "slack")
        #expect(HermesYAML.firstDuplicateKey(in: yaml)?.line == 5)
    }

    @Test func repeatInsideOneSequenceItemIsADuplicate() {
        let yaml = "profile_routes:\n  - profile: a\n    platform: slack\n    profile: b\n"
        #expect(HermesYAML.firstDuplicateKey(in: yaml)
                == YAMLDuplicateKey(path: "profile_routes[].profile", firstLine: 2, line: 4))
    }

    @Test func sameKeyInDifferentMappingsIsNotADuplicate() {
        // ruamel loads all of these.
        #expect(HermesYAML.firstDuplicateKey(in: "a: 1\nx:\n  a: 2\n") == nil)
        #expect(HermesYAML.firstDuplicateKey(in: "x:\n  a: 1\ny:\n  a: 2\n") == nil)
        let items = "routes:\n  - name: a\n    url: u1\n  - name: b\n    url: u2\nnext: 1\n"
        #expect(HermesYAML.firstDuplicateKey(in: items) == nil)
        let compact = "toolsets:\n- name: a\n  on: true\n- name: b\n  on: false\n"
        #expect(HermesYAML.firstDuplicateKey(in: compact) == nil)
    }

    @Test func quotedAndPlainSpellingsOfOneKeyCollide() {
        #expect(HermesYAML.firstDuplicateKey(in: "a: 1\n'a': 2\n")?.path == "a")
        #expect(HermesYAML.firstDuplicateKey(in: "\"a\": 1\na: 2\n")?.path == "a")
    }

    @Test func blockScalarBodiesContinuationsAndCommentsAreNotKeys() {
        let yaml = """
        agent:
          system_prompt: |
            role: assistant
            role: assistant
          note: a long folded value that mentions
            note: inside the fold
          # note: commented out
          note2: x
        """
        #expect(HermesYAML.firstDuplicateKey(in: yaml) == nil)
    }

    @Test func crlfFileReportsTheSameRepeat() {
        #expect(HermesYAML.firstDuplicateKey(in: "a: 1\r\nb:\r\n  c: 1\r\n  c: 2\r\n")?.path == "b.c")
    }

    // MARK: - HermesConfig read side

    @Test func duplicateKeyIsRecordedOnlyForAStrictLoaderHost() {
        let yaml = "model:\n  default: a\n  default: b\n"
        let strict = HermesConfig(yaml: yaml, capabilities: Self.v0216)
        #expect(strict.yamlDuplicateKey == YAMLDuplicateKey(path: "model.default", firstLine: 2, line: 3))
        let message = strict.strictYAMLLoadError
        #expect(message?.contains("model.default") == true)
        #expect(message?.contains("lines 2 and 3") == true)
        // Below the floor, and undetected: last-wins, no error (C1).
        for caps in [Self.v0215, HermesCapabilities.empty] {
            let config = HermesConfig(yaml: yaml, capabilities: caps)
            #expect(config.yamlDuplicateKey == nil)
            #expect(config.strictYAMLLoadError == nil)
            #expect(config.model == "b")
        }
        #expect(HermesConfig(yaml: yaml).yamlDuplicateKey == nil)
    }

    // MARK: - Booleans

    @Test func bareYAndNAreBooleansOnlyOnAStrictLoaderHost() {
        for raw in ["y", "Y", "y  # on"] {
            #expect(HermesYAML.boolishValue(raw, capabilities: Self.v0216) == true, "\(raw)")
            #expect(HermesYAML.boolishValue(raw, capabilities: Self.v0215) == nil, "\(raw)")
            #expect(HermesYAML.boolishValue(raw) == nil, "\(raw)")
        }
        for raw in ["n", "N"] {
            #expect(HermesYAML.boolishValue(raw, capabilities: Self.v0216) == false, "\(raw)")
            #expect(HermesYAML.boolishValue(raw, capabilities: Self.v0215) == nil, "\(raw)")
        }
        // Quoted `'y'` stays a string to ruamel too.
        #expect(HermesYAML.boolishValue("'y'", capabilities: Self.v0216) == nil)
        #expect(HermesYAML.boolishValue("\"n\"", capabilities: Self.v0216) == nil)
        // Not new words: `ye`, `no` unchanged.
        #expect(HermesYAML.boolishValue("ye", capabilities: Self.v0216) == nil)
        #expect(HermesYAML.boolishValue("no", capabilities: Self.v0215) == false)
    }

    @Test func configBooleanKeysReadBareYN() {
        let yaml = "display:\n  compact: y\nupdates:\n  check: n\nmultiplex_profiles: Y\n"
        let strict = HermesConfig(yaml: yaml, capabilities: Self.v0216)
        #expect(strict.display.compact)
        #expect(!strict.updatesCheck)
        #expect(strict.profileRoutes.multiplexProfiles)
        let legacy = HermesConfig(yaml: yaml, capabilities: Self.v0215)
        #expect(!legacy.display.compact)
        #expect(legacy.updatesCheck)
        #expect(!legacy.profileRoutes.multiplexProfiles)
    }

    // MARK: - Write side

    @Test func writeRefusalIsGatedOnTheFloor() {
        let dup = "a: 1\na: 2\n"
        #expect(HermesYAML.duplicateKeyWriteRefusal(in: dup, capabilities: Self.v0215) == nil)
        #expect(HermesYAML.duplicateKeyWriteRefusal(in: dup, capabilities: .empty) == nil)
        #expect(HermesYAML.duplicateKeyWriteRefusal(in: "a: 1\nb: 2\n", capabilities: Self.v0216) == nil)
        let why = HermesYAML.duplicateKeyWriteRefusal(in: dup, capabilities: Self.v0216)
        #expect(why?.contains("“a”") == true)
        #expect(why?.contains("nothing was saved") == true)
    }

    @Test func gatewaySaveListRefusesToPublishADuplicateOnAStrictHost() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-strict-yaml-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
        try FileManager.default.createDirectory(
            atPath: (ctx.paths.configYAML as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // A hand edit already repeats `model.default`; the allowlist write
        // would publish that file again.
        let original = "model:\n  default: a\n  default: b\n"
        try Data(original.utf8).write(to: URL(fileURLWithPath: ctx.paths.configYAML))
        func text() -> String? {
            (try? Data(contentsOf: URL(fileURLWithPath: ctx.paths.configYAML)))
                .flatMap { String(data: $0, encoding: .utf8) }
        }

        let refused = GatewayConfigWriter.saveListChecked(
            context: ctx, platform: "slack", key: "allowed_channels", items: ["C1"],
            capabilities: Self.v0216
        )
        guard case .refusedDuplicateKey(let why) = refused else {
            Issue.record("expected a duplicate-key refusal, got \(refused)")
            return
        }
        #expect(why.contains("model.default"))
        #expect(text() == original, "a refused save must not touch the file")

        // Below the floor the writer behaves exactly as before.
        let saved = GatewayConfigWriter.saveListChecked(
            context: ctx, platform: "slack", key: "allowed_channels", items: ["C1"],
            capabilities: Self.v0215
        )
        #expect(saved == .saved)
        #expect(text()?.contains("- C1") == true)
    }
}
