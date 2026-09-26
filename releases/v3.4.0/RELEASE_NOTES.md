# Scarf v3.4.0

This release brings Scarf up to Hermes v0.21.5 and fixes a long list of things Scarf said that weren't true. The most important: **Stop now actually stops the agent.** Scarf has always sent Hermes's cancel message in a shape Hermes's protocol library rejects, so clicking Stop, talking over a voice reply, or cancelling on iPhone ended the turn in Scarf while Hermes kept working, tools included. Alongside that, Scarf follows Hermes v0.21.4 and v0.21.5's move to one gateway serving every profile, reads the commands whose output changed in those releases correctly, shows how long a reply has been running, and fixes cron "Run now" killing any job longer than 30 seconds. Everything new is gated to the Hermes version that introduced it; nothing changes on a host you don't upgrade.

## Stop means stop

Hermes's agent-client protocol accepts a cancel only as a one-way notification. Scarf sent it as a request that expects an answer, which the protocol library answers with "method not found" and ignores, and Scarf discarded that error. This was true on every Hermes version Scarf supports. Scarf now sends the notification Hermes expects, waits up to two seconds for Hermes to confirm the turn ended before closing the connection, and never shows a failure banner for a cancel you asked for (Stop or a voice barge-in). A failed start now cleans up after itself instead of leaving a half-started agent process behind, and a request sent after the connection dropped fails straight away instead of hanging.

## Hermes v0.21.4 and v0.21.5

- **One gateway for every profile.** From v0.21.4 Hermes serves all your profiles from the default profile's gateway unless something prevents it, and an explicit `multiplex_profiles: false` is retired (v0.21.5 rewrites it to `true`). Settings → Profile Routes now says routing is on by default and lists the reasons Hermes can still refuse. The Gateway pane shows v0.21.5's "this gateway is standalone" warning with the profiles left without a bot, the reason, and the fix command as copyable text.
- **Parked profiles (v0.21.5).** Stopping a profile that the main gateway serves now parks it rather than stopping a separate process. Scarf shows a Parked badge and reports Start, Stop and Restart correctly instead of "could not confirm". Verified live against v0.21.5.
- **Commands whose output changed.** Kanban diagnostics stopped loading at all on v0.21.4 (a new summary row broke the decoder); a partial backup that Hermes kept now reads as a partial success rather than a failure; a skill blocked by the security scan reads as not installed; a deleted profile whose identity cleanup is still pending reads as deleted, with Hermes's retry command kept on screen; `peer dm` replies that were queued or are still running no longer invite a resend that would deliver the message twice; cron incidents understand the new "resolved" state.
- **Health → Optimize.** Hermes now refuses to optimize the sessions database while any process has it open, and on a local host Scarf's own read-only view always does. Scarf explains who holds it; when only Scarf does, a light confirmation runs it with `--force`, and when something else does (a gateway, another app) the confirmation spells out the risk.
- **Search.** Hermes v0.21.4 rebuilt its search index so every tool output is indexed only up to its first 8 KB. Scarf now detects that layout and searches the rest of long tool outputs directly, so a match deep inside a tool result isn't silently lost. A search that fails now says so instead of showing "No matches".
- **Cron jobs follow the main model.** Unpinned cron jobs now run on whatever `hermes model` is set to. The Mac cron editor gains **Pin to the current main model**; ScarfGo explains a blank model field.
- **Catalog and settings.** The keyless OpenCode Free provider is gone from v0.21.4 hosts (still offered on v0.20.5 through v0.21.3); `chatgpt` is accepted as an alias for the Codex provider; the new OpenAI-native web search backend is selectable; the compression threshold shows v0.21.4's 256K default when you haven't set one; WhatsApp gains the "decline" reply for unknown senders, with its message saved where Hermes reads it; MCP servers written as `enabled: 0` read as disabled on v0.21.5, like Hermes does.

## A clock for running replies

The three grey dots under a running reply never actually animated, so they looked frozen. They are replaced by **Working · 0:12**, a live elapsed time on the Mac and on ScarfGo, which picks up the right start time when you open a chat that's already mid-reply. It updates once a second without redrawing the conversation, and VoiceOver reads it as one element without re-announcing every second. (Thanks to the report in #145.)

## Cron "Run now"

Since Hermes v0.18.0, `hermes cron run` runs the job to completion before it returns. Scarf gave it 30 seconds, so any agent job longer than that was killed partway through its model call and shown as failed. Scarf now waits as long as Hermes itself allows a run (30 minutes), shows "Running…" immediately, ignores a second click while the first is running, reports a paused or deleted job as "didn't run" instead of "Agent started", and, if it does stop waiting, says so without calling it a failure.

## Chat and reconnects

- Switching to another chat while Scarf was reconnecting could put the old chat back on top of the new one. A reconnect now checks it's still wanted at every step.
- After a reconnect, "Load earlier" could repeat messages you'd already seen or skip a stretch of history. Fixed.
- Sending a message while a reply is still streaming no longer drops the partial reply and its tool card.
- Approval requests on v0.21.4+ no longer leave empty tool rows in the transcript.
- On ScarfGo, returning from the background could leave a chat stuck on "Reconnecting"; it now resumes, and a turn from a chat you've left can no longer show its error in the new one.

## Scarf never writes Hermes's database

Scarf reads `state.db` read-only. When the database's write-ahead log side files are missing, a read-only open fails, so Scarf falls back to a connection with writes switched off. SQLite still copies pending log changes into the database when the last connection closes, and in that fallback that connection could be Scarf's. Scarf now turns that off, on the Mac and in the `sqlite3` command it runs on remote hosts, and refuses the fallback on any host where it can't confirm the setting.

## Honest results elsewhere

- **Doctor** shows "did not complete" or "timed out" instead of a partial or empty report, stops counting error lines as passing checks, and has two minutes instead of one.
- **Security audit** only says "Advisories found" when it actually found some; a crash reads as a failure.
- **Skills → Check for updates** no longer says "No updates available" when the check failed, and keeps the list it had.
- **Settings → Profile Routes** no longer warns about a routing allowlist that Hermes stopped reading at v0.21.3.
- **ScarfGo** says "sqlite3 is not installed on this server" instead of a generic connection error (#141), and a session list that failed to load says so with Retry instead of "No sessions yet".
- The model picker opens on the right provider when your config uses an alias; MCP settings refresh when Scarf detects a Hermes upgrade; the MCP test result has a VoiceOver label; the peers message box is labelled "Message", not "Send".
- A `compression.threshold_tokens` value like `nan` or `1e30` in config.yaml could crash Scarf while reading the file. Scarf now reads numbers exactly the way Hermes's YAML parser does.

## Under the hood

- ScarfCore holds about 3,760 tests and the Mac app target about 1,590. Every fix in this release has a test that fails without it, most built from Hermes's exact output at the release tag.
- The provider tables check clean against Hermes v0.21.5 (`check-hermes-tables.py`, 5 of 5 lanes).
- Every new string is translated into all six supported languages.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight and the App Store; the iOS changes above ride its next build.
- Compatible with Hermes v0.6.0 through v0.21.5. Parked profiles, the standalone warning and MCP numeric on/off need v0.21.5; the other Hermes-specific changes above need v0.21.4. Everything newer than your host's version stays hidden.
- If you run Hermes from a git checkout or fork whose `hermes --version` reads like `v0.21.4+1234.gabcdef`, Scarf treats it as v0.21.4 even if it contains newer code. That's the safe direction; the official releases report their version exactly.
