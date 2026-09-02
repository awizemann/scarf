import Foundation
import Testing
import Stats
import StatsTesting
import ScarfCore
@testable import scarf

/// Covers the shape of the configuration `Analytics` ships — the same factory
/// the app's real client is built from — around an `InMemorySink` and a
/// `ManualClock`, so nothing here touches the network, the wall clock, or the
/// app's real Application Support directory.
/// Serialized on purpose: swift-stats persists the enabled/disabled choice in a
/// `UserDefaults` suite named after the **app id**, which every client built
/// from `Analytics.makeConfiguration` necessarily shares. Two of these tests
/// running concurrently would fight over that one switch. Each harness also
/// re-asserts the default (enabled) rather than trusting whatever a previous
/// run left behind.
@Suite("Analytics facade", .serialized)
struct AnalyticsFacadeTests {

    /// A client configured exactly as the app configures its own, but sinking
    /// into memory and storing in a throwaway directory.
    private func makeHarness() async -> (StatsClient, InMemorySink, ManualClock, URL) {
        let sink = InMemorySink()
        let clock = ManualClock()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-analytics-tests-\(UUID().uuidString)", isDirectory: true)
        let configuration = Analytics.makeConfiguration(
            sink: sink,
            isPreRelease: true,
            storageDirectory: directory,
            clock: clock
        )
        let client = StatsClient(configuration: configuration)
        await client.setEnabled(true)
        return (client, sink, clock, directory)
    }

    @Test("the shipping configuration is the one the taxonomy specifies")
    func configurationMatchesPlan() {
        let configuration = Analytics.makeConfiguration(sink: InMemorySink(), isPreRelease: true)
        #expect(configuration.appId == "com.scarf.app")
        #expect(configuration.projectId == "scarf")
        #expect(configuration.installIdSalt == "scarf-macos-2026")
        #expect(configuration.autoEvents == [.appOpen, .appBackground, .sessions])
        #expect(configuration.isPreRelease == true)
    }

    /// The write key is injected build-setting → Info.plist → runtime, so the
    /// one thing worth pinning is the validator that decides whether what came
    /// out of the bundle is usable. In particular an unexpanded `$(…)` — what a
    /// checkout with no `Configs/SwiftStatsLocal.xcconfig` produces — must be
    /// rejected rather than shipped to the endpoint as a literal key.
    @Test("write-key validator rejects missing, empty and unexpanded values")
    func writeKeyValidation() {
        #expect(Analytics.validWriteKey(nil) == nil)
        #expect(Analytics.validWriteKey("") == nil)
        #expect(Analytics.validWriteKey("   \n\t ") == nil)
        #expect(Analytics.validWriteKey("$(SWIFT_STATS_WRITE_KEY)") == nil)
        #expect(Analytics.validWriteKey("sk_stats_$(FOO)") == nil)
        #expect(Analytics.validWriteKey("  sk_stats_example  ") == "sk_stats_example")
    }

    /// No key literal may live in the app bundle's *source*. The Info.plist
    /// entry must be exactly the build-setting reference.
    @Test("Info.plist carries a build-setting reference, never a literal key")
    func infoPlistUsesBuildSetting() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf (project dir)
            .appendingPathComponent("scarf/Info.plist")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("<key>\(Analytics.writeKeyInfoPlistKey)</key>"))
        #expect(text.contains("$(SWIFT_STATS_WRITE_KEY)"))
        #expect(!text.contains("sk_stats_"))
    }

    @Test("record() reaches the sink, and app_open comes from the lifecycle hook")
    func recordsEvents() async throws {
        let (client, sink, _, directory) = await makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }

        await client.applicationDidBecomeActive()
        client.record("section_viewed", props: ["section": .string("chat")])
        await client.flush()
        await client.shutdown()

        let names = await sink.sentEventNames
        #expect(names.contains("app_open"))
        #expect(names.contains("section_viewed"))

        let recorded = try #require(await sink.sentEvents.first { $0.name == "section_viewed" })
        #expect(recorded.props["section"] == .string("chat"))
    }

    @Test("setEnabled(false) stops collection")
    func honorsOptOut() async throws {
        let (client, sink, _, directory) = await makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }

        await client.setEnabled(false)
        #expect(await client.isEnabled == false)

        await client.applicationDidBecomeActive()
        client.record("section_viewed", props: ["section": .string("chat")])
        await client.flush()
        await client.shutdown()

        #expect(await sink.sentEventNames.isEmpty)

        // Leave the shared, persisted switch back at its default so this test
        // cannot disable the next one that runs.
        await client.setEnabled(true)
    }

    @Test("re-enabling after opt-out resumes collection on the same client")
    func reenablingResumesCollection() async throws {
        let (client, sink, _, directory) = await makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }

        await client.setEnabled(false)
        #expect(await client.isEnabled == false)

        client.record("section_viewed", props: ["section": .string("chat")])
        await client.flush()
        #expect(await sink.sentEventNames.isEmpty)

        await client.setEnabled(true)
        #expect(await client.isEnabled == true)

        client.record("section_viewed", props: ["section": .string("chat")])
        await client.flush()
        await client.shutdown()

        let names = await sink.sentEventNames
        #expect(names.contains("section_viewed"))

        // Leave the shared, persisted switch back at its default so this test
        // cannot disable the next one that runs.
        await client.setEnabled(true)
    }
}

// MARK: - UsageEvent wire-format parity

/// Test-only stringification of a prop value, so a parity table can be written
/// as plain `[String: String]` literals matching the pre-enum call sites.
extension StatsValue {
    var usageEventToken: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
}

/// The acceptance criterion for the `UsageEvent` refactor: every case's derived
/// `name` and `props` must be byte-identical to what the string-based call
/// sites sent before the enum existed. Each row below was transcribed from the
/// literal that used to live at the call site — this is a wire-format contract,
/// not a restatement of `UsageEvent.props`.
@Suite("UsageEvent wire format")
struct UsageEventWireFormatTests {

    private struct Row {
        let event: UsageEvent
        let name: String
        let props: [String: String]
    }

    /// `duration_bucket`, `server_count_bucket`, `count_bucket` and the
    /// sanitized `setting_changed` key are produced by the shared helpers; the
    /// rows below pin the helper *output* for a fixed input, so a change to a
    /// bucket edge fails here too.
    private static let table: [Row] = [
        Row(event: .bootstrapTaskFailed(task: .skills),
            name: "bootstrap_task_failed", props: ["task": "skills"]),
        Row(event: .bootstrapTaskFailed(task: .slashCommands),
            name: "bootstrap_task_failed", props: ["task": "slash_commands"]),
        Row(event: .bootstrapTaskFailed(task: .envMirror),
            name: "bootstrap_task_failed", props: ["task": "env_mirror"]),
        Row(event: .deepLinkOpened(kind: .test),
            name: "deep_link_opened", props: ["kind": "test"]),
        Row(event: .deepLinkOpened(kind: .installTemplate),
            name: "deep_link_opened", props: ["kind": "install_template"]),
        Row(event: .firstRun(platform: .macos),
            name: "first_run", props: ["platform": "macos"]),
        Row(event: .launchCompleted(durationBucket: .init(seconds: 2),
                                    serverCountBucket: .init(count: 3),
                                    warm: true),
            name: "launch_completed",
            props: ["duration_bucket": "1_5s", "server_count_bucket": "2_5", "warm": "true"]),
        Row(event: .launchCompleted(durationBucket: .init(seconds: 0.1),
                                    serverCountBucket: .init(count: 1),
                                    warm: false),
            name: "launch_completed",
            props: ["duration_bucket": "lt_1s", "server_count_bucket": "1", "warm": "false"]),
        // The two `server_count_bucket` edges the rows above don't reach:
        // `Analytics.serverCountBucket` maps `..<1 → "0"` and `>5 → "gt_5"`.
        Row(event: .launchCompleted(durationBucket: .init(seconds: 0.1),
                                    serverCountBucket: .init(count: 0),
                                    warm: false),
            name: "launch_completed",
            props: ["duration_bucket": "lt_1s", "server_count_bucket": "0", "warm": "false"]),
        Row(event: .launchCompleted(durationBucket: .init(seconds: 0.1),
                                    serverCountBucket: .init(count: 6),
                                    warm: true),
            name: "launch_completed",
            props: ["duration_bucket": "lt_1s", "server_count_bucket": "gt_5", "warm": "true"]),
        Row(event: .skillsBootstrapped(countBucket: .init(count: 4)),
            name: "skills_bootstrapped", props: ["count_bucket": "2_5"]),
        // `SkillBootstrapService.bootstrapCountBucket`'s top edge: >5 → "gt_5".
        Row(event: .skillsBootstrapped(countBucket: .init(count: 6)),
            name: "skills_bootstrapped", props: ["count_bucket": "gt_5"]),
        Row(event: .hermesControlAction(action: .start, source: .menuBar, outcome: .succeeded),
            name: "hermes_control_action",
            props: ["action": "start", "source": "menu_bar", "outcome": "succeeded"]),
        Row(event: .hermesControlAction(action: .stop, source: .healthPanel, outcome: .failed),
            name: "hermes_control_action",
            props: ["action": "stop", "source": "health_panel", "outcome": "failed"]),
        Row(event: .hermesControlAction(action: .restart, source: .menuBar, outcome: .init(succeeded: true)),
            name: "hermes_control_action",
            props: ["action": "restart", "source": "menu_bar", "outcome": "succeeded"]),
        Row(event: .serverAdded(transport: .ssh),
            name: "server_added", props: ["transport": "ssh"]),
        Row(event: .serverRemoved(transport: .local),
            name: "server_removed", props: ["transport": "local"]),
        Row(event: .serverRemoved(transport: .ssh),
            name: "server_removed", props: ["transport": "ssh"]),
        Row(event: .connectAttempted(transport: .ssh),
            name: "connect_attempted", props: ["transport": "ssh"]),
        Row(event: .connectSucceeded(transport: .ssh, durationBucket: .init(seconds: 20)),
            name: "connect_succeeded", props: ["transport": "ssh", "duration_bucket": "15_60s"]),
        Row(event: .connectFailed(transport: .ssh, errorKind: .authFailed),
            name: "connect_failed", props: ["transport": "ssh", "error_kind": "auth_failed"]),
        Row(event: .reconnectAttempted(trigger: .wake),
            name: "reconnect_attempted", props: ["trigger": "wake"]),
        Row(event: .reconnectSucceeded(trigger: .wake, durationBucket: .init(seconds: 2)),
            name: "reconnect_succeeded", props: ["trigger": "wake", "duration_bucket": "1_5s"]),
        Row(event: .updateCheckCompleted(result: .available),
            name: "update_check_completed", props: ["result": "available"]),
        Row(event: .updateCheckCompleted(result: .upToDate),
            name: "update_check_completed", props: ["result": "up_to_date"]),
        Row(event: .updateCheckCompleted(result: .failed),
            name: "update_check_completed", props: ["result": "failed"]),
        Row(event: .settingChanged(key: .init(rawKey: "model.default"), outcome: .succeeded),
            name: "setting_changed", props: ["key": "model.default", "outcome": "succeeded"]),
        Row(event: .settingChanged(key: .init(rawKey: "model./Users/someone/x"), outcome: .failed),
            name: "setting_changed", props: ["key": "model.unknown", "outcome": "failed"]),
        Row(event: .notificationToggled(enabled: true),
            name: "notification_toggled", props: ["enabled": "true"]),
        Row(event: .notificationToggled(enabled: false),
            name: "notification_toggled", props: ["enabled": "false"]),
        Row(event: .sectionViewed(section: .quickCommands),
            name: "section_viewed", props: ["section": "quick_commands"]),
        Row(event: .chatSessionStarted(mode: .new, origin: .project),
            name: "chat_session_started", props: ["mode": "new", "origin": "project"]),
        Row(event: .chatSessionStarted(mode: .resume, origin: .errorRetry),
            name: "chat_session_started", props: ["mode": "resume", "origin": "error_retry"]),
        Row(event: .chatSessionStarted(mode: .continueLast, origin: .chat),
            name: "chat_session_started", props: ["mode": "continue_last", "origin": "chat"]),
        Row(event: .messageSent(hasAttachment: false, inputMode: .typed),
            name: "message_sent", props: ["has_attachment": "false", "input_mode": "typed"]),
        Row(event: .messageSent(hasAttachment: true, inputMode: .quickCommand),
            name: "message_sent", props: ["has_attachment": "true", "input_mode": "quick_command"]),
        Row(event: .modelPreflightResult(outcome: .passed),
            name: "model_preflight_result", props: ["outcome": "passed"]),
        Row(event: .modelPreflightResult(outcome: .repairedOrFailed(true)),
            name: "model_preflight_result", props: ["outcome": "repaired"]),
        Row(event: .modelPreflightResult(outcome: .repairedOrFailed(false)),
            name: "model_preflight_result", props: ["outcome": "failed"]),
        Row(event: .modelPreflightResult(outcome: .confirmedOrFailed(true)),
            name: "model_preflight_result", props: ["outcome": "confirmed"]),
        Row(event: .modelPreflightResult(outcome: .cancelled),
            name: "model_preflight_result", props: ["outcome": "cancelled"]),
        Row(event: .sessionResumeFallback(kind: .newSessionFallback),
            name: "session_resume_fallback", props: ["kind": "new_session_fallback"]),
        Row(event: .permissionPromptResponded(decision: .approve),
            name: "permission_prompt_responded", props: ["decision": "approve"]),
        Row(event: .permissionPromptResponded(decision: .deny),
            name: "permission_prompt_responded", props: ["decision": "deny"]),
        Row(event: .voiceUsed(kind: .tts),
            name: "voice_used", props: ["kind": "tts"]),
        Row(event: .voiceUsed(kind: .pushToTalk),
            name: "voice_used", props: ["kind": "push_to_talk"]),
        Row(event: .projectCreated(template: .custom, method: .scaffold),
            name: "project_created", props: ["template": "custom", "method": "scaffold"]),
        Row(event: .projectCreated(template: .custom, method: .import),
            name: "project_created", props: ["template": "custom", "method": "import"]),
        Row(event: .templateInstalled(source: .hub),
            name: "template_installed", props: ["source": "hub"]),
        Row(event: .templateInstalled(source: .url),
            name: "template_installed", props: ["source": "url"]),
        Row(event: .skillInstalled(source: .hub),
            name: "skill_installed", props: ["source": "hub"]),
        Row(event: .skillInstalled(source: .url),
            name: "skill_installed", props: ["source": "url"]),
        Row(event: .botCreated(method: .created, outcome: .succeeded),
            name: "bot_created", props: ["method": "created", "outcome": "succeeded"]),
        Row(event: .botCreated(method: .madeFromProfile, outcome: .failed),
            name: "bot_created", props: ["method": "made_from_profile", "outcome": "failed"]),
        Row(event: .botUpdated(aspect: .identity, outcome: .succeeded),
            name: "bot_updated", props: ["aspect": "identity", "outcome": "succeeded"]),
        Row(event: .botUpdated(aspect: .avatar, outcome: .failed),
            name: "bot_updated", props: ["aspect": "avatar", "outcome": "failed"]),
        Row(event: .botUpdated(aspect: .modelPin, outcome: .succeeded),
            name: "bot_updated", props: ["aspect": "model_pin", "outcome": "succeeded"]),
        Row(event: .botUpdated(aspect: .toolsets, outcome: .init(succeeded: true)),
            name: "bot_updated", props: ["aspect": "toolsets", "outcome": "succeeded"]),
        Row(event: .botUpdated(aspect: .mcp, outcome: .init(succeeded: false)),
            name: "bot_updated", props: ["aspect": "mcp", "outcome": "failed"]),
        Row(event: .botUpdated(aspect: .soul, outcome: .succeeded),
            name: "bot_updated", props: ["aspect": "soul", "outcome": "succeeded"]),
        Row(event: .botRemoved(kind: .deleted),
            name: "bot_removed", props: ["kind": "deleted"]),
        Row(event: .botRemoved(kind: .identityRemoved),
            name: "bot_removed", props: ["kind": "identity_removed"]),
        Row(event: .botRemoved(kind: .hidden),
            name: "bot_removed", props: ["kind": "hidden"]),
        Row(event: .botRoutineAction(action: .created, outcome: .succeeded),
            name: "bot_routine_action", props: ["action": "created", "outcome": "succeeded"]),
        Row(event: .botRoutineAction(action: .deleted, outcome: .failed),
            name: "bot_routine_action", props: ["action": "deleted", "outcome": "failed"]),
        Row(event: .botPeerAction(action: .dmSent),
            name: "bot_peer_action", props: ["action": "dm_sent"]),
        Row(event: .botPeerAction(action: .asyncRun),
            name: "bot_peer_action", props: ["action": "async_run"]),
        Row(event: .perfMeasure(category: .sqlite, durationBucket: .init(seconds: 0.5)),
            name: "perf_measure", props: ["category": "sqlite", "duration_bucket": "lt_1s"]),
    ]

    @Test("every UsageEvent case derives the exact legacy name and props")
    func wireFormatMatchesLegacyStrings() {
        for row in Self.table {
            #expect(row.event.name == row.name)
            #expect(row.event.props.mapValues(\.usageEventToken) == row.props,
                    "props drift for \(row.name)")
        }
    }

    /// A guard against a case being added to `UsageEvent` without a parity
    /// row: the table must cover every event *name* the app can emit.
    ///
    /// Compared against `UsageEvent.allEventNames` — derived from an
    /// exhaustive `switch` in the enum itself — rather than a count taken from
    /// the table, which would have made this test pass for any table at all.
    @Test("the parity table covers every event name in the enum")
    func tableCoversEveryEventName() {
        let covered = Set(Self.table.map(\.name))
        #expect(covered == UsageEvent.allEventNames)
    }

    /// `UsageEvent.TransportErrorKind` restates, in the app target, the tokens
    /// `TransportError.analyticsErrorKind` produces in `ScarfCore`
    /// (`ScarfCore/Transport/TransportErrors.swift`, `analyticsErrorKind`).
    /// Walk every kind, build a `TransportError` that must map to it, and
    /// assert both directions — so neither list can gain, lose or rename a
    /// token without the other following.
    @Test("every TransportErrorKind mirrors TransportError.analyticsErrorKind")
    func transportErrorKindsMirrorScarfCore() {
        func sample(for kind: UsageEvent.TransportErrorKind) -> TransportError {
            switch kind {
            case .hostUnreachable:  return .hostUnreachable(host: "h", stderr: "e")
            case .authFailed:       return .authenticationFailed(host: "h", stderr: "e")
            case .hostKeyMismatch:  return .hostKeyMismatch(host: "h", stderr: "e")
            case .commandFailed:    return .commandFailed(exitCode: 1, stderr: "e")
            case .fileIO:           return .fileIO(path: "/p", underlying: "e")
            case .timeout:          return .timeout(seconds: 1, partialStdout: Data())
            case .circuitOpen:      return .circuitOpen(host: "h", retryAt: Date())
            case .other:            return .other(message: "m")
            }
        }

        for kind in UsageEvent.TransportErrorKind.allCases {
            let error = sample(for: kind)
            #expect(error.analyticsErrorKind == kind.rawValue,
                    "token drift for \(kind)")
            #expect(UsageEvent.TransportErrorKind(error) == kind,
                    "classification drift for \(kind)")
        }
    }

    /// Four vocabulary tokens the app-target enum lists for completeness but
    /// never emits: `ScarfCore` sends them through the *string* seam, so the
    /// enum's raw value is a copy that nothing else checks. Pin each one to
    /// the literal at its emitting call site:
    ///
    /// - `reconnect_attempted {trigger: "manual"}` —
    ///   `ScarfCore/ViewModels/ConnectionStatusViewModel.swift:135`
    /// - `session_resume_fallback {kind: "slash_command_fallback"}` —
    ///   `ScarfCore/ViewModels/RichChatViewModel.swift:1522`
    /// - `… {kind: "history_fallback"}` — `RichChatViewModel.swift:2313`
    /// - `… {kind: "sparse_transcript"}` — `RichChatViewModel.swift:2325`
    @Test("tokens ScarfCore emits through the string seam match the enum's raw values")
    func packageEmittedTokensMatchVocabulary() {
        #expect(UsageEvent.ReconnectTrigger.manual.rawValue == "manual")
        #expect(UsageEvent.SessionResumeFallbackKind.slashCommandFallback.rawValue
                == "slash_command_fallback")
        #expect(UsageEvent.SessionResumeFallbackKind.historyFallback.rawValue
                == "history_fallback")
        #expect(UsageEvent.SessionResumeFallbackKind.sparseTranscript.rawValue
                == "sparse_transcript")
    }

    /// Names are the wire identity — snake_case, `^[a-z][a-z0-9_]*$`.
    @Test("every event name is a valid taxonomy token")
    func namesAreSnakeCase() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        for row in Self.table {
            #expect(row.name.unicodeScalars.allSatisfy(allowed.contains))
            #expect(row.name.first?.isLetter == true)
        }
    }
}
