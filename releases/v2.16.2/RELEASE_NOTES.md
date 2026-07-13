# Scarf v2.16.2

A point release that brings iOS's per-profile scoping to the Mac's remote windows — and it's a community milestone: the headline fix is Scarf's **first merged external contribution**, from [@JonLaliberte](https://github.com/JonLaliberte) ([#126](https://github.com/awizemann/scarf/issues/126), [PR #127](https://github.com/awizemann/scarf/pull/127)). A remote server window can now **view any Hermes profile** — Sessions, Memory, Cron, and Chat all scoped to it — without touching the profile the server's agent, cron, and terminal are actually running on.

## Remote windows: view any Hermes profile (#126)

If your remote host runs multiple Hermes profiles (say a day-to-day `admin` and a locked-down `gateway`), the Mac app previously had no good way to look at the non-active ones: the Sessions list was pinned to the root/default profile's `state.db` no matter what you switched to, and the only real "switch" was the host-mutating `hermes profile use` — which changes the profile for everything running on that server, not just your window.

v2.16.2 ports ScarfGo's per-connection profile scoping ("Design B", introduced for iOS in v2.13) to the Mac's remote windows:

- **"View this profile"** (Profiles tab, or click the sidebar chip) re-points the window at that profile's `~/.hermes/profiles/<name>/` data. Sessions, Memory, Cron, and Chat all reload against it — no relaunch, and the server's `active_profile` is untouched.
- The sidebar shows a **`viewing:` chip** on remote windows so you always know which profile a window is scoped to; the Profiles list badges the viewed profile (`viewing`) separately from the server's own (`active`).
- The host-mutating action is still there, relabeled **"Set as server's active profile"** so the two operations can't be confused. Local windows are unchanged.

The selection persists per server across launches. Credit where it's due: the scoping seam, persistence, and the viewing/active UI language are all @JonLaliberte's work.

## …including everything the window *does*, not just what it shows

Profile scoping has two layers, and our review of the PR caught that only the first had made it to the Mac. The **file layer** (re-pointing reads at `profiles/<name>/`) covered the lists — but every action that shells out to the remote `hermes` CLI (chat itself, Cron's "Run now", config edits, plugins, backups) still resolved the server's `active_profile`. The failure that made it concrete: chat from a window viewing `work` wrote the conversation into the *active* profile's `state.db` — a session the window's own Sessions list would never show.

The Mac's SSH transport now scopes the **process layer** too, prepending `HERMES_HOME=<profile home>` to every remote command exactly the way ScarfGo's transport has since v2.13. The assignment is empty for a root/default home, so if you never touch viewing profiles, every remote command is byte-identical to v2.16.1.

## Under the hood

- `ServerContext.scoped(toProfile:)` (ScarfCore) is root-normalized — re-selecting profiles never nests `profiles/a/profiles/b`, with a dedicated test suite covering tilde, custom, and Docker-style roots.
- The profile-selection store is now shared ScarfCore code (each app keeps its own `UserDefaults` key), and the Mac transport's three remote-command builders were deduplicated into one composed path with exact-string tests. ScarfCore suite: 813/813 green.
- The Scarf iOSTests target is enabled in CI-facing test plans, with a controller-level regression for #124.

## Upgrade notes

- **Sparkle** will offer the update automatically, or use **Scarf → Check for Updates**. macOS 14.6+ deployment target unchanged.
- **iOS / ScarfGo: no new build needed for this release.** The changes compile in shared ScarfCore but don't alter iOS behavior — ScarfGo's Citadel transport has injected `HERMES_HOME` since v2.13, and the relocated selection store is behavior- and key-identical. (Separately, the #124 chat-completion fix is merged and queued for the next TestFlight build; [#124](https://github.com/awizemann/scarf/issues/124) stays open as its tracker.)
