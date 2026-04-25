## What's New in 2.5.0

The big one for 2.5: **ScarfGo, the iPhone companion**, ships in public TestFlight. Same Hermes server you've been running on your Mac — now reachable from your phone over SSH. Dashboard, chat, memory, cron, skills, settings (read), all of it. On the Mac side, the global Sessions list grows up alongside the iOS work — project filter, project badges on each row.

### ScarfGo iOS companion (public TestFlight)

ScarfGo is a fully native iOS app — not a web view, not a remote desktop. It speaks SSH (Citadel under the hood), reads your Hermes state directly from your Mac (or wherever Hermes is running), and lets you tap a session to resume it from where you left off. Per-project chat works end-to-end: pick a project on your phone, the agent gets the same Scarf-managed `AGENTS.md` context block the Mac writes, and the resulting session shows up correctly attributed in the Dashboard's Sessions tab.

What's in the first public TestFlight build:

- **Multi-server.** Configure as many Hermes hosts as you want, switch between them from a single sidebar-adaptable tab root. Soft disconnect keeps your credentials; "Forget" wipes a server end-to-end (Keychain + UserDefaults).
- **Dashboard.** Stats + the 25 most recent sessions; an Overview tab and a Sessions tab with a project filter Menu.
- **Chat.** Full ACP (Agent Client Protocol) over SSH — streamed responses, tool-call disclosure groups, code blocks with horizontal scroll, "Connecting…" → "Ready" lifecycle, error banner with copy-to-clipboard for non-retryable failures.
- **Project-scoped chat.** "+ In project…" sheet picks from your project registry over SFTP. Writes the Scarf-managed `AGENTS.md` block before spawning `hermes acp` so the agent boots with project context. Records the resulting session ID in the attribution sidecar so the Mac picks it up.
- **Session resume.** Tap any session on the Dashboard → opens Chat with `loadSession`. Older CLI-started sessions hydrate from `state.db`; newer ACP sessions show an empty-state explaining the agent has the context but the local transcript isn't cached.
- **Memory editor.** Read + edit `MEMORY.md` and `USER.md`, with a "Saved" pill that survives keyboard dismissal and a Revert button.
- **Cron list.** Read-only for now, but with **human-readable schedules** ("Every 6 hours", "Weekdays at 09:00") instead of raw `0 */6 * * *`. Mac gets the same formatter.
- **Skills + Settings.** Read-only. Skills shows category structure; Settings shows your `config.yaml` for inspection (no editor in 2.5).
- **iOS 18+.** Dynamic Type clamp at the scene root, sidebar-adaptable TabView, scoped sheet detents, scroll anchoring, content-aware empty states throughout.

**TestFlight invite:** see the [ScarfGo wiki page](https://github.com/awizemann/scarf/wiki/ScarfGo) for the public link + onboarding walkthrough.

### Mac global Sessions: project filter + badges

The per-project Sessions tab shipped in 2.3, but the global Sessions feature still rendered every session as a flat list with no project context. 2.5 closes the gap:

- **Filter Menu** above the list: All projects / Unattributed / one entry per registered project. An xmark button clears the filter; the right side shows "X of Y shown".
- **Project badge** on each row — small tinted folder chip with the project name. Same visual language ScarfGo uses on its Dashboard.
- Logic comes from the same `SessionAttributionService` + `ProjectDashboardService` ScarfGo consumes, both in ScarfCore. Single source of truth across platforms.

### Human-readable cron schedules everywhere

Pre-2.5, both Mac and iOS rendered cron jobs as `0 */6 * * *` raw. The new `CronScheduleFormatter` in ScarfCore translates the common shapes to plain English (every-N-minutes, every-N-hours, daily-at-H, weekdays-at-H, the `@hourly`/`@daily`/`@weekly`/`@monthly` macros) and falls back to the raw expression for anything custom. Both apps consume it.

### Under the hood

- **Shared services.** `SessionAttributionService`, `ProjectContextBlock`, and `CronScheduleFormatter` moved into ScarfCore; both apps consume them via their respective transports (`SSHTransport` on Mac, `CitadelServerTransport` on iOS).
- **`RichChatViewModel`** carries the ACP error triplet (`acpError`, `acpErrorHint`, `acpErrorDetails`) for both platforms — Mac's `ChatViewModel` now delegates instead of duplicating.
- **Test reliability.** Cross-suite races on `ServerContext.sshTransportFactory` resolved by consolidating every factory-touching test into a single `.serialized` suite. 163 tests across 12 suites, three consecutive green runs.
- **Surface silent failures.** Several `try?` swallows in iOS lifecycle code now surface to the user — Keychain unlock errors no longer dump people back into onboarding, partial Forget operations report what failed, project-context-block writes that fail surface a banner instead of silently degrading agent context.

### Notes for users running 2.3

No data migrations needed. Server configs, Keychain entries, project registries, session attribution sidecar — all forward-compatible. The only invariant change is iOS-only: `ScarfGo.servers.v1` UserDefaults key migrates to `com.scarf.ios.servers.v2` on first launch, and Keychain accounts move from `"primary"` to `"server-key:<UUID>"`. One-shot, idempotent — re-running 2.3 after 2.5 ran would just see the v2 data.

Push notifications stay disabled in this build. The skeleton (NotificationRouter, category registration, action handlers) is in place behind `apnsEnabled = false` for when Hermes ships a push sender + we get an APNs cert.
