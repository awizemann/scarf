# ScarfGo — App Store Connect submission copy

Single source of truth for every field you paste into App Store Connect → My Apps → ScarfGo. TestFlight-specific fields (Beta App Description, "What to test") live in [TESTFLIGHT_CHECKLIST.md](TESTFLIGHT_CHECKLIST.md). This file covers the full App Store listing for when ScarfGo graduates from TestFlight to the public store.

All character counts are pre-counted against Apple's published limits. Counts include trailing punctuation but exclude the leading `> ` Markdown blockquote markers.

## App information (set once, persists across builds)

### App name (max 30 chars)

```
ScarfGo
```
_7 / 30 chars._

### Subtitle (max 30 chars)

```
On-the-go Hermes companion
```
_26 / 30 chars._

### Bundle ID

```
com.scarfgo.app
```

### Primary category

Developer Tools

### Secondary category (optional)

Productivity

### Age rating

4+ (no restricted content)

### Support URL

```
https://github.com/awizemann/scarf/wiki/Support
```

### Marketing URL (optional)

```
https://github.com/awizemann/scarf
```

### Privacy Policy URL

```
https://awizemann.github.io/scarf/privacy/
```

### Copyright

```
© 2026 Alan Wizemann
```

### Trade representative information

Not required for sole-developer accounts.

---

## Per-version metadata (resubmit on each App Store release)

### Promotional text (max 170 chars, editable without resubmission)

```
Manage your Hermes AI agent from your phone. Connect to any SSH-reachable Hermes host, run sessions, edit memory, browse cron jobs, resume conversations.
```
_153 / 170 chars._

### Description (max 4000 chars)

```
ScarfGo is the iPhone companion to Scarf, the open-source macOS GUI for the Hermes AI agent. It connects from your phone to a Hermes server you operate — your Mac, a home Linux box, a cloud VM, anything reachable over SSH — and lets you run sessions, browse memory, manage cron jobs, and resume conversations on the go.

A fully native iOS app, not a web view or a remote desktop. ScarfGo speaks SSH directly using a pure-Swift implementation, reads Hermes state via SFTP and SQLite snapshots, and streams real-time agent output over the Agent Client Protocol on a long-lived SSH exec channel. Every byte stays between your device and the Hermes host you configured.

What you can do:

• Multi-server. Configure as many Hermes hosts as you like and switch between them with a tap. Soft Disconnect keeps your credentials cached; Forget wipes a server end-to-end.

• Dashboard. Stats and the 25 most recent sessions, with project badges so you can tell at a glance which work is which.

• Project-scoped chat. Pick a project from your registry and ScarfGo writes the same Scarf-managed AGENTS.md context block the Mac app does, so the agent boots with the right project context. The resulting session is attributed correctly across both clients.

• Session resume. Tap any row on the Dashboard to open that session's transcript in Chat. CLI-started sessions hydrate from the Hermes state database; ACP sessions show an empty-state because Hermes does not persist ACP transcripts to the database.

• Memory editor. Read and edit MEMORY.md and USER.md with a Saved indicator that survives keyboard dismissal and a one-tap Revert.

• Cron list. Human-readable schedules ("Every 6 hours", "Weekdays at 09:00") instead of raw cron expressions, plus a relative next-run estimate. Read-only in this release; editing comes in a future update.

• Skills browser. Read-only category tree with the SKILL.md frontmatter chips (allowed tools, related skills, dependencies) the Mac app shows.

• Settings viewer. Read-only inspection of your config.yaml. Edit values from the Mac app or a remote shell.

Privacy. ScarfGo does not collect, transmit, or store your data on any server controlled by the developer. There are no analytics, no telemetry, no ad identifiers. SSH keys are generated on-device and stored in the iOS Keychain with the ThisDeviceOnly attribute, so they are unreachable while the device is locked and never sync to iCloud. The complete privacy policy lives at awizemann.github.io/scarf/privacy.

Open-source under the MIT license. Source, issue tracker, and contributor docs at github.com/awizemann/scarf. Bug reports tagged component:scarfgo go straight to the developer.

Requirements. iOS 18.0 or later. An SSH-reachable Hermes server (Hermes v0.10.0 or later recommended; full v0.11.0 features supported). Your phone needs to reach that server on the network — same Wi-Fi, VPN, Tailscale, or any port-forwarded address SSH can dial.
```
_2873 / 4000 chars._

### Keywords (max 100 chars, comma-separated, no spaces between terms)

```
hermes,ai agent,ssh,terminal,llm,assistant,developer tools,coding,remote,monitor,chat
```
_85 / 100 chars._

Brand-safe — no competitor product names. Apple flags trademarks like "Claude" or "OpenAI" as unauthorized brand use during review even when they appear as descriptive context.

### What's New text (max 4000 chars)

For v2.5.0 — first public App Store release. Trimmed from `RELEASE_NOTES.md`'s ScarfGo section to fit the iOS audience.

```
First public release of ScarfGo, the iPhone companion to the Scarf macOS app.

What's in this release:

• Multi-server. Configure multiple Hermes hosts and switch between them with a tap.

• Dashboard. Sessions, messages, and tool-call counts, plus the 25 most recent sessions with project badges and a project filter.

• Chat. Streamed agent responses over SSH with tool-call disclosure groups, code blocks, and project-scoped session start.

• Session resume. Tap any session on the Dashboard to open it in Chat.

• Memory editor. Read and edit MEMORY.md and USER.md with on-device save indication and one-tap Revert.

• Cron list. Human-readable schedules ("Every 6 hours", "Weekdays at 09:00") with relative next-run.

• Skills browser. Read-only category tree with SKILL.md frontmatter chips.

• Settings viewer. Read-only inspection of config.yaml. Edit values from the Mac app.

Known limitations in v1: no push notifications (the skeleton is in the binary, gated behind an internal flag pending Apple Developer Program enrollment and an APNs key); no in-app config editor; no template install UI; English only. iPad layout works via the system sidebar adaptive style but has not been polished — feedback welcome via TestFlight.

Privacy. No analytics, no telemetry, no developer-controlled servers. Read the full policy at awizemann.github.io/scarf/privacy.
```
_1150 / 4000 chars._

### Build (autopopulated)

Apple fills this in once the binary uploads + processes. The same build that went through TestFlight Beta Review is the one you ship to the public store.

### Version

Marketing version: `2.5.0` — the same number `release.sh` will write to `MARKETING_VERSION` for the macOS Scarf release. Keeping the iOS + Mac versions in lockstep is the convention this project uses.

---

## Build artifact

### App icon (1024×1024)

```
scarf/Scarf iOS/Assets.xcassets/AppIcon.appiconset/AW Mac OS Applications-macOS-Default-1024x1024@1x.png
```

The full appiconset is in repo and the Xcode target references it via `AppIcon`. App Store Connect pulls the 1024 from the binary on upload — no separate upload step.

### Screenshots

**Required for the public App Store, NOT required for TestFlight.** Scope deliberately excluded from this prep pass — capture from the simulator before flipping the App Store listing live. Apple requires:

- iPhone 6.7" (e.g. iPhone 16 Pro Max) — at least 5, up to 10
- iPhone 6.5" (e.g. iPhone 14 Plus) — at least 5, up to 10  
- iPhone 5.5" (e.g. iPhone 8 Plus) — at least 5, up to 10
- iPad — only if you flip the iPad flag in the target. Skip for v2.5.

Suggested screen captures (rough order):
1. Dashboard with stats + recent sessions list
2. Chat in mid-stream with a tool-call disclosure expanded
3. Project picker sheet
4. Sessions tab with project filter active
5. Memory editor with Saved indicator
6. Skills detail with frontmatter chips visible
7. Server list (showing multi-server)
8. Onboarding step 5 (public-key display)

### App preview video (optional)

Skip for v1. Apple will accept the listing without it.

---

## Beta App Review (TestFlight) — already submitted

Cross-reference [TESTFLIGHT_CHECKLIST.md](TESTFLIGHT_CHECKLIST.md). Once Apple's Beta Review approves the first build, the public TestFlight URL `https://testflight.apple.com/join/qCrRpcTz` accepts new joiners. Until then the link 404s with a "not accepting testers" splash.

## Public App Store submission flow (after TestFlight stabilizes)

1. App Store Connect → My Apps → ScarfGo → App Store tab → iOS App.
2. Paste every field above into the matching form.
3. Set the build to the same one that's been on TestFlight (Apple lets you reuse a TestFlight build verbatim — no re-upload).
4. Submit for review. Apple's standard App Review queue (separate from Beta Review) is typically 24–72h. Watch your inbox for "We have a question" emails and reply via App Store Connect's review-team chat.
5. On approval, choose "Manually release this version" so you can announce on a schedule.

## Update cadence

The same `releases/v<VERSION>/` directory pattern this file lives in is the canonical staging area for every future iOS release. When v2.6 (or whatever ships next) bumps the iOS app, copy this file forward and update:

- **Promotional text** — refreshed marketing wedge.
- **What's New text** — what changed since the last App Store release.
- Everything else above stays unless you're changing categories, support URL, or privacy stance.

The Mac `release.sh` does not yet drive the iOS release — that's a separate Xcode Archive + App Store Connect upload. See `TESTFLIGHT_CHECKLIST.md` Phase 4 for the archive flow.
