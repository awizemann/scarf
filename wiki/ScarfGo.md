---
title: ScarfGo
type: note
permalink: scarf-wiki/scarf-go
updated: 2026-07-14
created: 2026-05-29
---

# ScarfGo — iOS companion for Hermes

ScarfGo is the iPhone companion to [Scarf](Home), the macOS GUI for the [Hermes AI agent](https://github.com/awizemann/hermes-agent). It connects from your phone to a Hermes server you operate (your Mac, a home Linux box, a cloud VM — anywhere reachable over SSH), and lets you run sessions, review memory, manage cron jobs, and resume conversations on the go.

> **Status:** Public beta in TestFlight. See **[Installation](#installation)** below.

## What ScarfGo is, in one paragraph

ScarfGo is a fully native iOS app — not a web view, not a remote desktop. It speaks SSH (Citadel under the hood, no `ssh` binary needed on iOS), reads your Hermes state directly via SFTP + SQLite snapshots, and streams real-time agent output over the [Agent Client Protocol](ACP-Subprocess) on a long-lived SSH exec channel. Every byte stays between your device and the Hermes host you configured. There are no developer-controlled servers in between.

## System requirements

- iPhone running **iOS 18.0** or later.
- An **SSH-reachable Hermes host** running Hermes v0.10.0 or later. See [Hermes Version Compatibility](Hermes-Version-Compatibility).
- Your iPhone needs to reach that host on the network — same Wi-Fi, VPN, Tailscale, port-forwarded public address, or anything else SSH can dial.
- A spare second or two for onboarding to generate an SSH keypair.

## Installation

ScarfGo is in **public TestFlight**. Apple-provided test environment, free to join, no payment, no Apple ID needed for beta installs.

1. **Get the TestFlight app** — install from the App Store if you don't have it.
2. **Open the public TestFlight invite link** — **<https://testflight.apple.com/join/qCrRpcTz>**. The link is live now but only accepts new beta testers once Apple's Beta Review approves the first build. If you hit a "this beta isn't accepting any new testers" splash, bookmark this page and try again in 24–48h — that's the Beta Review queue, not a permanent state.
3. **Tap "Accept" and "Install"** — TestFlight installs ScarfGo alongside your other apps.
4. **Open ScarfGo** — onboarding walks you through host details, generates a new SSH keypair, and gives you the public-key snippet to paste into your Hermes host's `~/.ssh/authorized_keys`. Step-by-step walkthrough: [ScarfGo Onboarding](ScarfGo-Onboarding).

Onboarding details:

- ScarfGo generates a fresh Ed25519 keypair on first run. The private half lives in the iOS Keychain. **Default:** device-local (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not iCloud-synced). **v2.5.1+:** an opt-in toggle in System tab → Security flips it to sync via iCloud Keychain (`kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable=true`) so iPhone + iPad + Mac see the same key without onboarding each device. End-to-end encrypted by iCloud Keychain; with Advanced Data Protection enabled, the encryption keys never leave your devices.
- The public-key snippet is shown for you to copy and append to `~/.ssh/authorized_keys` on your Hermes host. Plain `ssh-copy-id` doesn't work from iPhone, so the manual paste is the safest path.
- A one-tap "Test connection" verifies SSH + the `hermes` binary's path before saving.

## Features

| Feature | What you can do |
|---|---|
| **Multi-server** | Configure as many Hermes hosts as you like. Soft Disconnect keeps credentials; Forget wipes a server end-to-end. |
| **Dashboard** | Total sessions / messages / tool calls + a 25-session list with project badges. Filter by project. |
| **Chat** | Streamed agent responses, tool-call disclosure groups, code blocks with horizontal scroll. Project-scoped chat picks a project from your registry, writes the same Scarf-managed `AGENTS.md` block as the Mac app, and spawns `hermes acp` with the project as the working directory. |
| **Session resume** | Tap a row on the Dashboard → opens that session's transcript in Chat. CLI-started sessions hydrate from `state.db`; ACP sessions show an empty-state because Hermes doesn't persist ACP transcripts to the DB (same on Mac). |
| **Memory** | Read + edit `MEMORY.md` and `USER.md`. The "Saved" pill survives keyboard dismissal; Revert undoes unsaved edits. |
| **Cron** | List view of `~/.hermes/cron/jobs.json` with **human-readable schedules** ("Every 6 hours", "Weekdays at 09:00") and a relative next-run ("in 4 hours"). Read-only in v1 — editing comes later. |
| **Skills** | Browse the skills tree from `~/.hermes/skills/`. Read-only. |
| **Settings** | Read view of full `config.yaml` plus a **Quick Edits** section that flips 7 commonly-changed keys (`model.default`, `model.provider`, `agent.approval_mode`, `agent.max_turns`, `display.show_cost`, `display.show_reasoning`, `display.streaming`) via `hermes config set` on the remote. Other keys remain read-only — edit from the Mac app or a remote shell. |
| **Slash commands** _(v2.5)_ | Read-only browser of project-scoped slash commands shipped via `<project>/.scarf/slash-commands/`. Tap a row to see the expanded prompt with a sample-argument field. Authoring is Mac-only in v1. See [Slash Commands](Slash-Commands). |
| **Auto-reconnect** _(v2.5.2)_ | Lock the phone, switch from WiFi to cellular, or just lose signal mid-prompt — when the SSH socket dies, ScarfGo reattaches via `session/load` on a 5-attempt 1→2→4→8→16 s exponential backoff (load-only — `session/resume` was removed because resuming an unknown id silently created orphan server-side sessions). Hermes keeps writing to `state.db` on the remote during the outage; on success ScarfGo reconciles the transcript from `state.db` and a "Resynced N new messages" toast surfaces what the agent did while you were offline. A yellow **Reconnecting (n/5)…** banner shows the recovery in progress; a red **No network** banner shows when reachability is unsatisfied. See [Chat](Chat) for the full resilience model. |
| **Draft persistence** _(v2.5.2)_ | A half-typed message survives force-quit — drafts are persisted to `UserDefaults` keyed by `(serverID, sessionID)` and restored when the session resumes. A 7-day janitor at app launch prunes stale slots. |
| **Load earlier messages** _(v2.5.2)_ | Long sessions (200+ messages) page chronologically — the initial fetch loads the most recent 200, with a "Load earlier messages" button at the top of the transcript for the rest. Pagination is keyed by message id (monotonic) so streaming-chunk timestamps that collide on the same millisecond never split a page. |

## Project-scoped chat

Picking a project at the start of a chat tells the agent exactly which directory it's operating in. ScarfGo does the same handshake the Mac app does:

1. SFTP-reads `~/.hermes/scarf/projects.json` for the project registry.
2. On selection, SFTP-writes a managed block into `<project>/AGENTS.md` (between `<!-- scarf-project:begin -->` and `:end -->` markers — preserves anything outside).
3. Spawns `hermes acp` with `cwd = <project.path>`.
4. After the session ID returns, records the attribution in `~/.hermes/scarf/session_project_map.json`.

The block contains the project name, directory, dashboard path, configuration field names (never values — secrets stored in the Keychain are surfaced as field names only), and any cron jobs registered to the project. Hermes's startup context scan picks it up automatically. Ask a fresh chat _"what project am I in?"_ and the agent answers with the right name + path.

If the SFTP write fails (permissions, disk full, network drop), ScarfGo surfaces a banner — "Project context not written — agent will proceed without it" — and starts the session anyway. The session works; it just doesn't have the augmented context.

## Limitations in v1

- **No local mode.** ScarfGo only operates against an SSH-reachable Hermes host. There's no local Hermes runtime on iOS.
- **No push notifications yet.** The skeleton (UNNotificationCenter delegate, "Approve / Deny" action category) ships in the binary but is gated behind an internal feature flag because: (a) the Push Notifications capability is not yet enabled in the Xcode target, (b) Hermes doesn't yet have a push sender. When both land, push lights up on the iOS side without an app update — well, with one update to flip the flag. Watch this page.
- **Limited config editor.** Settings on iOS surfaces a 7-key **Quick Edits** sheet that shells out to `hermes config set`; the rest of `config.yaml` stays read-only. Editing arbitrary keys still belongs on the Mac app or a remote shell.
- **No template install UI.** `.scarftemplate` install + uninstall is Mac-only in v1.
- **No terminal mode.** Rich-chat (ACP) only.
- **English only.** The Mac app ships in 7 languages; ScarfGo is English-only for v1.
- **Push from Hermes server-side is upstream work.** The iOS side is ready; Hermes needs the sender.

See [Platform Differences](Platform-Differences) for a full Mac-vs-iOS feature matrix.

## Troubleshooting

**Onboarding can't connect.** First check that `ssh user@host` works from your Mac with the same hostname/port. If that fails, ScarfGo can't connect either — fix SSH first. If the Mac connection works:

- Make sure you appended the ScarfGo-shown public-key to `~/.ssh/authorized_keys` on the host.
- Make sure `hermes` is in the SSH user's PATH on the host. ScarfGo prepends common pipx / Homebrew install paths to the exec command, but if `hermes` lives somewhere unusual, run `which hermes` over SSH and ensure the path is one of: `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.hermes/bin`.

**Dashboard shows zero sessions but I know there are some.** ScarfGo downloads a snapshot of `~/.hermes/state.db` over SFTP. If your Hermes install hasn't yet written the DB (no sessions ever started), the snapshot is empty. Start a session via the Mac app or CLI first.

**Memory says "Save failed" silently.** Pull-to-refresh — usually a transient SFTP hiccup. If it persists, check the SSH user has write permission on `~/.hermes/memories/`.

**The agent's running forever after a non-retryable error.** v2.5 added a banner for HTTP 4xx/5xx provider errors; older builds (or upstream Hermes hangs we haven't worked around yet) might still show "Thinking…" indefinitely. Tap the Stop button in Chat to abort — that always works.

**Biometric prompt loops or fails.** Cancelling Face ID / passcode prompts no longer drops you into fresh onboarding (v2.5 fix); the app surfaces a banner on the server list with a Dismiss button. Re-tap the server to retry.

## FAQ

**Q: Can ScarfGo run Hermes locally on the iPhone?**
A: No. Hermes is a Python agent that needs Python plus a model provider's CLI plus a writable filesystem. iOS doesn't make any of that practical. ScarfGo is a thin client.

**Q: Will my SSH key sync to my other devices?**
A: Optional as of v2.5.1. Default is **off** — the Keychain entry is `ThisDeviceOnly` and adding a second device means a second key + a second `authorized_keys` line. Toggle **System → Security → Sync SSH key with iCloud Keychain** to flip the entry to a synced item. iCloud Keychain encrypts the bundle end-to-end; with Advanced Data Protection on, the keys are encrypted client-side with material that never leaves your devices. Off is still the right choice if you want a hard guarantee that the key is bound to one device — issue [#52](https://github.com/awizemann/scarf/issues/52).

**Q: Can I use ScarfGo with a Hermes host that's not on my LAN?**
A: Yes — anywhere reachable over SSH. Tailscale, port forwarding, a VPS, anything. The Hermes host doesn't know it's being driven by an iPhone vs a Mac.

**Q: Why is push disabled?**
A: Two reasons that need to land together: (1) the Push Notifications capability requires Apple Developer Program enrollment + an APNs auth key, (2) Hermes needs a server-side push sender to actually emit pushes. The iOS skeleton ships ready; flipping it on is one app update + one Hermes update.

**Q: Is my data sent to anyone?**
A: No. See the [privacy policy](https://awizemann.github.io/scarf/privacy/). The apps make exactly three kinds of network connections: (1) SSH to your Hermes hosts, (2) Sparkle update checks (Mac only), (3) HTTPS to GitHub Pages for the public template catalog. Zero analytics.

**Q: Where can I see what's planned next?**
A: [ScarfGo Roadmap](ScarfGo-Roadmap) tracks shipped milestones (M6 / M7 / M8 / M9) and remaining work. The [main Roadmap](Roadmap) covers cross-platform plans.

## Reporting issues

- **Bugs:** [github.com/awizemann/scarf/issues](https://github.com/awizemann/scarf/issues) — tag `component: scarfgo`.
- **Feature requests:** same, tag `feature: scarfgo`.
- **TestFlight feedback:** the Send Beta Feedback button in TestFlight goes straight to the developer.
- **Security / credential concerns:** use the repo's security policy.

---

_Last updated: 2026-07-14 — Scarf main (Auto-reconnect row updated: ladder is load-only, `session/resume` removed; reattach reconciles from `state.db`)._