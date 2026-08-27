# swift-stats adoption — event taxonomy

Date: 2026-08-20, updated 2026-08-26 (Phases 1–3 landed). Backend: SaaS api.swiftstats.co. Package: github.com/awizemann/swift-stats, v0.2.0, macOS 15+/iOS 18+.

**Status note (2026-08-26):** this file is reconciled against the macOS app as of the analytics refactor (Phases 1–3, working tree). Items the code deliberately does not emit are marked **reserved / not emitted** rather than deleted — the name stays claimed so nothing else takes it, and so a later implementation lands on the documented shape.

## Key management (Phase 1)

The swift-stats write key is **no longer hardcoded in source**. It reaches the running app entirely through build settings:

```
scarf/Configs/SwiftStatsLocal.xcconfig  (gitignored, developer/CI-created)
    → SWIFT_STATS_WRITE_KEY (xcconfig build setting)
    → scarf/Configs/SwiftStats.xcconfig  (committed: empty default, then `#include?` of the local file)
    → target build configurations
    → Info.plist "SwiftStatsWriteKey" (build-setting expansion)
    → runtime read in Analytics.swift (Analytics.writeKey)
```

`Analytics.validWriteKey` gates the raw Info.plist value: `nil`, empty/whitespace-only, or anything still containing `$(` (an unexpanded build setting — what a checkout with no local xcconfig produces) is treated as invalid, and analytics degrades to a no-op for the whole process. Nothing is logged except the fact that the key was unusable — never its value.

The canonical rotated key lives in the Keychain vendor **`swift-stats-write-key`** (see `vendors/swift-stats-write-key.md`); the previously leaked, hardcoded key is being revoked. **The key must never appear in source, in this document, or in any committed file** — only in the gitignored local xcconfig and the Keychain vendor entry.

Practical consequence: a **release build shipped without `SwiftStatsLocal.xcconfig` present at build time ships with analytics off**, not with a stale/leaked key. CI and any release-signing environment must provision that file (or the equivalent build setting) before archiving. `scripts/release.sh` enforces this in its preflight: a missing local xcconfig, or one whose `SWIFT_STATS_WRITE_KEY` parses to empty, aborts the release before anything is built (the value itself is never printed).

## Enforcement mechanism (Phases 2–3): UsageEvent + UsageTracking

Phase 1 fixed how the key reaches the binary; Phases 2–3 close the other privacy gap — the taxonomy itself used to be enforced only by code review, since `Analytics.record(name:props:)` took a free `String` name and a free `[String: String]` prop dictionary.

- **`scarf/scarf/Core/Services/UsageEvent.swift`** — a closed `nonisolated enum` with one case per event (27 cases as of this refactor). Every associated value is either a closed, `String`-raw-valued prop-vocabulary enum (e.g. `Transport`, `Outcome`, `TransportErrorKind`) or a bucket struct (`DurationBucket`, `ServerCountBucket`, `SkillCountBucket`, `SettingKeyToken`) whose only initializer runs the vetted bucketing/sanitizing helper — there is no `init(token:)` back door. `name` and `props` reproduce the exact wire format the old string call sites sent, byte-for-byte; `UsageEventWireFormatTests` is the acceptance criterion, and adding a case is a taxonomy change while renaming one is a break. `UsageEvent.allEventNames` walks every case through an exhaustive `switch`, so a new case cannot compile until it is listed — which is what makes the parity table's coverage test a real guard rather than a self-referential count.
- **`scarf/scarf/Core/Services/UsageTracking.swift`** — the `UsageTracking` protocol (`record(_:)`, `recordOnce(_:key:)`, and a `record(rawName:props:)` escape hatch reserved for the ScarfCore bridge only) plus two implementations: `StatsUsageTracker.shared` (production — owns the single `StatsClient`) and `NoopUsageTracker` (reports nothing but still runs real once-per-key dedupe). `UsageOnceKeys` is the shared, lock-guarded dedupe set used by both.
- **`scarf/scarf/Core/Services/Analytics.swift`** is now a thin, `nonisolated`, lock-guarded forwarder over an installable tracker seam (default: `StatsUsageTracker.shared`). App call sites are unchanged — they still call `Analytics.record(...)` — but the event argument is a `UsageEvent`, so a new event can only be added by editing the closed enum. Tests swap the seam via `Analytics.install(_:)`; `scarfTests/CapturingUsageTracker.swift` is the test double. `Analytics.resetRecordedOnceForTesting()` is gone — dedupe state now lives on the installed tracker instance, so a fresh `CapturingUsageTracker` per test starts clean.
- **The `ScarfCore` seam (`ScarfAnalyticsRecording` / `Analytics.CoreBridge`) deliberately stays string-based.** `ScarfCore` is compiled without knowledge of the app target (the dependency runs app → package, never back), so it physically cannot name a `UsageEvent`; giving it a second, parallel closed enum would fork the taxonomy across two declarations that could silently drift. Its surface is a small, fixed set of event names emitted from a handful of call sites inside the package itself, none reachable from app code, and its `[String: String]` prop type already forbids anything but tokens — so the closure that matters ("no app-target call site can invent an event") is achieved by keeping the **installed tracker** (`Analytics.tracker`) `private`. `record(rawName:props:)` is still an ordinary requirement on the internal `UsageTracking` protocol, but the only handle on the installed tracker lives inside `Analytics`, and `CoreBridge` is nested there — so no other file can reach the raw entry point. The enum is not duplicated into the package.

## Accepted deviations from cross-app swift-stats conventions

These are deliberate product decisions (Alan), not TODOs to reconcile later:

1. **Keep Scarf's own event name `section_viewed`** rather than the cross-app convention's `view_shown`, and do not add the cross-app `via` prop. Scarf's sidebar-section semantics don't map cleanly onto the generic "view" concept the convention targets, and renaming would break the frozen wire-format/history for no analytical gain.
2. **No `error_shown` event.** Failures are tracked at the operation layer instead — e.g. `connect_failed`, `agent_turn_failed`, `bootstrap_task_failed`, `model_preflight_result(outcome: .failed)` — which carries the failing operation's own context (transport, error kind, category) that a generic `error_shown` event would lose.
3. **Keep `autoEvents: [.appOpen, .appBackground, .sessions]`** — in particular, `.appBackground` is retained rather than dropped. macOS has no true "did enter background" (a backgrounded Mac app keeps running), so `.appBackground` is the closest analogue to the session-gap/inactivity-timer behavior the package's session logic expects, and dropping it would silently change session-boundary semantics.
4. **`perf_measure`'s `category` prop is camelCase** (`chatRender`, `sqlite`, `transport`, `render`), not snake_case like every other prop token. It is `ScarfMon.Category.rawValue` verbatim, and it is what the string call site sent before `UsageEvent` existed — frozen-wire precedent, not a bug. Event *names* are snake_case-enforced; prop values are not.

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
- launch_completed {duration_bucket, **server_count_bucket**: 0|1|2_5|gt_5, warm} — bucketed, never a raw count (`scarfApp.swift`)
- update_check_completed {result: up_to_date|available|failed}

### Connection & transport
- server_added {transport: ssh|local} — `key_source` (generated|imported_pem|imported_openssh) is **reserved / not emitted**: it describes the iOS onboarding generate-or-import choice, which has no macOS analogue (the Mac defers to ssh-agent or an existing identity file), and a fabricated value would be worse than an absent prop (`ServerRegistry.swift`).
- server_removed {transport}
- connect_attempted / connect_succeeded {transport, duration_bucket}
- connect_failed {transport, error_kind: host_unreachable|auth_failed|host_key_mismatch|timeout|circuit_open|other}  ← classifySSHFailure
- circuit_breaker_opened / circuit_breaker_closed {failure_count, backoff_bucket}
- connection_degraded {cause: config_missing|home_missing|config_unreadable|profile_active|unknown}
- reconnect_attempted / reconnect_succeeded {trigger: wake|manual, duration_bucket} — `reachability` and `scene_active` are **reserved / not emitted** (iOS triggers; nothing emits them today). One pair per event, never per host.
  - `manual`: the connection pill / toolbar Retry, and only from a non-connected state (`ConnectionStatusViewModel`). Success = the probe reaching `.connected` **or** `.degraded` (SSH itself came back); `.error` resolves the attempt with no success.
  - `wake`: the post-sleep ControlMaster sweep (`WakeReconnectMetrics` in `scarfApp.swift`). An *attempt* is a host whose dead master had to be torn down — a wake where every master was still healthy emits **nothing**. Success = at least one socket verifiably gone afterwards (the next ssh handshakes fresh); a teardown that left the master in place is attempted-without-succeeded. `duration_bucket` covers the teardown work only — not the post-wake settle, not the probes of healthy hosts. (Before this release the sweep had this inverted: healthy masters were counted as successes and real recoveries were not.)

### Onboarding (iOS) — reserved / not emitted

**ScarfGo (iOS) emits no analytics events at all as of this release**: swift-stats is wired into the macOS target only. This section (and `crash_diagnostic_recorded` under Diagnostics) is the documented shape for whenever iOS is instrumented — nothing below exists in code today.

- onboarding_step {step: server_details|key_source|generate_key|import_key|show_public_key|connection_test|test_failed|done}
- onboarding_completed; onboarding_abandoned {last_step}

### Sessions & chat
- chat_session_started {mode: new|resume|continue_last, origin: chat|error_retry|project|kanban|cron}
  - `origin: error_retry` — the chat error banner's Reconnect button (`ChatView.swift`), which mechanically runs the same resume as the session list. Split out so failure recovery doesn't inflate ordinary resume counts.
- session_resume_fallback {kind: new_session_fallback|history_fallback|sparse_transcript|slash_command_fallback}
- message_sent {has_attachment, input_mode: typed|voice|quick_command} — never content/length
- agent_turn_completed {duration_bucket, tool_call_count_bucket}
- agent_turn_failed {error_kind: connection_lost|timeout|agent_error}
- permission_prompt_responded {decision: approve|deny} — `surface` (in_app|notification) is **reserved / not emitted**: the macOS prompt has only the in-app surface, so the prop would be a constant (`ChatViewModel.respondToPermission`).
- model_preflight_result {outcome: passed|repaired|confirmed|cancelled|failed}

### Hermes compatibility
- hermes_version_detected {version, provisional}
- hermes_probe_failed {fallback: last_known|empty}
- hermes_control_action {action: start|stop|restart, source: menu_bar|health_panel, outcome}

### Feature usage
- section_viewed {section: stable snake_case token, NOT the display rawValue — see SidebarSection.analyticsToken on macOS; iOS must use the same token vocabulary} — deduped first-visit-per-process. Deliberately NOT renamed to the cross-app `view_shown` convention — see "Accepted deviations" above.
- project_created {template, method: scaffold|import}
- skill_installed / template_installed {source: hub|url} — **user-driven installs only**. One `skill_installed` per skill directory the installer actually *wrote* (derived from the install plan's file copies), not per skill the manifest declares — installs are all-or-nothing, so a failed install emits neither event. `bundled` is NOT part of this vocabulary: the unattended launch bootstrap reports `skills_bootstrapped` instead (see below), so app-shipped copies can't drown user installs on a shared event name.
- skills_bootstrapped {count_bucket: 1|2_5|gt_5} — ONE event per `SkillBootstrapService` run that actually wrote ≥1 bundled skill. A run that wrote nothing (the steady state after first launch) is silent, matching `hermes_control_action`'s edge-triggered pattern.
- setting_changed {key (identifier only, never value), outcome}
- voice_used {kind: tts|push_to_talk}
- notification_toggled; deep_link_opened {kind: install_template|test}

### Diagnostics

Named for the *subject matter*, not a consent group: like every other event here these ride `.usage` consent. `.diagnostics` gates only the per-batch context block — see "Consent posture" above.

- perf_measure {category, duration_bucket} — thresholded/over-budget only, via ScarfMon backend. `category` is camelCase (e.g. `chatRender`) — see "Accepted deviations" #4.
- crash_diagnostic_recorded (iOS) {kind: crash|hang|disk_write} — MetricKit counts only. **Reserved / not emitted**: no MetricKit wiring exists, and iOS emits nothing at all (see Onboarding above).
- bootstrap_task_failed {task: skills|slash_commands|env_mirror}

### Never tracked
Message content/lengths, hostnames, file paths, project/session names, key material, raw error strings. All durations/counts as coarse bucket enums. **No `error_shown` event** — see "Accepted deviations" above.

## Ship checklist (from package)
1. Wire lifecycle calls (macOS AppKit notifications, iOS scenePhase).
2. Visible opt-out: setEnabled(false) master switch + explicit consent in `makeConfiguration` (`[.usage, .diagnostics]`, never `.identity`).
3. Privacy manifest + nutrition label: Product Interaction, Other Diagnostic Data (no User ID — no identify()).
4. Pick installIdSalt once, never change. App supplies screenMetrics/colorScheme/isPreRelease to config.
5. Release builds must have `scarf/Configs/SwiftStatsLocal.xcconfig` provisioned at archive time — see "Key management" above. `scripts/release.sh` preflight fails the release if it is missing or empty.
