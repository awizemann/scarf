---
title: ScarfGo-Roadmap
type: note
permalink: scarf-wiki/scarf-go-roadmap
created: 2026-05-29
updated: 2026-05-29
---

# ScarfGo — Roadmap & development reference

> **Looking for the user guide?** See **[ScarfGo](ScarfGo)**. This page tracks engineering milestones (M6 / M7 / M8 / M9) and the pass-1 / pass-2 smoke-test punch list — useful for contributors and history, less useful for users.

ScarfGo is the on-the-go iPhone companion to [Scarf](Home). Its scope is deliberately narrower than the Mac app: **remotely manage and interact with a running Hermes agent** from your phone. It is **not** a feature-parity port — Mac handles the full operator surface; ScarfGo handles what's valuable away from a desk.

**Current state:** **public TestFlight** as of v2.5. M6 → M7 → M8 → M9 all shipped. See [Known Issues](#known-issues) below for residual items + this page for the historical milestone narrative.

**Tech stack:**

- **Transport:** pure-Swift SSH via [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.x — no OpenSSH client subprocess (iOS sandbox).
- **Shared core:** `ScarfCore` SPM package — Models / Transport / Services / ViewModels portable across macOS and iOS, unit-tested on Linux in CI.
- **iOS-only code:** `ScarfIOS` package (Citadel glue, Keychain key storage) + `Scarf iOS/` SwiftUI views.
- **Target:** iPhone-only, iOS 18+. v2.5 ships with `TARGETED_DEVICE_FAMILY = 1`, `SUPPORTS_MACCATALYST = NO`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`, `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = NO`. iPad and Catalyst flags are explicitly OFF until layout polish lands (M10+).

## What's shipped today (M6)

| Feature | Behavior |
|---|---|
| **Onboarding** | 8-step: host form → generate or import Ed25519 → show public key → you add to `~/.ssh/authorized_keys` → test probe → done. Single server v1 — multi-server in M9. |
| **Dashboard** | Session count, message count, tool-call count, token totals, last 5 sessions. Pulled from remote `~/.hermes/state.db` via `sqlite3 .backup` + SFTP download (WAL-safe snapshot). |
| **Chat** | Real-time ACP over a dedicated SSH exec channel. Markdown, tool-call cards, permission sheets, reasoning disclosure, streaming. **No** embedded terminal — rich chat only. |
| **Memory** | Read + write MEMORY.md, USER.md, SOUL.md (SOUL is in the Personalities feature on Mac; on iOS we fold it in here because you rarely want them separately on a phone). |
| **Cron** | List jobs, toggle enabled/disabled, edit schedule / prompt / skills / delivery route, add new, swipe-to-delete. Writes `~/.hermes/cron/jobs.json` atomically. |
| **Skills** | Read-only browse — categories + skill files per skill. |
| **Settings** | Read-only view of `config.yaml` grouped by section. Editing deferred — see M9. |

## Deliberately not on ScarfGo

- **Analytics features** (Activity, Logs, Health, Insights) — belong on the Mac where screen real-estate supports them.
- **Full-surface configuration** (CredentialPools, Gateway, Templates, MCP Servers, Platforms, Plugins, Profiles, Personalities, Tools, Webhooks, QuickCommands) — config flows live on the Mac. On the go you want to run and interact, not configure.
- **Terminal mode** (embedded SwiftTerm) — out of scope for a chat-first companion.
- **Local Hermes** — iOS can't spawn subprocesses (sandbox). ScarfGo is remote-only by design.

## Roadmap

### M7 — Stabilization (pre-TestFlight)

Bug fixes only, no new features. Unblocks the first internal TestFlight build. See the full issue list in [Known Issues](#known-issues).

### M8 — UX density pass

ScarfGo is a developer tool; it needs to show more on-screen than Apple's spacious defaults. Research-driven changes:

- Migrate root navigation from "Dashboard-is-hub" to a `TabView` with `.sidebarAdaptable` style — Chat, Dashboard, Memory, More. Primary nav stops hiding below the fold.
- Clamp Dynamic Type at scene root: `.dynamicTypeSize(.xSmall ... .accessibility2)`. Semantic fonts + `@ScaledMetric`.
- Tighten list density — `.listRowSpacing(0)` + 6pt vertical insets + `.defaultMinListRowHeight(36)`, preserving 44pt hit targets via `.contentShape(Rectangle()).frame(minHeight: 44)`.
- Chat code blocks: horizontal scroll inside bubble, never wrap, `maxHeight: 240` + Expand.
- Chat tool calls: `DisclosureGroup` collapsed; title = action + elapsed ms.
- Chat scroll anchoring: iOS 18 `.defaultScrollAnchor(.bottom, for: .sizeChanges)` + suspend auto-follow on user scroll-up + "↓ new messages" pill.
- Message/row actions via `.contextMenu` — not visible buttons.
- Sheets with custom peek detents (`.presentationDetents([.height(180), .large])`) — never `.medium`.

### M9 — On-the-go essentials

Features that only make sense on mobile, in priority order:

1. **Multi-server support.** Root becomes a server list (nickname + host + status pill). Each server has two actions: **Disconnect** (soft — closes live transport, keeps Keychain key + config, one-tap to reconnect) and **Forget** (destructive — wipes credentials, re-onboards). The underlying transport factory is already `ServerID`-keyed; changes are storage layer + root nav + onboarding entry point.
2. **Project-scoped chat.** The `+` button in Chat opens a picker: "Quick chat" (default) or "In project…" — SFTP-read `~/.hermes/scarf/projects.json`, pick one, SFTP-write the scarf-managed project-context block into `<project>/AGENTS.md`, spawn `hermes acp` with `cwd = project.path`. After session id comes back, SFTP-write the attribution row into `session_project_map.json`. Unlocks the iOS parity of `ProjectAgentContextService` + `SessionAttributionService`.
3. **Session resume.** Dashboard's Recent Sessions list becomes tappable — taps call `ACPClient.loadSession(id:)` instead of starting a new session. Resume a conversation that was started on a Mac, continue it on the phone.
4. **APNs push — cron completion + pending permissions.** Notification for "your cron just ran" or "your agent needs approval to run X." The client half is ~200 LOC; the Hermes-side sender is a separate upstream feature.
5. **Lock-screen quick-approve.** Notification action button for "Approve" / "Deny" on pending permissions so the agent keeps running while you're away from the app.
6. **Scoped Settings editor.** Not a generic YAML round-trip editor — a curated set of high-value fields (model / provider / approval mode / max turns / display toggles) that save via `hermes config set <key> <value>` over SSH exec. Hermes owns the YAML round-trip; Scarf just picks values.

### M10 — TestFlight ✅ Shipped (v2.5)

App Store Connect + Apple Distribution cert + Apple Developer Program enrollment + privacy policy live at `awizemann.github.io/scarf/privacy/`. Public TestFlight live at <https://testflight.apple.com/join/qCrRpcTz> — accepts new joiners after Apple's Beta Review approves the first build (24–48h queue). See [TESTFLIGHT_CHECKLIST.md](https://github.com/awizemann/scarf/blob/main/releases/v2.5.0/TESTFLIGHT_CHECKLIST.md) for the submission flow + [APP_STORE_METADATA.md](https://github.com/awizemann/scarf/blob/main/releases/v2.5.0/APP_STORE_METADATA.md) for the public App Store metadata bundle (description, keywords, support URL, etc.) staged for the eventual public release.

### M11+ — Post-TestFlight feedback loop

- Iterate on TestFlight feedback over v2.5.x patches.
- iPad layout polish (flip device family flag + verify).
- Cron editor on iOS — adds the editor sheet that's missing in v2.5.
- iOS localization — translate the strings the Mac already has.
- Push notifications — flip the capability + deploy Hermes-side push sender.
- Deeper Insights / Activity views, scaled to phone screen sizes.

## Known Issues

All tracked from the 2026-04-24 pass-1 smoke test. This list is the truth about what's broken today — filed publicly in the interest of transparency. A ✅ means the fix has already landed on the `scarf-mobile-development` branch.

### Blocking TestFlight — must fix in M7

| # | Summary | Scope | Status |
|---|---|---|---|
| 1 | **Primary navigation hidden below Dashboard fold.** Chat / Memory / Cron / Skills / Settings links lived as the 4th section in a `List`. Replaced with `.tabViewStyle(.sidebarAdaptable)` root: 4 primary tabs (Chat / Dashboard / Memory / More) + collapse to sidebar on iPadOS later with zero UI code change. | ScarfGo | ✅ Fixed |
| 2 | **Non-retryable provider errors → perpetual spinner.** ACP error triplet (`acpError`, `acpErrorHint`, `acpErrorDetails`) promoted to ScarfCore so Mac + ScarfGo share state; ChatView renders an inline banner with Copy Details / Expand. `handlePromptComplete` now calls `recordPromptStopFailureUsingProvider(stopReason:)` on non-`end_turn` stops with the stderr tail appended. | Cross-platform | ✅ Fixed |
| 3 | **No connecting feedback when entering Chat.** ChatController's existing `.connecting` state now drives a `.regularMaterial` overlay with "Connecting to <nickname>…" + ProgressView. | ScarfGo | ✅ Fixed |
| 4 | **`isAgentWorking` doesn't clear after primary response.** Split into computed `isGenerating` (agent still producing text) + `isPostProcessing` (agent done producing; ACP `promptComplete` not yet fired). Prominent spinner drops as soon as the reply is visible; subtle "Finishing up…" pill covers auxiliary post-work. Applied cross-platform. | Cross-platform | ✅ Fixed |
| 5 | **ACP command missing PATH prefix.** SSH exec runs a non-interactive shell whose PATH is `/usr/bin:/bin:/usr/sbin:/sbin`. Fixed by prepending the three most common pipx + Homebrew install locations (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) to PATH inline on every Citadel `runProcess` and `SSHExecACPChannel` invocation. Self-install layouts at `~/.hermes/bin` need the per-server **Hermes binary hint** override. | ScarfGo | ✅ Fixed |
| 6 | **SFTP `~` tilde not expanded.** Per-connection cached `resolveHome()` on `ConnectionHolder` + `resolveSFTPPath()` helper applied to every SFTP entry point (`readFile` / `writeFile` / `fileExists` / `stat` / `listDirectory` / `createDirectory` / `removeFile`). | ScarfGo | ✅ Fixed |
| 7 | **No loading state on Memory editor.** Switched to throwing read (#8) so `lastError` populates on real failures instead of silently showing "empty" — the existing error banner now renders. | ScarfGo | ✅ Fixed |
| 8 | **`ServerContext.readText` swallows errors.** New `readTextThrowing(_:)` distinguishes "file absent" from "transport error"; old nil-returning `readText` stays as a `try?` shim for callers that really don't care. Memory editor uses the throwing variant. | Cross-platform | ✅ Fixed |
| 9 | **TextEditor keyboard obscures cursor.** `.scrollDismissesKeyboard(.interactively)` on the TextEditor, error pill + Saved pill moved into `.safeAreaInset(edge: .bottom)` so SwiftUI draws them above the keyboard. | ScarfGo | ✅ Fixed |
| 10 | **Save confirmation not visible.** Saved pill is now a full-width material strip inside `.safeAreaInset`, holds 2.5s (up from 1.5s), and cancels any in-flight hide task on subsequent saves so rapid saves don't drop the pill mid-fade. | ScarfGo | ✅ Fixed |
| 11 | **Cron schedule + next-run shown as machine formats.** New `CronScheduleFormatter` in ScarfCore translates the common cron shapes (every N minutes / hourly / daily at H / weekdays at H / weekends / specific weekday / monthly on day D + @-macros) into English phrases and falls back to raw expression on unrecognised shapes. Sibling `formatNextRun(iso:)` parses Hermes's ISO-8601 next-run and renders `"in 4 hours"` etc. 17 unit tests. Applied Mac + ScarfGo. | Cross-platform | ✅ Fixed |
| 12 | **"Disconnect" is factory reset.** Split properly into **Disconnect** (soft — keeps Keychain key + config, returns to ServerListView, next tap reconnects with no re-onboarding) and **Forget** (hard — removes that server's key + config, returns to list or onboarding if list becomes empty). Lives on the More tab. | ScarfGo | ✅ Fixed |

### Cross-platform (fix on Mac too)

- **Model picker accepts unknown models.** `ModelCatalogService.validateModel(_:for:)` returns `.valid` / `.unknownProvider(id)` / `.invalid(providerName, suggestions)`. Overlay-only providers (Nous / OpenAI Codex / Qwen OAuth) short-circuit to `.valid` because their catalogs aren't in models.dev. Mac `ModelPickerSheet.submitSelection` routes through the validator and raises an alert with suggestions on `.invalid`. 5 unit tests. — ✅ Fixed

### Hermes-side (upstream, not ours)

- Auxiliary `title_generation` appears to hang when the main provider returns a 404 — likely retries the failed call. Worth filing upstream; causes bug #4 to manifest. — still open upstream.

## Post-pass-1 feature work

The pass-1 session also surfaced the user-facing roadmap we delivered through M8 (UX density) and M9 (on-the-go features):

### M8 — UX density (all shipped)

- Dynamic Type clamped at scene root to `.xSmall ... .accessibility2`.
- TabView root nav replacing Dashboard-as-hub (see fix #1 above).
- `.scarfGoCompactListRow()` + `.scarfGoListDensity()` tokens applied to Memory / Cron / Skills / Dashboard / MoreTab / ServerList for ~48pt rows that still meet the 44pt tap-target invariant.
- Chat: fenced code blocks render in a horizontally-scrollable `CodeBlockView` (240pt collapsed, Expand to full) instead of soft-wrapping into unreadable columns; message bubbles gained `.contextMenu` (Copy + Share); iOS 17+ `.defaultScrollAnchor(.bottom)` + iOS 18's `.defaultScrollAnchor(.bottom, for: .sizeChanges)` replace the manual `scrollTo` dance.
- Custom `.presentationDetents` per sheet — `[.height(220), .large]` for permission sheet, `[.large]` for cron editor; never the misleading `.medium`.

### M9 — Multi-server + on-the-go (all shipped)

- **Multi-server** — storage layer (UserDefaults + Keychain) now keys by `ServerID`, with one-shot v1 → v2 migration so updating the app doesn't re-onboard anyone. New `ServerListView` root shows every configured server with nickname / user@host:port / tap-to-connect / swipe-to-forget. "+" button re-enters onboarding for a fresh server. ScarfGoTabRoot splits the old factory-reset "Disconnect" into soft Disconnect + destructive Forget rows in the More tab.
- **Session resume** — Dashboard Recent Sessions rows are now tappable; `ScarfGoCoordinator` routes the tap to the Chat tab with a `pendingResumeSessionID`; ChatController.startResuming calls `session/resume` (or falls back to `session/load` on older Hermes) with the full transcript preserved.
- **Project-scoped chat** — "+" in Chat opens a picker: Quick chat vs. In project…. Project list loads from `~/.hermes/scarf/projects.json` over SFTP. On project select, ScarfGo SFTP-writes the Scarf-managed block into `<project>/AGENTS.md` via the shared `ProjectContextBlock` service (same byte-for-byte markers as the Mac app — projects round-trip cleanly), spawns `hermes acp` with `cwd = project.path`, and records the session attribution in `session_project_map.json`. `SessionAttributionService` moved from Mac target into ScarfCore so both apps use the same store.
- **Scoped Settings editor** — curated list of 7 editable keys (model.default, model.provider, approvals.mode, agent.max_turns, display.show_cost / show_reasoning / streaming) as a Quick Edits section at the top of Settings. Save routes through `hermes config set <key> <value>` on the remote (Hermes owns the YAML round-trip); Scarf just picks the value. Inline error banner on sheet if the remote command fails.
- **APNs push skeleton** — `APNSTokenStore` + `NotificationRouter` ship ready for a future Hermes-side push sender. Lock-screen "Approve" / "Deny" action category is registered. Capability stays OFF in Xcode until Hermes gains a sender + we have an APNs auth key; flipping the capability on is a ~5-line follow-up.

## Reporting issues

- **Bugs:** <https://github.com/awizemann/scarf/issues> — tag with `component: scarfgo`.
- **Feature requests:** same, tag with `feature: scarfgo`.
- **Security / credential handling concerns:** use the repo's security policy.

## For contributors

See [Architecture Overview](Architecture-Overview) for how ScarfCore + ScarfIOS fit together, [ScarfCore Package](ScarfCore-Package) for the package boundaries, and [Transport Layer](Transport-Layer) for the Citadel transport details. M6 → M10 are all merged to `main` and shipped as part of Scarf v2.5.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (M10 TestFlight shipped; iPhone-only target settings; PATH-prefix correction)_