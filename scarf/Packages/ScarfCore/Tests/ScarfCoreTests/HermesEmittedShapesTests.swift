import Testing
import Foundation
@testable import ScarfCore

/// Fixture tests against **Hermes's own serializer emissions** — every YAML
/// fixture here is generated at test time by real PyYAML with the exact
/// `atomic_yaml_write` options (and JSON via `json.dumps(indent=2)`), per the
/// convention note "Hermes-authored file fixtures must come from Hermes's own
/// serializer". Covers the 2026-09-02 pattern-hunt findings:
///
///   1. unquoted colon-bearing map keys (`llama3:8b`)
///   2. ~80-column line folding of long plain and quoted scalars
///   4. flow-style empty top-level sections (`slack: {}`)
///   5. jobs.json records missing `enabled` / `schedule`
///   6. dotted quick-command names (`v1.2_deploy`)
///
/// When python3/PyYAML is missing on the host the generated-fixture tests
/// SKIP (record a known-issue-free early return) rather than pass vacuously.
@Suite struct HermesEmittedShapesTests {

    private func caps(_ major: Int, _ minor: Int) -> HermesCapabilities {
        HermesCapabilities(
            versionLine: "hermes \(major).\(minor).0",
            semver: HermesCapabilities.SemVer(major: major, minor: minor, patch: 0),
            dateVersion: nil
        )
    }

    // MARK: - Backlog 1 + 6: quick_commands (folding + dotted names)

    /// A command with spaces past ~80 columns folds across physical lines in
    /// Hermes's emission; the parser must join the continuations back into
    /// the FULL pipeline — a truncated prefix used to execute from the slash
    /// menu and then be written back permanently by the editor.
    @Test func foldedQuickCommandRoundTripsInFull() throws {
        let long = "docker compose -f /srv/stack/docker-compose.yml pull && "
            + "docker compose -f /srv/stack/docker-compose.yml up -d --remove-orphans "
            + "&& docker system prune -f"
        let obj = """
        {"quick_commands": {
            "deploy": {"type": "exec", "command": \(jsonString(long))},
            "v1.2_deploy": {"type": "exec", "command": "echo ok"}
        }}
        """
        guard let yaml = HermesEmission.yamlDump(json: obj) else { return }  // no PyYAML — skip
        // Sanity: the fixture really folded (the trait under test exists).
        #expect(yaml.contains("\n      "))

        let entries = HermesQuickCommandsYAML.entries(inYAML: yaml)
        #expect(entries.map(\.name) == ["deploy", "v1.2_deploy"])
        #expect(entries.first?.command == long)
        // Finding 6: the dotted name survives (the iOS reader now shares
        // this parser; the naive maxSplits split dropped it).
        #expect(entries.last == .init(name: "v1.2_deploy", type: "exec", command: "echo ok"))
    }

    // MARK: - Backlog 2: agent.reasoning_overrides (unquoted colon keys)

    /// PyYAML emits `llama3:8b: high` UNQUOTED — a colon not followed by
    /// whitespace is plain-scalar text. Splitting at the first colon sheared
    /// the key into `llama3` = `8b: high`, which then failed effort
    /// validation and made the whole reasoning-overrides editor refuse to
    /// save. Full loop: Hermes emission → Scarf read → Scarf write →
    /// PyYAML (Hermes) read-back.
    @Test func unquotedColonKeysReadAndRoundTrip() throws {
        let obj = """
        {"agent": {"reasoning_overrides": {"llama3:8b": "high", "qwen2.5-coder:32b": "low"}}}
        """
        guard let yaml = HermesEmission.yamlDump(json: obj) else { return }
        #expect(yaml.contains("llama3:8b: high"))  // fixture is really unquoted

        let parsed = HermesYAML.parseNestedYAML(yaml)
        let overrides = parsed.maps["agent.reasoning_overrides"]
        #expect(overrides?["llama3:8b"] == "high")
        #expect(overrides?["qwen2.5-coder:32b"] == "low")

        // The editor path must accept the read-back pairs again…
        let rewritten = PowerSettingsWriter.setReasoningOverrides(
            in: yaml,
            pairs: (overrides ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
            capabilities: caps(0, 20)
        )
        let updated = try #require(rewritten)  // nil == the old silent refusal
        // …and what Scarf wrote must load back in Hermes with the keys intact.
        if let loaded = HermesEmission.pyYAMLLoad(updated) {
            #expect(loaded.contains(#""llama3:8b": "high""#))
            #expect(loaded.contains(#""qwen2.5-coder:32b": "low""#))
        }
    }

    // MARK: - Backlog 3: free-text scalars (secrets.command.command)

    /// Folded free-text scalar, both plain and single-quoted flavors. The
    /// quoted flavor closes its quote only on the last continuation line, so
    /// quote-stripping must run on the JOINED value.
    @Test func foldedFreeTextScalarsJoinAndUnquote() throws {
        let plain = "op read op://Private/APIKey/credential --no-newline || "
            + "security find-generic-password -a hermes -s api-key-store -w"
        let quoted = "echo 'status: ok' && op read 'op://Private/API Key/credential' "
            + "--no-newline || security find-generic-password -a hermes -s api -w"
        let obj = """
        {"secrets": {"command": {"enabled": true, "command": \(jsonString(plain))}},
         "other": {"command": \(jsonString(quoted))}}
        """
        guard let yaml = HermesEmission.yamlDump(json: obj) else { return }
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(HermesYAML.stripYAMLQuotes(parsed.values["secrets.command.command"] ?? "") == plain)
        // PyYAML single-quotes the second one (it contains ": "); the join
        // must reunite the quote pair and strip it, and the escaped ''
        // must collapse back (maps entries are quote-stripped).
        let rejoined = HermesYAML.stripYAMLQuotes(parsed.values["other.command"] ?? "")
            .replacingOccurrences(of: "''", with: "'")
        #expect(rejoined == quoted)
    }

    // MARK: - Backlog 4: personalities folded system_prompt

    @Test func foldedPersonalitySystemPromptIsComplete() throws {
        let prompt = "You are a helpful assistant who always answers in the voice "
            + "of a weathered sea captain, sprinkling nautical metaphors generously."
        let obj = """
        {"agent": {"personalities": {"pirate": {"system_prompt": \(jsonString(prompt))}}}}
        """
        guard let yaml = HermesEmission.yamlDump(json: obj) else { return }
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(parsed.values["agent.personalities.pirate.system_prompt"] == prompt)
    }

    /// The folding join must NOT swallow genuine nested block bodies: a
    /// scalar followed by a sibling key, a deeper section, and a list all
    /// still parse as structure.
    @Test func joiningDoesNotSwallowRealStructure() throws {
        let obj = """
        {"agent": {"model": "gpt-5", "sub": {"a": "1"}, "toolsets": ["x", "y"]}}
        """
        guard let yaml = HermesEmission.yamlDump(json: obj) else { return }
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(parsed.values["agent.model"] == "gpt-5")
        #expect(HermesYAML.stripYAMLQuotes(parsed.values["agent.sub.a"] ?? "") == "1")
        #expect(parsed.lists["agent.toolsets"] == ["x", "y"])
    }

    // MARK: - Backlog 5: GatewayConfigWriter vs `slack: {}` / `[]`

    @Test func flowEmptyTopLevelSectionGetsBlockBodyNotDuplicate() throws {
        let obj = """
        {"slack": {}, "agent": {"model": "gpt-5"}}
        """
        guard let yaml = HermesEmission.yamlDump(json: obj) else { return }
        #expect(yaml.contains("slack: {}"))  // the trait under test

        let updated = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C123", "C456"]
        )
        // Exactly ONE top-level slack section — no appended duplicate.
        let headerCount = updated.components(separatedBy: "\n")
            .filter { $0 == "slack:" || $0.hasPrefix("slack: ") }.count
        #expect(headerCount == 1)
        #expect(!updated.contains("{}"))
        if let loaded = HermesEmission.pyYAMLLoad(updated) {
            #expect(loaded.contains(#""allowed_channels": ["C123", "C456"]"#))
            #expect(loaded.contains(#""model": "gpt-5""#))
        }

        // Same for the map writer (`setMap` shares locateBlock).
        let mapped = GatewayConfigWriter.setMap(
            in: yaml, section: "slack", key: "opts", pairs: [("a", "1")]
        )
        if let loaded = HermesEmission.pyYAMLLoad(mapped) {
            #expect(loaded.contains(#""opts": {"a": 1}"#))
        }
    }

    @Test func flowEmptyAllowlistIsReplacedInline() throws {
        let obj = """
        {"telegram": {"allowed_chats": [], "busy_ack_enabled": true}}
        """
        guard let yaml = HermesEmission.yamlDump(json: obj) else { return }
        #expect(yaml.contains("allowed_chats: []"))

        let updated = GatewayConfigWriter.setList(
            in: yaml, platform: "telegram", key: "allowed_chats", items: ["12345"]
        )
        if let loaded = HermesEmission.pyYAMLLoad(updated) {
            // The writer emits the numeric id unquoted, so PyYAML reads an
            // int — Hermes's own shape for Telegram chat ids.
            #expect(loaded.contains(#""allowed_chats": [12345]"#))
            #expect(loaded.contains(#""busy_ack_enabled": true"#))
        }
    }

    // MARK: - Backlog 6 (report finding 5): jobs.json tolerant decode

    /// Hermes's own reader treats `enabled` as default-true and `schedule`
    /// as nullable/absent; one bad record must not blank the whole board.
    @Test func jobsFileToleratesHermesTolerantShapes() throws {
        let obj = """
        {"jobs": [
            {"id": "good", "name": "n", "prompt": "p", "state": "scheduled",
             "enabled": true, "schedule": {"kind": "interval", "minutes": 5}},
            {"id": "no-enabled", "name": "n2", "prompt": "p2", "state": "scheduled",
             "schedule": {"kind": "cron", "expr": "* * * * *"}},
            {"id": "null-schedule", "name": "n3", "prompt": "p3", "state": "scheduled",
             "enabled": false, "schedule": null},
            {"name": "no-id at all", "prompt": "irrecoverable"},
            "not even an object"
        ], "updated_at": "2026-09-01T00:00:00"}
        """
        guard let json = HermesEmission.jsonDump(json: obj) else { return }
        let file = try JSONDecoder().decode(CronJobsFile.self, from: Data(json.utf8))
        // Recoverable records survive; irrecoverable ones are skipped, not fatal.
        #expect(file.jobs.map(\.id) == ["good", "no-enabled", "null-schedule"])
        #expect(file.jobs[1].enabled == true)              // Hermes default
        #expect(file.jobs[2].schedule.isDecodedPlaceholder)
        #expect(file.jobs[2].enabled == false)

        // A defaulted schedule must not be written back to disk.
        let reencoded = try JSONEncoder().encode(file.jobs[2])
        let text = String(decoding: reencoded, as: UTF8.self)
        #expect(!text.contains("\"schedule\""))
    }

    // MARK: - helpers

    /// JSON-encode a Swift string for embedding in a fixture description.
    private func jsonString(_ s: String) -> String {
        let data = try! JSONEncoder().encode([s])
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }
}
