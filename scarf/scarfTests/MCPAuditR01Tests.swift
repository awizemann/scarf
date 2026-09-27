import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Runs a snippet with the tagged Hermes reference's own Python, against a
/// scratch HERMES_HOME, so a test can check what HERMES parses out of a file
/// Scarf wrote. Only available on a machine that has the reference worktree
/// (`~/.hermes/hermes-agent-v0215`, tag v2026.9.24); the tests that need it
/// are skipped elsewhere. Never points at the real `~/.hermes`.
enum HermesReference {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".hermes/hermes-agent-v0215")
    static var python: URL { root.appendingPathComponent(".venv/bin/python") }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    /// Runs `code` with `HERMES_HOME=home` and returns its stdout as JSON.
    static func json(_ code: String, home: String, args: [String] = []) throws -> Any {
        let proc = Process()
        proc.executableURL = python
        proc.arguments = ["-c", code] + args
        proc.currentDirectoryURL = root
        proc.environment = [
            "HERMES_HOME": home,
            "HOME": home,
            "PATH": "/usr/bin:/bin",
        ]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let lastLine = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? ""
        return try JSONSerialization.jsonObject(with: Data(lastLine.utf8))
    }

    /// What Hermes registers for each server, per its own filter
    /// (`tools/mcp_tool_registration.py::_make_tool_filter`) and the
    /// `resources`/`prompts` switches (`_parse_boolish(..., default=True)`).
    static func toolFilterVerdict(home: String, probeTools: [String]) throws -> [String: [String: Any]] {
        let code = """
        import sys, json
        from hermes_cli.mcp_config import _get_mcp_servers
        from tools.mcp_tool_registration import _make_tool_filter
        from tools.mcp_tool_common import _parse_boolish
        probe = sys.argv[1].split(",")
        out = {}
        for name, cfg in _get_mcp_servers().items():
            f = _make_tool_filter(name, cfg)
            t = cfg.get("tools") or {}
            out[name] = {
                "registers": [x for x in probe if f(x)],
                "resources": _parse_boolish(t.get("resources"), default=True),
                "prompts": _parse_boolish(t.get("prompts"), default=True),
            }
        print(json.dumps(out))
        """
        return try json(code, home: home, args: [probeTools.joined(separator: ",")])
            as? [String: [String: Any]] ?? [:]
    }
}

/// Hermes v0.21.5 audit, phase R01 (MCP), app-target half.
@Suite struct MCPAuditR01Tests {

    private static func home(with yaml: String) throws -> (TempHermesHome, HermesFileService) {
        let home = try TempHermesHome()
        try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        return (home, HermesFileService(context: home.context))
    }

    private static func read(_ home: TempHermesHome) throws -> String {
        try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
    }

    private static let baseYAML = """
    model: x
    mcp_servers:
      gh:
        url: https://example.com/mcp
        enabled: true
    """

    // MARK: S09-F1 — the tool-filter round trip

    /// The P0: Scarf writes a blocklist, Scarf reads it back, Hermes reads
    /// the same file the same way. Before the fix the read-back put
    /// `delete_repo` in the INCLUDE list and lost `resources: false`.
    @Test func blocklistRoundTripsThroughScarfAndHermes() throws { try blocklistRoundTripsThroughScarfAndHermesBody(checkHermes: false) }

    /// The Hermes half: runs the tagged reference's own parser. Shown as
    /// skipped, not passed, on a machine without the reference.
    @Test(.enabled(if: HermesReference.available, "needs ~/.hermes/hermes-agent-v0215/.venv"))
    func blocklistRoundTripsThroughScarfAndHermesInHermes() throws { try blocklistRoundTripsThroughScarfAndHermesBody(checkHermes: true) }

    private func blocklistRoundTripsThroughScarfAndHermesBody(checkHermes: Bool) throws {
        let (home, service) = try Self.home(with: Self.baseYAML)
        defer { home.cleanup() }
        #expect(service.updateMCPToolFilters(
            name: "gh", include: [], exclude: ["delete_repo"], resources: false, prompts: true))

        let server = try #require(service.loadMCPServers().first { $0.name == "gh" })
        #expect(server.toolsInclude.isEmpty)
        #expect(!server.toolsIncludeIsExplicit)
        #expect(server.toolsExclude == ["delete_repo"])
        #expect(server.resourcesEnabled == false)
        #expect(server.promptsEnabled == true)
        // No bare `include:` line is written any more.
        #expect(!(try Self.read(home)).contains("include:"))

        guard checkHermes else { return }
        let verdict = try HermesReference.toolFilterVerdict(
            home: home.path, probeTools: ["delete_repo", "read_file", "list_issues"])
        #expect(verdict["gh"]?["registers"] as? [String] == ["read_file", "list_issues"])
        #expect(verdict["gh"]?["resources"] as? Bool == false)
        #expect(verdict["gh"]?["prompts"] as? Bool == true)
    }

    /// The layout Scarf's OLD writer produced — bare `include:` followed by
    /// the exclude list and the two switches — must now read correctly,
    /// because that is what is already sitting in users' config files.
    @Test func legacyScarfLayoutReadsAsTheBlocklistHermesSees() throws { try legacyScarfLayoutReadsAsTheBlocklistHermesSeesBody(checkHermes: false) }

    /// The Hermes half: runs the tagged reference's own parser. Shown as
    /// skipped, not passed, on a machine without the reference.
    @Test(.enabled(if: HermesReference.available, "needs ~/.hermes/hermes-agent-v0215/.venv"))
    func legacyScarfLayoutReadsAsTheBlocklistHermesSeesInHermes() throws { try legacyScarfLayoutReadsAsTheBlocklistHermesSeesBody(checkHermes: true) }

    private func legacyScarfLayoutReadsAsTheBlocklistHermesSeesBody(checkHermes: Bool) throws {
        let yaml = """
        mcp_servers:
          gh:
            url: https://example.com/mcp
            tools:
              include:
              exclude:
                - delete_repo
                - "admin_*"
              resources: false
              prompts: false
        """
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        let server = try #require(service.loadMCPServers().first)
        #expect(server.toolsInclude.isEmpty)
        #expect(!server.toolsIncludeIsExplicit)
        #expect(server.toolsExclude == ["delete_repo", "admin_*"])
        #expect(server.resourcesEnabled == false)
        #expect(server.promptsEnabled == false)

        guard checkHermes else { return }
        let verdict = try HermesReference.toolFilterVerdict(
            home: home.path, probeTools: ["delete_repo", "admin_x", "read_file"])
        #expect(verdict["gh"]?["registers"] as? [String] == ["read_file"])
    }

    /// Every spelling Hermes itself writes or accepts: PyYAML's indentless
    /// lists, IndentDumper's indented ones, flow lists, `[]`, null and a
    /// bare string (`_normalize_name_filter` takes a str as one entry).
    @Test func includeAndExcludeSpellingsMatchNormalizeNameFilter() throws { try includeAndExcludeSpellingsMatchNormalizeNameFilterBody(checkHermes: false) }

    /// The Hermes half: runs the tagged reference's own parser. Shown as
    /// skipped, not passed, on a machine without the reference.
    @Test(.enabled(if: HermesReference.available, "needs ~/.hermes/hermes-agent-v0215/.venv"))
    func includeAndExcludeSpellingsMatchNormalizeNameFilterInHermes() throws { try includeAndExcludeSpellingsMatchNormalizeNameFilterBody(checkHermes: true) }

    private func includeAndExcludeSpellingsMatchNormalizeNameFilterBody(checkHermes: Bool) throws {
        let yaml = """
        mcp_servers:
          indentless:
            command: x
            tools:
              include:
              - a
              - b
              prompts: false
          flow:
            command: x
            tools:
              exclude: [c, 'd e']
              include: []
          nulls:
            command: x
            tools:
              include: null
              exclude: single_tool
              resources: no
        """
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        let servers = Dictionary(uniqueKeysWithValues: service.loadMCPServers().map { ($0.name, $0) })
        #expect(servers["indentless"]?.toolsInclude == ["a", "b"])
        #expect(servers["indentless"]?.promptsEnabled == false)
        #expect(servers["flow"]?.toolsExclude == ["c", "d e"])
        #expect(servers["flow"]?.toolsInclude == [])
        #expect(servers["flow"]?.toolsIncludeIsExplicit == true)
        #expect(servers["nulls"]?.toolsIncludeIsExplicit == false)
        #expect(servers["nulls"]?.toolsExclude == ["single_tool"])
        #expect(servers["nulls"]?.resourcesEnabled == false)

        guard checkHermes else { return }
        let verdict = try HermesReference.toolFilterVerdict(
            home: home.path, probeTools: ["a", "c", "single_tool", "z"])
        #expect(verdict["indentless"]?["registers"] as? [String] == ["a"])
        // `include: []` wins over exclude and registers nothing.
        #expect(verdict["flow"]?["registers"] as? [String] == [])
        #expect(verdict["nulls"]?["registers"] as? [String] == ["a", "c", "z"])
    }

    /// `include: []` is written back as `[]`, never collapsed to "all".
    @Test func explicitEmptyWhitelistSurvivesAWrite() throws {
        let (home, service) = try Self.home(with: Self.baseYAML)
        defer { home.cleanup() }
        #expect(service.updateMCPToolFilters(
            name: "gh", include: [], exclude: ["x"], resources: true, prompts: true,
            includeIsExplicit: true))
        #expect(try Self.read(home).contains("      include: []"))
        let server = try #require(service.loadMCPServers().first)
        #expect(server.toolsIncludeIsExplicit)
        #expect(server.toolsInclude.isEmpty)
    }

    /// Keys under `tools:` that Scarf does not model survive a rewrite,
    /// with their nested lines, and the modelled four are still replaced.
    @Test func toolsRewriteKeepsUnmodelledChildKeys() throws { try toolsRewriteKeepsUnmodelledChildKeysBody(checkHermes: false) }

    /// The Hermes half: runs the tagged reference's own parser. Shown as
    /// skipped, not passed, on a machine without the reference.
    @Test(.enabled(if: HermesReference.available, "needs ~/.hermes/hermes-agent-v0215/.venv"))
    func toolsRewriteKeepsUnmodelledChildKeysInHermes() throws { try toolsRewriteKeepsUnmodelledChildKeysBody(checkHermes: true) }

    private func toolsRewriteKeepsUnmodelledChildKeysBody(checkHermes: Bool) throws {
        let yaml = """
        mcp_servers:
          gh:
            url: https://example.com/mcp
            tools:
              include:
              - old_a
              # keep this note
              future_flag: true
              future_list:
              - x
              - y
              exclude: [old_b]
              future_map:
                deep: 1
              resources: true
            enabled: true
        """
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        #expect(service.updateMCPToolFilters(
            name: "gh", include: [], exclude: ["delete_repo"], resources: false, prompts: true))
        let after = try Self.read(home)
        #expect(after.contains("""
            tools:
              exclude:
                - delete_repo
              resources: false
              prompts: true
              # keep this note
              future_flag: true
              future_list:
              - x
              - y
              future_map:
                deep: 1
            enabled: true
        """))
        #expect(!after.contains("old_a"))
        #expect(!after.contains("old_b"))

        // Scarf reads the new filters and ignores the unmodelled keys.
        let server = try #require(service.loadMCPServers().first)
        #expect(server.toolsInclude.isEmpty)
        #expect(server.toolsExclude == ["delete_repo"])
        #expect(server.resourcesEnabled == false)
        #expect(server.enabled)

        // A second rewrite is stable.
        #expect(service.updateMCPToolFilters(
            name: "gh", include: [], exclude: ["delete_repo"], resources: false, prompts: true))
        #expect(try Self.read(home) == after)

        guard checkHermes else { return }
        let code = """
        import json
        from hermes_cli.mcp_config import _get_mcp_servers
        print(json.dumps(_get_mcp_servers()["gh"]["tools"]))
        """
        let tools = try HermesReference.json(code, home: home.path) as? [String: Any]
        #expect(tools?["exclude"] as? [String] == ["delete_repo"])
        #expect(tools?["future_flag"] as? Bool == true)
        #expect(tools?["future_list"] as? [String] == ["x", "y"])
        #expect((tools?["future_map"] as? [String: Any])?["deep"] as? Int == 1)
        #expect(tools?["include"] == nil)
    }

    /// Children at indent 8 stay at indent 8: Scarf's own lines follow the
    /// block's indent, so the result still parses (review R01: mixing 6
    /// and 8 made the whole file unreadable to PyYAML).
    @Test func toolsRewriteFollowsTheBlocksOwnIndent() throws { try toolsIndent8Body(checkHermes: false) }

    @Test(.enabled(if: HermesReference.available, "needs ~/.hermes/hermes-agent-v0215/.venv"))
    func toolsRewriteFollowsTheBlocksOwnIndentInHermes() throws { try toolsIndent8Body(checkHermes: true) }

    private func toolsIndent8Body(checkHermes: Bool) throws {
        let yaml = """
        mcp_servers:
          gh:
            url: https://example.com/mcp
            tools:   # filters
                include:
                  - a
                future: 1
            enabled: true
        """
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        #expect(service.updateMCPToolFilters(
            name: "gh", include: ["b"], exclude: [], resources: true, prompts: false))
        let after = try Self.read(home)
        #expect(after.contains("""
            tools:   # filters
                include:
                  - b
                resources: true
                prompts: false
                future: 1
            enabled: true
        """))
        let server = try #require(service.loadMCPServers().first)
        #expect(server.toolsInclude == ["b"])
        #expect(server.promptsEnabled == false)

        guard checkHermes else { return }
        let code = """
        import json
        from hermes_cli.mcp_config import _get_mcp_servers
        print(json.dumps(_get_mcp_servers()["gh"]["tools"]))
        """
        let tools = try HermesReference.json(code, home: home.path) as? [String: Any]
        #expect(tools?["include"] as? [String] == ["b"])
        #expect(tools?["future"] as? Int == 1)
        #expect(tools?["prompts"] as? Bool == false)
    }

    /// An include list the user left alone is kept byte-for-byte, because
    /// its meaning depends on the Hermes version: a blank item registers
    /// nothing everywhere, `[]` only from v0.20.6.
    @Test @MainActor func untouchedIncludeIsKeptVerbatimOnAnExcludeEdit() async throws {
        let yaml = """
        mcp_servers:
          gh:
            url: https://example.com/mcp
            tools:
              include:
              - ''
              # after the block
            enabled: true
        """
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        let editor = MCPServerEditorViewModel(
            server: try #require(service.loadMCPServers().first), context: home.context)
        editor.excludeDraft = "delete_repo"
        let ok = await withCheckedContinuation { cont in editor.save { cont.resume(returning: $0) } }
        #expect(ok)
        let after = try Self.read(home)
        #expect(after.contains("      include:\n      - ''\n"))
        #expect(after.contains("      exclude:\n        - delete_repo\n"))
        #expect(after.contains("      # after the block\n    enabled: true"))
    }

    /// The editor no longer rewrites the tools block on every save: changing
    /// only a timeout leaves a hand-written block byte-for-byte alone.
    @Test @MainActor func editorSaveLeavesUntouchedToolFiltersAlone() async throws {
        let yaml = """
        mcp_servers:
          gh:
            url: https://example.com/mcp
            tools:
              include: []
              exclude:
              - delete_repo
            connect_timeout: 45.0
        """
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        let server = try #require(service.loadMCPServers().first)
        #expect(server.connectTimeout == 45)
        let editor = MCPServerEditorViewModel(server: server, context: home.context)
        #expect(editor.connectTimeoutDraft == "45")
        #expect(!editor.toolFiltersChanged)
        editor.timeoutDraft = "120"
        let ok = await withCheckedContinuation { cont in editor.save { cont.resume(returning: $0) } }
        #expect(ok)
        let after = try Self.read(home)
        #expect(after.contains("      include: []\n      exclude:\n      - delete_repo"))
        // S09-F3: Hermes's float spelling survives an unrelated save.
        #expect(after.contains("    connect_timeout: 45.0"))
        #expect(after.contains("    timeout: 120"))
    }

    /// Changing the exclude list of a whitelist-of-nothing keeps `include: []`.
    @Test @MainActor func editingExcludeKeepsAnExplicitEmptyInclude() async throws {
        let yaml = """
        mcp_servers:
          gh:
            url: https://example.com/mcp
            tools:
              include: []
        """
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        let editor = MCPServerEditorViewModel(
            server: try #require(service.loadMCPServers().first), context: home.context)
        editor.excludeDraft = "delete_repo"
        #expect(editor.toolFiltersChanged)
        let ok = await withCheckedContinuation { cont in editor.save { cont.resume(returning: $0) } }
        #expect(ok)
        let server = try #require(service.loadMCPServers().first)
        #expect(server.toolsIncludeIsExplicit)
        #expect(server.toolsExclude == ["delete_repo"])
    }

    // MARK: S09-F3 — float timeouts

    @Test func floatTimeoutsAreReadNotDropped() throws {
        let yaml = """
        mcp_servers:
          s:
            command: x
            timeout: 180
            connect_timeout: 12.5
        """
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        let server = try #require(service.loadMCPServers().first)
        #expect(server.timeout == 180)
        #expect(server.connectTimeout == 12.5)
    }

    @Test func timeoutEditIsDeltaGatedAndRefusesGarbage() {
        typealias VM = MCPServerEditorViewModel
        #expect(VM.timeoutEdit(draft: "45", loaded: 45.0) == .unchanged)
        #expect(VM.timeoutEdit(draft: " ", loaded: nil) == .unchanged)
        #expect(VM.timeoutEdit(draft: "", loaded: 45) == .set(nil))
        #expect(VM.timeoutEdit(draft: "90.5", loaded: 45) == .set(90.5))
        #expect(VM.timeoutEdit(draft: "abc", loaded: 45) == .invalid)
        #expect(VM.timeoutEdit(draft: "0", loaded: nil) == .invalid)
    }

    @Test @MainActor func invalidTimeoutRefusesTheSaveAndWritesNothing() async throws {
        let yaml = Self.baseYAML + "\n    connect_timeout: 45.0\n"
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        let before = try Self.read(home)
        let editor = MCPServerEditorViewModel(
            server: try #require(service.loadMCPServers().first), context: home.context)
        editor.connectTimeoutDraft = "soon"
        let ok = await withCheckedContinuation { cont in editor.save { cont.resume(returning: $0) } }
        #expect(!ok)
        #expect(editor.saveError != nil)
        #expect(try Self.read(home) == before)
    }

    // MARK: S09-F2 — OAuth entries written without `mcp add`

    @Test func oauthEntryInsertsIntoEveryLayoutTheWriterAccepts() throws {
        typealias HFS = HermesFileService
        // No block at all.
        let none = try #require(HFS.insertingOAuthEntry(
            into: "model: x\n", name: "linear", url: "https://mcp.linear.app/mcp", sse: false, replacing: false))
        #expect(none == "model: x\nmcp_servers:\n  linear:\n    url: 'https://mcp.linear.app/mcp'\n    auth: oauth\n    enabled: true\n")
        // An emptied block (`mcp remove` of the last server leaves `{}`).
        let emptied = try #require(HFS.insertingOAuthEntry(
            into: "mcp_servers: {}\nmodel: x\n", name: "a", url: "https://a/sse", sse: true, replacing: false))
        #expect(emptied.hasPrefix("mcp_servers:\n  a:\n    url: 'https://a/sse'\n    auth: oauth\n    transport: sse\n    enabled: true\nmodel: x"))
        // Appended after the last entry, ahead of the next top-level key.
        let appended = try #require(HFS.insertingOAuthEntry(
            into: Self.baseYAML + "\n# trailing\nother: 1\n", name: "b", url: "https://b", sse: false, replacing: false))
        #expect(appended.contains("    enabled: true\n  b:\n    url: 'https://b'\n    auth: oauth\n    enabled: true\n# trailing\nother: 1"))
        // A name that needs quoting as a key.
        let quoted = try #require(HFS.insertingOAuthEntry(
            into: "model: x\n", name: "a: b", url: "https://b", sse: false, replacing: false))
        #expect(quoted.contains("  'a: b':\n"))
    }

    @Test func oauthEntryRefusesLayoutsItWasNotBuiltFor() {
        typealias HFS = HermesFileService
        func refuses(_ yaml: String, replacing: Bool = false) -> Bool {
            HFS.insertingOAuthEntry(into: yaml, name: "n", url: "https://n", sse: false, replacing: replacing) == nil
        }
        #expect(refuses("mcp_servers: {a: {url: x}}\n"))                  // flow content
        #expect(refuses("mcp_servers:\n    a:\n      url: x\n"))          // 4-space block
        #expect(refuses("mcp_servers:\n\ta:\n\t\turl: x\n"))              // tabs
        #expect(refuses("mcp_servers:\n  n:\n    url: x\n"))              // exists, no overwrite
        #expect(refuses("model: x\n", replacing: true))                   // nothing to replace
        // Review R01: a duplicated entry name, with or without an entry in
        // between, is refused rather than guessed at (this used to build an
        // inverted range and trap).
        #expect(refuses("mcp_servers:\n  n:\n    url: a\n  m:\n    url: b\n  n:\n    url: c\n", replacing: true))
        #expect(refuses("mcp_servers:\n  n:\n    url: a\n  n:\n    url: c\n", replacing: true))
        // A block key spelled any other way, or twice, would make a second
        // block that hides the first from Hermes.
        #expect(refuses("\"mcp_servers\":\n  a:\n    url: x\n"))
        #expect(refuses("\u{FEFF}mcp_servers:\n  a:\n    url: x\n"))
        #expect(refuses("mcp_servers:\n  a:\n    url: x\nmcp_servers:\n  b:\n    url: y\n"))
    }

    /// Review R01: a managed install refuses config writes in `save_config`;
    /// the direct write checks the same marker and writes nothing.
    @Test func oauthAddRefusesAManagedInstall() throws {
        let (home, service) = try Self.home(with: Self.baseYAML + "\n")
        defer { home.cleanup() }
        try Data().write(to: URL(fileURLWithPath: home.context.paths.managedMarker))
        let before = try Self.read(home)
        let result = service.addMCPServerOAuth(
            name: "linear", url: "https://mcp.linear.app/mcp", sse: false,
            catalogIdentifier: nil,
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)"))
        #expect(result.exitCode != 0)
        #expect(try Self.read(home) == before)
    }

    /// Review R01: a blank include item keeps whitelist mode but names no
    /// tool, so an untouched editor sees no change and writes nothing.
    @Test @MainActor func blankIncludeItemIsNotATool() throws {
        let yaml = """
        mcp_servers:
          a:
            command: x
            tools:
              include:
              -
          b:
            command: x
            tools:
              include: ''
        """
        let (home, service) = try Self.home(with: yaml)
        defer { home.cleanup() }
        for server in service.loadMCPServers() {
            #expect(server.toolsInclude.isEmpty)
            #expect(server.toolsIncludeIsExplicit)
            let editor = MCPServerEditorViewModel(server: server, context: home.context)
            #expect(!editor.toolFiltersChanged)
        }
    }

    @Test func oauthEntryReplacesAnExistingEntryWholesale() throws {
        let yaml = """
        mcp_servers:
          n:
            url: https://old
            headers:
              Authorization: Bearer ${MCP_N_API_KEY}
          keep:
            command: x
        """
        let out = try #require(HermesFileService.insertingOAuthEntry(
            into: yaml, name: "n", url: "https://new", sse: false, replacing: true))
        #expect(!out.contains("https://old"))
        #expect(!out.contains("Authorization"))
        #expect(out.contains("  n:\n    url: 'https://new'\n    auth: oauth\n    enabled: true\n  keep:\n    command: x"))
    }

    /// Scarf writes it, Scarf reads it, and Hermes loads it as the same
    /// entry `mcp add --auth oauth` would have saved, with no security
    /// warnings.
    @Test func oauthEntryRoundTripsThroughScarfAndHermes() throws { try oauthEntryRoundTripsThroughScarfAndHermesBody(checkHermes: false) }

    /// The Hermes half: runs the tagged reference's own parser. Shown as
    /// skipped, not passed, on a machine without the reference.
    @Test(.enabled(if: HermesReference.available, "needs ~/.hermes/hermes-agent-v0215/.venv"))
    func oauthEntryRoundTripsThroughScarfAndHermesInHermes() throws { try oauthEntryRoundTripsThroughScarfAndHermesBody(checkHermes: true) }

    private func oauthEntryRoundTripsThroughScarfAndHermesBody(checkHermes: Bool) throws {
        let (home, service) = try Self.home(with: Self.baseYAML + "\n")
        defer { home.cleanup() }
        let result = service.writeMCPServerOAuthEntry(
            name: "linear", url: "https://mcp.linear.app/sse", sse: true, replacing: false)
        #expect(result.ok)
        let servers = service.loadMCPServers()
        #expect(servers.map(\.name) == ["gh", "linear"])
        let linear = try #require(servers.last)
        #expect(linear.auth == "oauth")
        #expect(linear.transport == .sse)
        #expect(linear.url == "https://mcp.linear.app/sse")
        #expect(linear.enabled)

        guard checkHermes else { return }
        let code = """
        import json
        from hermes_cli.mcp_config import _get_mcp_servers
        from hermes_cli.mcp_security import validate_mcp_server_entry
        s = _get_mcp_servers()
        print(json.dumps({k: {"cfg": v, "issues": validate_mcp_server_entry(k, v)} for k, v in s.items()}))
        """
        let parsed = try HermesReference.json(code, home: home.path) as? [String: [String: Any]]
        let cfg = parsed?["linear"]?["cfg"] as? [String: Any]
        #expect(cfg?["url"] as? String == "https://mcp.linear.app/sse")
        #expect(cfg?["auth"] as? String == "oauth")
        #expect(cfg?["transport"] as? String == "sse")
        #expect(cfg?["enabled"] as? Bool == true)
        #expect((parsed?["linear"]?["issues"] as? [Any])?.isEmpty == true)
        // The existing entry is untouched.
        #expect((parsed?["gh"]?["cfg"] as? [String: Any])?["url"] as? String == "https://example.com/mcp")
    }

    @Test func oauthAddRefusesAnExistingNameWithoutConfirmation() throws {
        let (home, service) = try Self.home(with: Self.baseYAML + "\n")
        defer { home.cleanup() }
        let before = try Self.read(home)
        let result = service.addMCPServerOAuth(
            name: "gh", url: "https://other", sse: false, catalogIdentifier: nil)
        #expect(result.exitCode != 0)
        #expect(try Self.read(home) == before)
    }

    @Test func oauthWriteRefusesAMissingConfigRatherThanCreatingOne() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let result = HermesFileService(context: home.context)
            .writeMCPServerOAuthEntry(name: "a", url: "https://a", sse: false, replacing: false)
        #expect(!result.ok)
        #expect(!FileManager.default.fileExists(atPath: home.context.paths.configYAML))
    }

    // MARK: S09-F4 — the browser flow's paste fallback

    @Test func redirectPasteLineMirrorsWhatHermesAccepts() {
        typealias C = MCPLoginController
        #expect(C.redirectPasteLine("  http://127.0.0.1:5173/callback?code=abc&state=xyz \n")
            == "http://127.0.0.1:5173/callback?code=abc&state=xyz")
        #expect(C.redirectPasteLine("?error=access_denied") == "?error=access_denied")
        #expect(C.redirectPasteLine("http://127.0.0.1:5173/callback") == nil)
        #expect(C.redirectPasteLine("code=a\nstate=b") == nil)
        #expect(C.redirectPasteLine("") == nil)
    }

    /// End to end through the controller: a fake `hermes` prints Hermes's
    /// paste prompt, reads ONE stdin line the way `_paste_callback_reader`
    /// does, and succeeds only when that line carries the code.
    @Test @MainActor func pastedRedirectReachesTheLoginProcessStdin() async throws {
        let script = """
        printf '  Or paste the redirect URL here (or the ``?code=...&state=...`` portion) and press Enter.\\n' >&2
        IFS= read -r line
        case "$line" in
          *code=abc123*) printf '  \\342\\234\\223 Authenticated \\342\\200\\224 3 tool(s) available\\n' ;;
          *) printf '  \\342\\234\\227 Authentication failed: got %s\\n' "$line" ;;
        esac
        """
        let controller = MCPLoginController(context: .local) { _ in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", script]
            return proc
        }
        controller.start(server: "remote-oauth", flow: "browser")
        for _ in 0..<400 where !controller.acceptsRedirectPaste {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.acceptsRedirectPaste)
        // Not a redirect: refused locally, the one stdin line is kept.
        #expect(!controller.submitRedirect("hello"))
        #expect(controller.acceptsRedirectPaste)
        #expect(controller.submitRedirect("http://127.0.0.1:41999/callback?code=abc123&state=s"))
        #expect(!controller.acceptsRedirectPaste)
        for _ in 0..<400 where controller.succeeded == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.succeeded == true)
        #expect(controller.errorMessage == nil)
    }

    /// A paste after the login ended is an error, not a SIGPIPE.
    @Test @MainActor func pasteAfterTheLoginEndedIsRefused() async throws {
        let controller = MCPLoginController(context: .local) { _ in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", "printf '  paste the redirect URL here\\n'; exit 0"]
            return proc
        }
        controller.start(server: "x", flow: nil)
        for _ in 0..<400 where controller.succeeded == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!controller.acceptsRedirectPaste)
        #expect(!controller.submitRedirect("http://127.0.0.1:1/callback?code=a"))
    }
}
