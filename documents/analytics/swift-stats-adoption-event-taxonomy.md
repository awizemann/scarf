# swift-stats adoption — proposed event taxonomy (pre-implementation plan)

Date: 2026-08-20. Backend: SaaS api.swiftstats.co (write key in Keychain, vendor `swiftstats`). Package: github.com/awizemann/swift-stats, v0.2.0, macOS 15+/iOS 18+.

## Package facts that shaped the design
- `autoEvents: [.appOpen, .appBackground, .sessions]` cover launches/foreground/background/session duration — do not duplicate.
- Batch context (OS, device model, app version, locale, screen, color scheme, prerelease) sent once per batch under `.diagnostics` consent — never add these as props.
- Constraints: snake_case names `^[a-z][a-z0-9_]*$`; flat props ≤32 keys; strings ≤200 chars; NO free text, paths, URLs, hostnames, identifiers. StatsValue = String/Int/Double/Bool.
- `record()` is nonisolated fire-and-forget; `await track()` for durable-before-teardown. Consent groups: usage/diagnostics/identity. We will NOT call identify().
- Caution: README says hosted api.swiftstats.co "not open yet", self-hosting supported path; v0.2.0 needs Cloudflare migration 0003 — confirm endpoint accepts v0.2.0 wire format. Confirm Scarf deployment targets are ≥ macOS 15 / iOS 18.

## Consent posture (as implemented)

There is **no per-event consent routing** in the package — the groups gate layers, not individual events. `Analytics.makeConfiguration` spells the posture out explicitly (same value as `StatsConsent.default`, stated rather than inherited):

- `.usage` — **granted**. Gates event emission itself. **Every** event in this taxonomy rides this one group, including the "Diagnostics" section below. Denied → nothing is emitted at all.
- `.diagnostics` — **granted**. Gates only the per-batch context block (OS, device model, app version, locale, screen, color scheme). Denied → documented unknown values in that block; no event is suppressed.
- `.identity` — **never granted**. It would buy a stable cross-launch install id and a `userId` field; Scarf never calls `identify()`.

## Codebase seams
- ScarfMon (`Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfMon.swift`) is a pluggable event bus — add a StatsBackend; perf categories come free.
- Typed failure seams: `TransportErrors.swift` (`classifySSHFailure`), `SSHConnectionGate.swift` (circuit breaker, gh#138), `ConnectionStatusViewModel.Status`, `HermesCapabilitiesStore`, iOS `OnboardingViewModel` state machine.
- Lifecycle: macOS `NSApplication.didBecomeActive/didResignActive` in scarfApp.swift; iOS `ScarfGoCoordinator.setScenePhase`.
- Opt-out toggle next to the Telemetry row: `Features/Settings/Views/Tabs/AdvancedTab.swift` (macOS), `Scarf iOS/Settings/ScarfMonDiagnosticsView.swift` (iOS). Privacy manifests: declare Product Interaction + Other Diagnostic Data (no User ID).
- Recommend distinct appIds: `com.scarf.app` (macOS) and `com.scarf.ios` (ScarfGo).

## Event list

### Lifecycle
- auto: app_open, app_background, session_start/end
- first_run {platform}
- launch_completed {duration_bucket, server_count, warm}
- update_check_completed {result: up_to_date|available|failed}

### Connection & transport
- server_added {transport: ssh|local, key_source: generated|imported_pem|imported_openssh}
- server_removed {transport}
- connect_attempted / connect_succeeded {transport, duration_bucket}
- connect_failed {transport, error_kind: host_unreachable|auth_failed|host_key_mismatch|timeout|circuit_open|other}  ← classifySSHFailure
- circuit_breaker_opened / circuit_breaker_closed {failure_count, backoff_bucket}
- connection_degraded {cause: config_missing|home_missing|config_unreadable|profile_active|unknown}
- reconnect_attempted / reconnect_succeeded {trigger: wake|reachability|scene_active|manual, duration_bucket}

### Onboarding (iOS)
- onboarding_step {step: server_details|key_source|generate_key|import_key|show_public_key|connection_test|test_failed|done}
- onboarding_completed; onboarding_abandoned {last_step}

### Sessions & chat
- chat_session_started {mode: new|resume|continue_last, origin: chat|project|kanban|cron}
- session_resume_fallback {kind: new_session_fallback|history_fallback|sparse_transcript|slash_command_fallback}
- message_sent {has_attachment, input_mode: typed|voice|quick_command} — never content/length
- agent_turn_completed {duration_bucket, tool_call_count_bucket}
- agent_turn_failed {error_kind: connection_lost|timeout|agent_error}
- permission_prompt_responded {decision: approve|deny, surface: in_app|notification}
- model_preflight_result {outcome: passed|repaired|confirmed|cancelled|failed}

### Hermes compatibility
- hermes_version_detected {version, provisional}
- hermes_probe_failed {fallback: last_known|empty}
- hermes_control_action {action: start|stop|restart, source: menu_bar|health_panel, outcome}

### Feature usage
- section_viewed {section: SidebarSection/tab rawValue} — debounced first-visit-per-session
- project_created {template, method: scaffold|import}
- skill_installed / template_installed {source: hub|url} — **user-driven installs only**. `bundled` is NOT part of this vocabulary: the unattended launch bootstrap reports `skills_bootstrapped` instead (see below), so app-shipped copies can't drown user installs on a shared event name.
- skills_bootstrapped {count_bucket: 1|2_5|gt_5} — ONE event per `SkillBootstrapService` run that actually wrote ≥1 bundled skill. A run that wrote nothing (the steady state after first launch) is silent, matching `hermes_control_action`'s edge-triggered pattern.
- setting_changed {key (identifier only, never value), outcome}
- voice_used {kind: tts|push_to_talk}
- notification_toggled; deep_link_opened {kind: install_template|test}

### Diagnostics

Named for the *subject matter*, not a consent group: like every other event here these ride `.usage` consent. `.diagnostics` gates only the per-batch context block — see "Consent posture" above.

- perf_measure {category, duration_bucket} — thresholded/over-budget only, via ScarfMon backend
- crash_diagnostic_recorded (iOS) {kind: crash|hang|disk_write} — MetricKit counts only
- bootstrap_task_failed {task: skills|slash_commands|env_mirror}

### Never tracked
Message content/lengths, hostnames, file paths, project/session names, key material, raw error strings. All durations/counts as coarse bucket enums.

## Ship checklist (from package)
1. Wire lifecycle calls (macOS AppKit notifications, iOS scenePhase).
2. Visible opt-out: setEnabled(false) master switch + explicit consent in `makeConfiguration` (`[.usage, .diagnostics]`, never `.identity`).
3. Privacy manifest + nutrition label: Product Interaction, Other Diagnostic Data (no User ID — no identify()).
4. Pick installIdSalt once, never change. App supplies screenMetrics/colorScheme/isPreRelease to config.
