import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P41 / round-4 decision 9 — the two free-text surfaces round-3 decision 6
/// left open: the MCP entry editor and the per-model reasoning-override
/// pattern.
///
/// Decision 6 wired `YAMLScalar.containsControlCharacter` into
/// `BotsViewModel` and `HermesProfileRoute` and stopped there. The emitter
/// behind both of these is correct since P41 (`yamlScalar` forwards to
/// `YAMLScalar.quoteIfNeeded`, which escapes a control `\xNN`/`\uNNNN`), so
/// these refusals are not the parse guard — they are the VISIBILITY guard: a
/// pasted ESC that round-trips as the literal `a\x1bb` is a value the user
/// cannot see in the field they typed it into.
@Suite("P41 control-character refusals")
struct HermesP41ControlCharacterRefusalTests {

    /// One case per class PyYAML's reader refuses raw, plus the tab.
    static let controls: [String] = [
        "a\u{0}b", "a\u{1B}b", "a\u{7F}b", "a\u{85}b", "a\u{2029}b", "a\tb",
    ]

    // MARK: - Fixtures

    private func server(
        transport: MCPTransport,
        clientCert: String? = nil
    ) -> HermesMCPServer {
        HermesMCPServer(
            name: "srv", transport: transport,
            command: transport == .stdio ? "/usr/local/bin/tool" : nil, args: [],
            url: transport == .stdio ? nil : "https://mcp.example.com", auth: nil,
            env: [:], headers: [:], timeout: nil, connectTimeout: nil, enabled: true,
            toolsInclude: [], toolsExclude: [], resourcesEnabled: true,
            promptsEnabled: true, hasOAuthToken: false, clientCert: clientCert
        )
    }

    private func editor(_ s: HermesMCPServer) -> MCPServerEditorViewModel {
        MCPServerEditorViewModel(server: s, context: .local)
    }

    // MARK: - The MCP entry editor

    @Test(arguments: controls)
    func anEnvKeyIsRefused(_ raw: String) throws {
        let vm = editor(server(transport: .stdio))
        vm.envDraft = [.init(key: raw, value: "v")]
        #expect(vm.controlCharacterFieldLabel == "Environment name")
    }

    @Test(arguments: controls)
    func anEnvValueIsRefused(_ raw: String) throws {
        let vm = editor(server(transport: .stdio))
        vm.envDraft = [.init(key: "TOKEN", value: raw)]
        #expect(vm.controlCharacterFieldLabel == "Environment value")
    }

    @Test(arguments: controls)
    func aHeaderKeyAndValueAreRefused(_ raw: String) throws {
        let keyVM = editor(server(transport: .http))
        keyVM.headersDraft = [.init(key: raw, value: "v")]
        #expect(keyVM.controlCharacterFieldLabel == "Header name")

        let valueVM = editor(server(transport: .http))
        valueVM.headersDraft = [.init(key: "X-Note", value: raw)]
        #expect(valueVM.controlCharacterFieldLabel == "Header value")
    }

    @Test(arguments: controls)
    func aToolFilterIsRefused(_ raw: String) throws {
        let include = editor(server(transport: .stdio))
        include.includeDraft = "read_file, \(raw)"
        #expect(include.controlCharacterFieldLabel == "Include tools")

        let exclude = editor(server(transport: .stdio))
        exclude.excludeDraft = raw
        #expect(exclude.controlCharacterFieldLabel == "Exclude tools")
    }

    /// The refusal is checked on the value as the SAVE writes it. `save`
    /// trims every env/header key and every tool-filter item, and
    /// `.whitespaces` contains the tab — so a tab at either END of one of
    /// those never reaches config.yaml and refusing it would be an
    /// over-refusal on a paste the writer already cleans up. A tab INSIDE
    /// survives and is refused; a value is written raw and is refused at
    /// either end.
    @Test func aSurroundingTabIsCheckedWhereTheWriterTrimsAndWhereItDoesNot() {
        let trimmedKey = editor(server(transport: .stdio))
        trimmedKey.envDraft = [.init(key: "\tTOKEN\t", value: "v")]
        #expect(trimmedKey.controlCharacterFieldLabel == nil)

        let interiorKey = editor(server(transport: .stdio))
        interiorKey.envDraft = [.init(key: "TO\tKEN", value: "v")]
        #expect(interiorKey.controlCharacterFieldLabel == "Environment name")

        let value = editor(server(transport: .stdio))
        value.envDraft = [.init(key: "TOKEN", value: "v\t")]
        #expect(value.controlCharacterFieldLabel == "Environment value",
                "a value is written raw, so a trailing tab DOES reach the file")

        let trimmedTool = editor(server(transport: .stdio))
        trimmedTool.includeDraft = "read_file, \twrite_file\t"
        #expect(trimmedTool.controlCharacterFieldLabel == nil)
    }

    @Test(arguments: controls)
    func theCertKeyCAAndIdentityHeaderAreRefused(_ raw: String) throws {
        let cert = editor(server(transport: .http))
        cert.clientCertDraft = "/certs/\(raw).pem"
        #expect(cert.controlCharacterFieldLabel == "Client certificate")

        let key = editor(server(transport: .http))
        key.clientKeyDraft = "/certs/\(raw).key"
        #expect(key.controlCharacterFieldLabel == "Client key")

        let ca = editor(server(transport: .http))
        ca.sslVerifyPeer = true
        ca.sslCAPathDraft = "/certs/\(raw).pem"
        #expect(ca.controlCharacterFieldLabel == "CA bundle path")

        let name = editor(server(transport: .http))
        name.identityHeaderEnabled = true
        name.identityHeaderNameDraft = "X-\(raw)"
        name.identityHeaderValueFromDraft = .static
        name.identityHeaderValueDraft = "v"
        #expect(name.controlCharacterFieldLabel == "Identity header name")

        let value = editor(server(transport: .http))
        value.identityHeaderEnabled = true
        value.identityHeaderNameDraft = "X-Id"
        value.identityHeaderValueFromDraft = .static
        value.identityHeaderValueDraft = raw
        #expect(value.controlCharacterFieldLabel == "Identity header value")
    }

    @Test(arguments: controls)
    func aCwdIsRefusedOnStdio(_ raw: String) throws {
        let vm = editor(server(transport: .stdio))
        vm.cwdDraft = "/tmp/\(raw)"
        #expect(vm.controlCharacterFieldLabel == "Working directory")
    }

    /// The refusal runs BEFORE anything computes a value or touches
    /// config.yaml — `save` reports failure and never gets as far as
    /// building the `patchMCPServerField(expecting:)` expectation, which is
    /// emitted by the same routine as the write.
    @Test func saveRefusesWithAVisibleMessageAndWritesNothing() throws {
        let home = try TempHermesHome()
        let before = """
        mcp_servers:
          srv:
            command: /usr/local/bin/tool
            transport: stdio
        """
        try before.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)

        let vm = MCPServerEditorViewModel(
            server: server(transport: .stdio), context: home.context)
        vm.envDraft = [.init(key: "TOKEN", value: "a\u{1B}b")]

        var reported: Bool?
        vm.save { reported = $0 }
        #expect(reported == false)
        #expect(vm.isSaving == false)
        let message = try #require(vm.saveError)
        #expect(message.contains("Environment value"))
        #expect(message.contains("control character"))
        #expect(try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
                == before, "config.yaml was touched by a refused save")
    }

    // MARK: - What must NOT be refused (over-refusal clamps)

    /// An ordinary entry saves. Without this the suite would pass with a
    /// `controlCharacterFieldLabel` that always refuses.
    @Test func anOrdinaryEntryIsNotRefused() {
        let vm = editor(server(transport: .http))
        vm.headersDraft = [.init(key: "Authorization", value: "Bearer abc123")]
        vm.includeDraft = "read_file, write_file"
        vm.clientCertDraft = "/certs/client.pem"
        vm.identityHeaderEnabled = true
        vm.identityHeaderNameDraft = "X-Hermes-Profile"
        vm.identityHeaderValueFromDraft = .profile
        #expect(vm.controlCharacterFieldLabel == nil)
    }

    /// A delta-gated scalar that the save will NOT write must not block the
    /// editor: an entry whose config.yaml already carries a control
    /// character in `client_cert` would otherwise be permanently uneditable.
    @Test func anUnchangedScalarWithAControlCharacterDoesNotBlockTheSave() {
        let vm = editor(server(transport: .http, clientCert: "/certs/a\u{1B}b.pem"))
        #expect(vm.clientCertDraft == "/certs/a\u{1B}b.pem", "premise: the draft loaded it")
        #expect(vm.controlCharacterFieldLabel == nil,
                "an unchanged field is not written, so refusing it is over-refusal")
    }

    /// A CA path is ignored entirely when verification is off — the resolved
    /// `ssl_verify` is the literal `false` — so a control character in it is
    /// not written and not a reason to refuse.
    @Test func anIgnoredCAPathDoesNotBlockTheSave() {
        let vm = editor(server(transport: .http))
        vm.sslVerifyPeer = false
        vm.sslCAPathDraft = "/certs/a\u{1B}b.pem"
        #expect(vm.resolvedSSLVerify == "false", "premise: the path is not what gets written")
        #expect(vm.controlCharacterFieldLabel == nil)
    }

    /// Headers are not written for a stdio server and env is not written for
    /// an http one, so neither is checked on the wrong transport.
    @Test func theWrongTransportsRowsAreNotChecked() {
        let stdio = editor(server(transport: .stdio))
        stdio.headersDraft = [.init(key: "X", value: "a\u{1B}b")]
        #expect(stdio.controlCharacterFieldLabel == nil)

        let http = editor(server(transport: .http))
        http.envDraft = [.init(key: "TOKEN", value: "a\u{1B}b")]
        #expect(http.controlCharacterFieldLabel == nil)
    }

    // MARK: - The reasoning-override pattern

    /// The writer's own half of the same decision: a trimmed key, written
    /// trimmed. `setExcludedProviders` has trimmed all along.
    @Test func aReasoningOverrideKeyIsWrittenTrimmed() throws {
        let caps = HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)")
        let out = try #require(PowerSettingsWriter.setReasoningOverrides(
            in: "agent:\n  max_turns: 10\n",
            pairs: [(key: "  claude-opus-4.5  ", value: "high")],
            capabilities: caps
        ))
        #expect(out.contains("claude-opus-4.5: high"))
        #expect(!out.contains("'  claude-opus-4.5  '"))
        #expect(!out.contains("\"  claude-opus-4.5  \""))

        // A key that is only whitespace is still dropped.
        let empty = try #require(PowerSettingsWriter.setReasoningOverrides(
            in: "agent:\n  max_turns: 10\n",
            pairs: [(key: "   ", value: "high")],
            capabilities: caps
        ))
        #expect(!empty.contains("reasoning_overrides"))
    }

    /// The refusal predicate the Add button is gated on. The view holds the
    /// draft, so this pins the rule the view applies (trimmed, and a tab
    /// counts) rather than the button's `.disabled` modifier.
    @Test(arguments: controls)
    func aReasoningOverridePatternWithAControlIsRefused(_ raw: String) {
        #expect(PowerSettingsWriter.controlCharacterFieldLabel(pattern: "claude-\(raw)")
                == "Model pattern")
    }

    /// The over-refusal clamp: an ordinary pattern — including one pasted
    /// with surrounding whitespace, which the writer trims — is addable.
    @Test(arguments: ["claude-opus-4.5", "  claude-opus-4.5  ", "llama3:8b", ""])
    func anOrdinaryReasoningOverridePatternIsNotRefused(_ raw: String) {
        #expect(PowerSettingsWriter.controlCharacterFieldLabel(pattern: raw) == nil)
    }
}
