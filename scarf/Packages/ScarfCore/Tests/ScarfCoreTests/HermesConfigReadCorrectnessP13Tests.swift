import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Whole-surface audit P13 — config READ correctness.
///
/// Every default asserted here was verified twice against the Hermes source,
/// per the phase rule: once at the target tag **v2026.9.7 (v0.21.1)** and
/// once at the key's own FLOOR tag (walking back over each file location the
/// key has had — `hermes_cli/config.py`'s `DEFAULT_CONFIG` before the
/// v2026.7.30 split into `hermes_cli/config_defaults.py`). Both citations are
/// in each test's doc comment, because a default that changed mid-window is
/// not a default at all — it is a sentinel (see `richMessagesIsASentinel`).
///
/// A note on where a "default" lives. `hermes_cli/config.py:2197,2211`
/// (`_load_config_impl`) starts from `deepcopy(DEFAULT_CONFIG)` and
/// deep-merges the user's config.yaml over it, so for any key present in the
/// schema the reader's OWN fallback is unreachable and the schema value is
/// the answer. Where the schema has no entry, the reader's fallback IS the
/// default — both kinds appear below and each test says which it is.
struct HermesConfigReadCorrectnessP13Tests {

    // MARK: - Default drifts (finding 1)

    /// `openrouter.response_cache` defaults **true**.
    ///
    /// - v2026.9.7 `hermes_cli/config_defaults.py:649`
    ///   `"openrouter": {"response_cache": True, ...}`
    /// - floor v2026.5.7 (v0.13.0) `hermes_cli/config.py:686`
    ///   `"response_cache": True,` — the first tag at which the key exists,
    ///   and True at every tag in between.
    ///
    /// Scarf read `false`, so the toggle rendered OFF on a host that was
    /// caching and one save wrote the `false` the user never chose.
    @Test func openrouterResponseCacheDefaultsTrue() {
        #expect(HermesConfig(yaml: "model:\n  default: x\n").openrouterResponseCacheEnabled)
        // Only an explicit falsy scalar turns it off — including the
        // spellings a literal `== "true"` compare used to read as ON.
        #expect(!HermesConfig(yaml: "openrouter:\n  response_cache: false\n")
            .openrouterResponseCacheEnabled)
        #expect(!HermesConfig(yaml: "openrouter:\n  response_cache: 'off'\n")
            .openrouterResponseCacheEnabled)
        #expect(HermesConfig(yaml: "openrouter:\n  response_cache: yes\n")
            .openrouterResponseCacheEnabled)
        // …and a trailing comment must not defeat the falsy read.
        #expect(!HermesConfig(yaml: "openrouter:\n  response_cache: false  # billing\n")
            .openrouterResponseCacheEnabled)
    }

    /// `display.streaming` defaults **false** — and always has.
    ///
    /// - v2026.9.7 `hermes_cli/config_defaults.py:796` `"streaming": False,`
    ///   and its only reader `cli.py:2598`
    ///   `self.streaming_enabled = display.get("streaming", False)`
    /// - floor v2026.3.17 (v0.3.0) `hermes_cli/config.py:220`
    ///   `"streaming": False,` — every tag from the first one that has the
    ///   key agrees.
    ///
    /// Scarf's `values["display.streaming"] != "false"` was wrong twice: the
    /// absent key rendered the toggle ON, and the raw compare bypassed
    /// `HermesYAML.normalizedScalar`.
    @Test func displayStreamingDefaultsFalseAndIsBoolish() {
        #expect(!HermesConfig(yaml: "model:\n  default: x\n").streaming)
        #expect(HermesConfig(yaml: "display:\n  streaming: true\n").streaming)
        #expect(HermesConfig(yaml: "display:\n  streaming: \"true\"\n").streaming)
        #expect(HermesConfig(yaml: "display:\n  streaming: true  # for now\n").streaming)
        #expect(!HermesConfig(yaml: "display:\n  streaming: false\n").streaming)
    }

    /// `platforms.telegram.extra.rich_messages` is a SENTINEL, not a default,
    /// because Hermes flipped the shipped value one release after the key
    /// landed:
    ///
    /// - v2026.6.19 (v0.17.0) `hermes_cli/config.py:2144` `"rich_messages": True`
    ///   — the FLOOR tag; the key exists at no earlier tag.
    /// - v2026.7.1 (v0.18.0) `hermes_cli/config.py:2367` `"rich_messages": False`
    /// - v2026.9.7 `hermes_cli/config_defaults.py:1492` `"rich_messages": False`,
    ///   and the reader agrees: `plugins/platforms/telegram/adapter.py:440`
    ///   `_coerce_bool_extra("rich_messages", False)`.
    ///
    /// So the parse must report ABSENCE and let the display layer resolve it
    /// against the host. Baking in either answer renders one host
    /// generation's toggle backwards.
    @Test func richMessagesIsASentinel() {
        #expect(HermesConfig(yaml: "model:\n  default: x\n").telegram.richMessages == nil)
        let on = HermesConfig(yaml: """
            platforms:
              telegram:
                extra:
                  rich_messages: true
            """)
        #expect(on.telegram.richMessages == true)
        let off = HermesConfig(yaml: """
            platforms:
              telegram:
                extra:
                  rich_messages: 'off'
            """)
        #expect(off.telegram.richMessages == false)
    }

    /// The absent case resolves to the HOST's default: `true` on the single
    /// release that shipped it on (v0.17.x), `false` from v0.18.0 on, and
    /// `false` for an unanswered version probe.
    @Test func displayTelegramRichMessagesResolvesAgainstTheHost() {
        let absent = HermesConfig(yaml: "model:\n  default: x\n")
        #expect(absent.displayTelegramRichMessages(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)")))
        #expect(!absent.displayTelegramRichMessages(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)")))
        #expect(!absent.displayTelegramRichMessages(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")))
        #expect(!absent.displayTelegramRichMessages(capabilities: .empty))
        // An explicit value always wins over the host default.
        let explicitOn = HermesConfig(yaml: """
            platforms:
              telegram:
                extra:
                  rich_messages: true
            """)
        #expect(explicitOn.displayTelegramRichMessages(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")))
    }

    // MARK: - Boolish reads (findings 2 and 3)

    /// The TRUE-by-default keys must read Hermes's falsy set, not a literal
    /// `== "true"`. Under the old `bool(_:default: true)` every one of these
    /// `yes` / `on` / `1` spellings read as OFF, and a trailing comment made
    /// even a plain `true` read as OFF.
    ///
    /// Each key's default was checked at v2026.9.7 by exec'ing
    /// `hermes_cli/config_defaults.py` and reading `DEFAULT_CONFIG`.
    @Test func trueDefaultKeysAreBoolish() {
        let yaml = """
        display:
          inline_diffs: yes
        terminal:
          persistent_shell: on
        security:
          redact_secrets: true  # keep
          tirith_enabled: 'off'
        compression:
          enabled: 'no'
        cron:
          wrap_response: "0"
        """
        let c = HermesConfig(yaml: yaml)
        #expect(c.display.inlineDiffs)          // `yes` is ON, not OFF
        #expect(c.terminal.persistentShell)     // `on` is ON
        #expect(c.security.redactSecrets)       // trailing comment stripped
        #expect(!c.security.tirithEnabled)      // quoted `off` is OFF
        #expect(!c.compression.enabled)         // `no` is OFF
        #expect(!c.cronWrapResponse)            // `0` is OFF
    }

    /// …and every one of them still defaults to ON when absent.
    @Test func trueDefaultKeysDefaultOnWhenAbsent() {
        let c = HermesConfig(yaml: "model:\n  default: x\n")
        #expect(c.display.inlineDiffs)
        #expect(c.terminal.persistentShell)
        #expect(c.voice.sttEnabled)
        #expect(c.security.redactSecrets)
        #expect(c.security.tirithEnabled)
        #expect(c.security.tirithFailOpen)
        #expect(c.compression.enabled)
        #expect(c.discord.requireMention)
        #expect(c.matrix.requireMention)
        #expect(c.matrix.autoThread)
        #expect(c.mattermost.requireMention)
        #expect(c.userProfileEnabled)
        #expect(c.cronWrapResponse)
        #expect(c.displayBusyAckEnabled)
        // `voice.auto_tts` LEFT this list at P20: it is `False` in both layers
        // at every tag in the window (`config_defaults.py:1121`,
        // `cli_voice_mixin.py:516` @ v2026.9.7).
        #expect(!c.autoTTS)
        #expect(c.interimAssistantMessages)
    }

    /// Slack's three flags went through raw `!= "false"` / `== "true"`
    /// compares on the VERBATIM parse. Defaults at v2026.9.7:
    /// `slack.require_mention` True (`config_defaults.py`), `reply_in_thread`
    /// True (`plugins/platforms/slack/adapter.py:2590,3989` and
    /// `gateway/run_turn.py:2790` all `.get("reply_in_thread", True)`),
    /// `reply_broadcast` False (`adapter.py:2083`).
    @Test func slackFlagsAreBoolish() {
        let defaults = HermesConfig(yaml: "model:\n  default: x\n")
        #expect(defaults.slack.requireMention)
        #expect(defaults.slack.replyInThread)
        #expect(!defaults.slack.replyBroadcast)

        let c = HermesConfig(yaml: """
        platforms:
          slack:
            require_mention: 'no'
            extra:
              reply_in_thread: false  # flat replies
              reply_broadcast: yes
        """)
        #expect(!c.slack.requireMention)
        #expect(!c.slack.replyInThread)
        #expect(c.slack.replyBroadcast)
    }

    /// Slack's `require_mention` precedence mirrors Hermes's bridge exactly:
    /// `gateway/config_loader.py` copies the top-level spelling into `extra`
    /// with `extra.update(bridged)`, so a top-level value OVERWRITES an
    /// `extra:` one. The FIRST key present decides — a present-but-false
    /// top-level value must not fall through to a true `extra:` one.
    @Test func slackRequireMentionPrecedenceIsFirstPresentKey() {
        let c = HermesConfig(yaml: """
        platforms:
          slack:
            require_mention: false
            extra:
              require_mention: true
        """)
        #expect(!c.slack.requireMention)
    }

    /// P20 refined the above: the bridge SOURCE is chosen by
    /// `platform_section` before any key is looked at, and a top-level
    /// `slack:` block wins OUTRIGHT — so with one present, a nested
    /// `platforms.slack.require_mention` is never bridged and never reaches
    /// the adapter, whichever key "came first". Fails before P20, which
    /// walked a fixed key list and picked the nested key here.
    @Test func topLevelSlackBlockReplacesTheNestedBridgeSource() {
        let c = HermesConfig(yaml: """
        slack:
          reply_prefix: hi
        platforms:
          slack:
            require_mention: false
            extra:
              require_mention: true
        """)
        // Top-level block present but carrying no `require_mention`, so
        // nothing is bridged and the merged `extra:` value survives.
        #expect(c.slack.requireMention)
    }

    // MARK: - Closed-enum normalisation (finding 4)

    /// A closed-enum scalar drives a `PickerRow`, so a trailing comment or a
    /// quote pair must not survive into the selection — the control renders
    /// blank for a selection outside its own option list, and the next save
    /// writes over a value the user never saw.
    @Test func closedEnumKeysAreNormalised() {
        let c = HermesConfig(yaml: """
        terminal:
          backend: docker  # weak-fsync host
        approvals:
          mode: "smart"
        display:
          resume_display: minimal   # short recap
          busy_input_mode: 'steer'
        database:
          journal_mode: delete  # NFS
        stt:
          provider: openai   # cloud
        tts:
          provider: "elevenlabs"
        browser:
          cloud_provider: browserbase  # hosted
        human_delay:
          mode: 'natural'
        """)
        #expect(c.terminalBackend == "docker")
        #expect(c.approvalMode == "smart")
        #expect(c.display.resumeDisplay == "minimal")
        #expect(c.display.busyInputMode == "steer")
        #expect(c.database.journalMode == "delete")
        #expect(c.voice.sttProvider == "openai")
        #expect(c.voice.ttsProvider == "elevenlabs")
        #expect(c.browserCloudProvider == "browserbase")
        #expect(c.humanDelay.mode == "natural")
    }

    /// `strEnum` deliberately does NOT validate against a fixed member set:
    /// Hermes grows these enums between releases, and snapping an unknown
    /// member back to the default would hide a value the host honours.
    /// `human_delay.mode: natural` above is the live case; here is a value
    /// no Hermes version knows, which must still round-trip.
    @Test func closedEnumKeysKeepUnknownMembers() {
        let c = HermesConfig(yaml: "database:\n  journal_mode: memory\n")
        #expect(c.database.journalMode == "memory")
    }

    // MARK: - Mattermost reply_mode path (finding 6)

    /// Hermes reads `platforms.mattermost.extra.reply_mode` and nothing else
    /// from YAML: `plugins/platforms/mattermost/adapter.py:120-121`
    /// `config.extra.get("reply_mode", "") or _get_scoped_secret(...)`, and
    /// `reply_mode` is NOT one of `gateway/config_loader.py`'s `_SHARED_KEYS`
    /// (v2026.9.7 `:197-215`), so a top-level `mattermost.reply_mode` is
    /// never bridged into `extra` and never reaches the adapter.
    @Test func mattermostReplyModeComesFromTheExtraBlock() {
        let c = HermesConfig(yaml: """
        platforms:
          mattermost:
            extra:
              reply_mode: thread  # per-post threads
        """)
        #expect(c.mattermost.replyMode == "thread")
        // The top-level spelling Hermes never reads must not be picked up.
        let topLevelOnly = HermesConfig(yaml: "mattermost:\n  reply_mode: thread\n")
        #expect(topLevelOnly.mattermost.replyMode == "off")
    }

    // MARK: - Approval modes (finding 7)

    /// `auto` was never a member of `approvals.mode` at ANY tag — walked from
    /// v2026.3.17 (v0.3.0) `tools/approval.py` to v2026.9.7
    /// `tools/approval_context.py:197` `_VALID_MODES = ("manual", "smart",
    /// "off")`, whose docstring names `'auto'` as the example of a value that
    /// warns and falls back to `manual`.
    @Test func approvalModeDropsAuto() {
        #expect(HermesApprovalMode.options == ["manual", "smart", "off"])
        #expect(!HermesApprovalMode.options.contains("auto"))
    }

    /// A config still carrying the `auto` Scarf itself used to write must
    /// render as the `manual` the host actually enforces — never as a blank
    /// picker (a selection outside its own option list).
    @Test func approvalModeNormalisesLikeHermes() {
        #expect(HermesApprovalMode.normalize("auto") == .manual)
        #expect(HermesApprovalMode.normalize("AUTO") == .manual)
        #expect(HermesApprovalMode.normalize("wat") == .manual)
        #expect(HermesApprovalMode.normalize("") == .manual)
        #expect(HermesApprovalMode.normalize(" Smart ") == .smart)
        #expect(HermesApprovalMode.normalize("off") == .off)
        // YAML 1.1 turns a bare `off` into a boolean; Hermes reads that back
        // as the `off` MODE (`_normalize_approval_mode`'s `isinstance(mode,
        // bool)` arm), so the false spelling must not land on `manual`.
        #expect(HermesApprovalMode.normalize("false") == .off)
        // …and the normalised value is always inside the picker's options,
        // which is the property that keeps the control from rendering blank.
        for raw in ["auto", "", "wat", "false", "SMART"] {
            #expect(HermesApprovalMode.options.contains(
                HermesApprovalMode.normalize(raw).rawValue))
        }
    }

    /// P29 · `false` was only ONE of PyYAML's falsy bool spellings. Hermes
    /// branches on `isinstance(mode, bool)` → `"off" if mode is False else
    /// "manual"` (`tools/approval_context.py:200,205-206` @ v2026.9.7), and
    /// PyYAML's YAML 1.1 resolver loads `no`/`No`/`NO` and `off`/`Off`/`OFF`
    /// as Python `False` exactly as it does `false`. So `approvals.mode: no`
    /// is the `off` mode upstream; Scarf's single-spelling arm read it as
    /// `manual` and the row announced "ask before every guarded command" on a
    /// host that never asks.
    ///
    /// Every spelling below was round-tripped through the real PyYAML, which
    /// is also how the `0`/`1` carve-out was found: those load as INTS, so
    /// neither of Hermes's `isinstance` arms matches and they fall through to
    /// `manual`.
    @Test func approvalModeResolvesEveryYAMLBoolSpellingLikePyYAML() {
        // Falsy bools → the `off` mode.
        for raw in ["false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF",
                    " no ", "\tno"] {
            #expect(HermesApprovalMode.normalize(raw) == .off,
                    "`approvals.mode: \(raw)` is PyYAML-false, i.e. the `off` mode")
        }
        // Truthy bools → `manual`, which is what `"manual" if mode is True` says.
        for raw in ["true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON",
                    " yes "] {
            #expect(HermesApprovalMode.normalize(raw) == .manual,
                    "`approvals.mode: \(raw)` is PyYAML-true, i.e. `manual`")
        }
        // NOT bools: `0`/`1` are ints and `~`/`null` is None, so Hermes's
        // type-switch misses all of them and returns `manual` — a liberal
        // boolish read of `0` as the `off` mode would be wrong here.
        for raw in ["0", "1", "~", "null", "Null", "NULL"] {
            #expect(HermesApprovalMode.normalize(raw) == .manual,
                    "`\(raw)` is not a YAML bool, so Hermes gives it `manual`")
        }
        // Near-misses are plain strings, so Hermes warns and falls back.
        for raw in ["nope", "offf", "00", "2", "y", "n", "t", "f"] {
            #expect(HermesApprovalMode.normalize(raw) == .manual,
                    "`\(raw)` is not a YAML bool")
        }
        // And every answer is still a pickable option.
        for raw in ["no", "on", "0", "1", "~", "nope"] {
            #expect(HermesApprovalMode.options.contains(
                HermesApprovalMode.normalize(raw).rawValue))
        }
    }

    // MARK: - Non-finite doubles (finding 10)

    /// `%.17g` spells a non-finite Double as the bare words `nan` / `inf`,
    /// which SQLite's tokenizer reads as IDENTIFIERS — `WHERE ts >= inf`
    /// fails "no such column: inf" on the REMOTE backend while the local one
    /// binds the same value happily.
    ///
    /// The literals chosen reproduce `sqlite3_bind_double` (what
    /// `LocalSQLiteBackend` calls) exactly, so the two backends answer the
    /// same query the same way: NaN binds as NULL, ±Infinity binds as a
    /// float and `9e999` is SQLite's own out-of-range float literal.
    @Test func nonFiniteRealsEncodeLikeBindDouble() {
        #expect(SQLValueInliner.encode(.real(Double.nan)) == "NULL")
        #expect(SQLValueInliner.encode(.real(Double.infinity)) == "9e999")
        #expect(SQLValueInliner.encode(.real(-Double.infinity)) == "-9e999")
        // Finite values are untouched.
        #expect(SQLValueInliner.encode(.real(0)) == "0")
        #expect(Double(SQLValueInliner.encode(.real(1_767_225_600.5))) == 1_767_225_600.5)
        // And the inliner never emits a bare identifier for a param.
        let sql = try? SQLValueInliner.inline(
            "SELECT ? , ?", params: [.real(Double.nan), .real(Double.infinity)])
        #expect(sql == "SELECT NULL , 9e999")
    }
}

/// Whole-surface audit P13, finding 10 — `LocalSQLiteBackend`'s detected-schema
/// flags are DERIVED state describing the file behind the current handle, not
/// knowledge that accumulates.
///
/// `detectSchema()` only ever set them to `true`, so once a wide state.db had
/// been read the flags stayed set across a `refresh()` onto a NARROWER file —
/// a v0.21.1 quarantine-and-recreate (`quarantine_zeroed_state_db`), a restore
/// from backup, or a Hermes downgrade — and every widened SELECT then failed
/// with "no such column".
struct LocalSQLiteBackendSchemaFlagResetP13Tests {

    private func writeDB(at url: URL, wide: Bool) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "open failed")
        }
        defer { sqlite3_close(db) }
        let sessions = wide
            ? "CREATE TABLE sessions (id TEXT PRIMARY KEY, reasoning_tokens INTEGER, rewind_count INTEGER);"
            : "CREATE TABLE sessions (id TEXT PRIMARY KEY);"
        let ddl = sessions + "\nCREATE TABLE messages (id INTEGER PRIMARY KEY);"
        guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
            throw TransportError.other(message: "ddl failed")
        }
    }

    @Test func replacingTheDBWithANarrowerOneClearsTheFlags() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-schema-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let context = ServerContext.local(home: home)
        let path = URL(fileURLWithPath: context.paths.stateDB)
        try writeDB(at: path, wide: true)

        let backend = LocalSQLiteBackend(context: context)
        #expect(await backend.refresh(forceFresh: true))
        #expect(await backend.hasV07Schema)
        #expect(await backend.hasRewindCountColumn)

        // Swap in a state.db WITHOUT those columns, exactly as a quarantine +
        // recreate leaves the path.
        try FileManager.default.removeItem(at: path)
        try writeDB(at: path, wide: false)
        #expect(await backend.refresh(forceFresh: true))
        #expect(!(await backend.hasV07Schema))
        #expect(!(await backend.hasRewindCountColumn))
        await backend.close()
    }

    /// A refresh whose reopen FAILS must report "no schema" rather than the
    /// last good file's — `close()` runs before `open()`, and a failed open
    /// never reaches `detectSchema()`.
    @Test func aFailedReopenLeavesNoStaleFlags() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-schema-reset-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let context = ServerContext.local(home: home)
        let path = URL(fileURLWithPath: context.paths.stateDB)
        try writeDB(at: path, wide: true)

        let backend = LocalSQLiteBackend(context: context)
        #expect(await backend.refresh(forceFresh: true))
        #expect(await backend.hasV07Schema)

        try FileManager.default.removeItem(at: path)
        _ = await backend.refresh(forceFresh: true)
        #expect(!(await backend.hasV07Schema))
        await backend.close()
    }
}
