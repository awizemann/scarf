import Foundation
import ScarfCore
import Stats

/// The closed set of product-analytics events the macOS app may emit — the
/// typed spelling of the taxonomy in
/// `documents/analytics/swift-stats-adoption-event-taxonomy.md`.
///
/// **Why a type instead of a string.** `Analytics.record(_:props:)` used to
/// take a `String` name and a free-form prop dictionary, which meant the
/// privacy contract ("snake_case names from the taxonomy; bounded-cardinality
/// prop values; never user text, paths, hostnames or identifiers") was a
/// convention enforced only by review. Here it is enforced by the type
/// checker: the event set is closed, and *every* associated value is an enum
/// case or a bucket type whose only initializers run the vetted bucketing /
/// sanitizing helper. There is no way to spell a new event, or to smuggle a
/// raw `String` into a prop, without editing this file — which is exactly the
/// change that should be reviewed as a taxonomy change.
///
/// **Wire format is frozen.** ``name`` and ``props`` reproduce byte for byte
/// what the string call sites sent before this type existed; the parity table
/// in `AnalyticsFacadeTests` is the acceptance criterion. Adding a case is a
/// taxonomy change; renaming one is a break.
///
/// **Not the whole surface.** `ScarfCore` emits a handful of events of its own
/// through `ScarfAnalyticsRecording` and cannot see this type — see the note on
/// `Analytics.CoreBridge` for why that seam stays string-based.
nonisolated enum UsageEvent {

    // MARK: - Launch / lifecycle

    /// A detached launch bootstrap task threw.
    case bootstrapTaskFailed(task: BootstrapTask)
    /// A `scarf://` URL (or the XCUITest bypass for one) was routed.
    case deepLinkOpened(kind: DeepLinkKind)
    /// First launch this install has ever completed.
    case firstRun(platform: Platform)
    /// Every launch, once the window scene is built.
    case launchCompleted(durationBucket: DurationBucket, serverCountBucket: ServerCountBucket, warm: Bool)
    /// A bootstrap run that actually wrote skills into `~/.hermes`.
    case skillsBootstrapped(countBucket: SkillCountBucket)

    // MARK: - Hermes control

    /// Start / stop / restart from the menu bar or the Health panel.
    case hermesControlAction(action: ControlAction, source: ControlSource, outcome: Outcome)

    // MARK: - Servers / connection

    case serverAdded(transport: Transport)
    case serverRemoved(transport: Transport)
    case connectAttempted(transport: Transport)
    case connectSucceeded(transport: Transport, durationBucket: DurationBucket)
    case connectFailed(transport: Transport, errorKind: TransportErrorKind)
    case reconnectAttempted(trigger: ReconnectTrigger)
    case reconnectSucceeded(trigger: ReconnectTrigger, durationBucket: DurationBucket)

    // MARK: - Updates

    case updateCheckCompleted(result: UpdateCheckResult)

    // MARK: - Settings / navigation

    case settingChanged(key: SettingKeyToken, outcome: Outcome)
    case notificationToggled(enabled: Bool)
    case sectionViewed(section: SidebarSection)

    // MARK: - Chat

    case chatSessionStarted(mode: ChatSessionMode, origin: ChatSessionOrigin)
    case messageSent(hasAttachment: Bool, inputMode: ChatViewModel.ChatInputMode)
    case modelPreflightResult(outcome: ModelPreflightOutcome)
    case sessionResumeFallback(kind: SessionResumeFallbackKind)
    case permissionPromptResponded(decision: PermissionDecision)
    case voiceUsed(kind: VoiceKind)

    // MARK: - Projects / templates

    case projectCreated(template: ProjectTemplateKind, method: ProjectCreationMethod)
    case templateInstalled(source: InstallSource)
    case skillInstalled(source: InstallSource)

    // MARK: - Diagnostics

    case perfMeasure(category: ScarfMon.Category, durationBucket: DurationBucket)

    // MARK: - Wire format

    /// The snake_case event name. Frozen: these are the exact strings the
    /// string-based call sites sent.
    var name: String {
        switch self {
        case .bootstrapTaskFailed:      return "bootstrap_task_failed"
        case .deepLinkOpened:           return "deep_link_opened"
        case .firstRun:                 return "first_run"
        case .launchCompleted:          return "launch_completed"
        case .skillsBootstrapped:       return "skills_bootstrapped"
        case .hermesControlAction:      return "hermes_control_action"
        case .serverAdded:              return "server_added"
        case .serverRemoved:            return "server_removed"
        case .connectAttempted:         return "connect_attempted"
        case .connectSucceeded:         return "connect_succeeded"
        case .connectFailed:            return "connect_failed"
        case .reconnectAttempted:       return "reconnect_attempted"
        case .reconnectSucceeded:       return "reconnect_succeeded"
        case .updateCheckCompleted:     return "update_check_completed"
        case .settingChanged:           return "setting_changed"
        case .notificationToggled:      return "notification_toggled"
        case .sectionViewed:            return "section_viewed"
        case .chatSessionStarted:       return "chat_session_started"
        case .messageSent:              return "message_sent"
        case .modelPreflightResult:     return "model_preflight_result"
        case .sessionResumeFallback:    return "session_resume_fallback"
        case .permissionPromptResponded: return "permission_prompt_responded"
        case .voiceUsed:                return "voice_used"
        case .projectCreated:           return "project_created"
        case .templateInstalled:        return "template_installed"
        case .skillInstalled:           return "skill_installed"
        case .perfMeasure:              return "perf_measure"
        }
    }

    /// The flat prop dictionary. Every value here comes from an enum raw value
    /// or a bucket token — never from a caller-supplied string.
    var props: [String: StatsValue] {
        switch self {
        case .bootstrapTaskFailed(let task):
            return ["task": .string(task.rawValue)]
        case .deepLinkOpened(let kind):
            return ["kind": .string(kind.rawValue)]
        case .firstRun(let platform):
            return ["platform": .string(platform.rawValue)]
        case .launchCompleted(let duration, let servers, let warm):
            return [
                "duration_bucket": .string(duration.token),
                "server_count_bucket": .string(servers.token),
                "warm": .bool(warm),
            ]
        case .skillsBootstrapped(let count):
            return ["count_bucket": .string(count.token)]
        case .hermesControlAction(let action, let source, let outcome):
            return [
                "action": .string(action.rawValue),
                "source": .string(source.rawValue),
                "outcome": .string(outcome.rawValue),
            ]
        case .serverAdded(let transport), .serverRemoved(let transport),
             .connectAttempted(let transport):
            return ["transport": .string(transport.rawValue)]
        case .connectSucceeded(let transport, let duration):
            return [
                "transport": .string(transport.rawValue),
                "duration_bucket": .string(duration.token),
            ]
        case .connectFailed(let transport, let errorKind):
            return [
                "transport": .string(transport.rawValue),
                "error_kind": .string(errorKind.rawValue),
            ]
        case .reconnectAttempted(let trigger):
            return ["trigger": .string(trigger.rawValue)]
        case .reconnectSucceeded(let trigger, let duration):
            return [
                "trigger": .string(trigger.rawValue),
                "duration_bucket": .string(duration.token),
            ]
        case .updateCheckCompleted(let result):
            return ["result": .string(result.rawValue)]
        case .settingChanged(let key, let outcome):
            return [
                "key": .string(key.token),
                "outcome": .string(outcome.rawValue),
            ]
        case .notificationToggled(let enabled):
            return ["enabled": .bool(enabled)]
        case .sectionViewed(let section):
            return ["section": .string(section.analyticsToken)]
        case .chatSessionStarted(let mode, let origin):
            return [
                "mode": .string(mode.rawValue),
                "origin": .string(origin.rawValue),
            ]
        case .messageSent(let hasAttachment, let inputMode):
            // Deliberately a *string* "true"/"false", not `.bool` — this is
            // the shape the pre-enum call site sent and the wire format is
            // frozen.
            return [
                "has_attachment": .string(hasAttachment ? "true" : "false"),
                "input_mode": .string(inputMode.rawValue),
            ]
        case .modelPreflightResult(let outcome):
            return ["outcome": .string(outcome.rawValue)]
        case .sessionResumeFallback(let kind):
            return ["kind": .string(kind.rawValue)]
        case .permissionPromptResponded(let decision):
            return ["decision": .string(decision.rawValue)]
        case .voiceUsed(let kind):
            return ["kind": .string(kind.rawValue)]
        case .projectCreated(let template, let method):
            return [
                "template": .string(template.rawValue),
                "method": .string(method.rawValue),
            ]
        case .templateInstalled(let source), .skillInstalled(let source):
            return ["source": .string(source.rawValue)]
        case .perfMeasure(let category, let duration):
            return [
                "category": .string(category.rawValue),
                "duration_bucket": .string(duration.token),
            ]
        }
    }

    // MARK: - Coverage

    /// Every event name this enum can produce.
    ///
    /// Built by walking a chain of representative values rather than being
    /// written out as a literal set: ``nextForCoverage`` is an *exhaustive*
    /// `switch`, so adding a case to `UsageEvent` fails to compile until it is
    /// spliced into the chain. That is what makes the parity table's coverage
    /// test in `AnalyticsFacadeTests` a real guard — a new case with no parity
    /// row shows up here immediately, instead of the test comparing the table
    /// against a count derived from itself.
    static var allEventNames: Set<String> {
        var names: Set<String> = []
        var event: UsageEvent? = .bootstrapTaskFailed(task: .skills)
        // Every case has a distinct `name`, so a repeat means the chain was
        // mis-linked into a cycle. Stop rather than spin: the coverage test
        // then fails on a short set instead of hanging.
        while let current = event, names.insert(current.name).inserted {
            event = current.nextForCoverage
        }
        return names
    }

    /// The next link in the coverage chain, in declaration order; `nil` ends
    /// it. Associated values are arbitrary — only ``name`` is read.
    private var nextForCoverage: UsageEvent? {
        switch self {
        case .bootstrapTaskFailed:      return .deepLinkOpened(kind: .test)
        case .deepLinkOpened:           return .firstRun(platform: .macos)
        case .firstRun:                 return .launchCompleted(durationBucket: .init(seconds: 0),
                                                                serverCountBucket: .init(count: 0),
                                                                warm: false)
        case .launchCompleted:          return .skillsBootstrapped(countBucket: .init(count: 1))
        case .skillsBootstrapped:       return .hermesControlAction(action: .start,
                                                                    source: .menuBar,
                                                                    outcome: .succeeded)
        case .hermesControlAction:      return .serverAdded(transport: .local)
        case .serverAdded:              return .serverRemoved(transport: .local)
        case .serverRemoved:            return .connectAttempted(transport: .local)
        case .connectAttempted:         return .connectSucceeded(transport: .local,
                                                                 durationBucket: .init(seconds: 0))
        case .connectSucceeded:         return .connectFailed(transport: .local, errorKind: .other)
        case .connectFailed:            return .reconnectAttempted(trigger: .wake)
        case .reconnectAttempted:       return .reconnectSucceeded(trigger: .wake,
                                                                   durationBucket: .init(seconds: 0))
        case .reconnectSucceeded:       return .updateCheckCompleted(result: .available)
        case .updateCheckCompleted:     return .settingChanged(key: .init(rawKey: "model.default"),
                                                               outcome: .succeeded)
        case .settingChanged:           return .notificationToggled(enabled: true)
        case .notificationToggled:      return .sectionViewed(section: .dashboard)
        case .sectionViewed:            return .chatSessionStarted(mode: .new, origin: .chat)
        case .chatSessionStarted:       return .messageSent(hasAttachment: false, inputMode: .typed)
        case .messageSent:              return .modelPreflightResult(outcome: .passed)
        case .modelPreflightResult:     return .sessionResumeFallback(kind: .newSessionFallback)
        case .sessionResumeFallback:    return .permissionPromptResponded(decision: .approve)
        case .permissionPromptResponded: return .voiceUsed(kind: .tts)
        case .voiceUsed:                return .projectCreated(template: .custom, method: .scaffold)
        case .projectCreated:           return .templateInstalled(source: .hub)
        case .templateInstalled:        return .skillInstalled(source: .hub)
        case .skillInstalled:           return .perfMeasure(category: .sqlite,
                                                            durationBucket: .init(seconds: 0))
        case .perfMeasure:              return nil
        }
    }
}

// MARK: - Closed prop vocabularies
//
// One `String`-raw-valued enum per prop vocabulary. Raw values ARE the wire
// tokens — changing one is a taxonomy change.

nonisolated extension UsageEvent {
    enum BootstrapTask: String, CaseIterable, Sendable {
        case skills
        case slashCommands = "slash_commands"
        case envMirror = "env_mirror"
    }

    enum DeepLinkKind: String, CaseIterable, Sendable {
        /// XCUITest's `--scarf-test-install-url` bypass, never a real open.
        case test
        case installTemplate = "install_template"
    }

    enum Platform: String, CaseIterable, Sendable {
        case macos
    }

    enum ControlAction: String, CaseIterable, Sendable {
        case start, stop, restart
    }

    enum ControlSource: String, CaseIterable, Sendable {
        case menuBar = "menu_bar"
        case healthPanel = "health_panel"
    }

    /// The taxonomy's shared succeeded/failed outcome vocabulary.
    enum Outcome: String, CaseIterable, Sendable {
        case succeeded, failed

        /// The one place a `Bool` becomes an outcome token.
        init(succeeded: Bool) { self = succeeded ? .succeeded : .failed }
    }

    enum Transport: String, CaseIterable, Sendable {
        case ssh, local
    }

    enum ReconnectTrigger: String, CaseIterable, Sendable {
        case wake
        /// Emitted by `ScarfCore` through the string seam, listed here so the
        /// vocabulary is complete in one place.
        case manual
    }

    enum UpdateCheckResult: String, CaseIterable, Sendable {
        case available
        case upToDate = "up_to_date"
        case failed
    }

    enum ChatSessionMode: String, CaseIterable, Sendable {
        case new
        case resume
        case continueLast = "continue_last"
    }

    enum ChatSessionOrigin: String, CaseIterable, Sendable {
        case chat
        case project
        case errorRetry = "error_retry"
        /// A bot's canonical "Bot Chat", opened from the Bots section.
        case bots
    }

    enum ModelPreflightOutcome: String, CaseIterable, Sendable {
        case passed, repaired, confirmed, cancelled, failed

        /// Repaired-or-failed is the shape three banner fixes share.
        static func repairedOrFailed(_ ok: Bool) -> Self { ok ? .repaired : .failed }
        static func confirmedOrFailed(_ ok: Bool) -> Self { ok ? .confirmed : .failed }
    }

    enum SessionResumeFallbackKind: String, CaseIterable, Sendable {
        case newSessionFallback = "new_session_fallback"
        // The three below are emitted by `ScarfCore` through the string seam;
        // present for vocabulary completeness.
        case slashCommandFallback = "slash_command_fallback"
        case historyFallback = "history_fallback"
        case sparseTranscript = "sparse_transcript"
    }

    enum PermissionDecision: String, CaseIterable, Sendable {
        case approve, deny
    }

    enum VoiceKind: String, CaseIterable, Sendable {
        case tts
        case pushToTalk = "push_to_talk"
    }

    /// `project_created`'s `template` prop. Only `custom` is producible on
    /// macOS: the scaffold wizard has no template concept, and an imported
    /// template's id is author-controlled free text that must never ride along.
    enum ProjectTemplateKind: String, CaseIterable, Sendable {
        case custom
    }

    enum ProjectCreationMethod: String, CaseIterable, Sendable {
        case scaffold, `import`
    }

    /// `hub` = Browse Catalog; `url` = Install from URL, `scarf://install`
    /// deep links, and every local-file entry point.
    enum InstallSource: String, CaseIterable, Sendable {
        case hub, url
    }

    /// Case-derived `error_kind` for `connect_failed`, mirroring
    /// `TransportError.analyticsErrorKind` one-for-one so the two can't drift.
    enum TransportErrorKind: String, CaseIterable, Sendable {
        case hostUnreachable = "host_unreachable"
        case authFailed = "auth_failed"
        case hostKeyMismatch = "host_key_mismatch"
        case commandFailed = "command_failed"
        case fileIO = "file_io"
        case timeout
        case circuitOpen = "circuit_open"
        case other

        init(_ error: TransportError) {
            switch error {
            case .hostUnreachable:      self = .hostUnreachable
            case .authenticationFailed: self = .authFailed
            case .hostKeyMismatch:      self = .hostKeyMismatch
            case .commandFailed:        self = .commandFailed
            case .fileIO:               self = .fileIO
            case .timeout:              self = .timeout
            case .circuitOpen:          self = .circuitOpen
            case .other:                self = .other
            }
        }
    }
}

// MARK: - Bucket types
//
// Not enums, because their tokens are produced by the shared bucketing helpers
// in `ScarfCore`/`Analytics` and re-spelling the edges here would be a second
// source of truth that could drift. What they ARE is closed at the initializer:
// there is no `init(token:)`, so the only way to obtain one is to run the
// vetted helper on a raw number.

nonisolated extension UsageEvent {
    /// Coarse duration bucket (`lt_1s` … `gt_60s`).
    struct DurationBucket: Equatable, Sendable {
        let token: String
        init(seconds: TimeInterval) { token = ScarfAnalytics.durationBucket(seconds) }
        init(since start: Date) { self.init(seconds: Date().timeIntervalSince(start)) }
    }

    /// Coarse server-count bucket for `launch_completed`.
    struct ServerCountBucket: Equatable, Sendable {
        let token: String
        init(count: Int) { token = Analytics.serverCountBucket(count) }
    }

    /// Coarse count bucket for `skills_bootstrapped`.
    struct SkillCountBucket: Equatable, Sendable {
        let token: String
        init(count: Int) { token = SkillBootstrapService.bootstrapCountBucket(count) }
    }

    /// `setting_changed`'s `key`. The only initializer runs the
    /// all-or-nothing-per-segment sanitizer, so a config key that isn't already
    /// a bounded token can't leak a fragment of itself into a prop.
    struct SettingKeyToken: Equatable, Sendable {
        let token: String
        init(rawKey: String) { token = SettingsViewModel.analyticsSettingKey(rawKey) }
    }
}
