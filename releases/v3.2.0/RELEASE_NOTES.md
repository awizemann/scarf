# Scarf v3.2.0

This release moves Scarf to **Hermes v0.21.2** and ships the largest correctness pass in the app's history. After the v0.21.1 parity work landed, every surface Scarf reads or drives — config reads and writes, the CLI verbs it shells, cron and kanban, the capability floors, chat over ACP, and the process and SSH plumbing underneath — went through six rounds of adversarial audit, each round re-deriving the last round's fixes at the source. Two hundred and some defects were fixed, most of them pre-existing and invisible until the audit read the surrounding code: settings that showed the wrong value, buttons that reported success over a refusal, features gated to the wrong Hermes version, and background work that quietly blocked the app. Then the release gate ran for real: the UI test plans pass, on both Hermes v0.21.1 and v0.21.2.

## Hermes v0.21.1 and v0.21.2

Everything the v0.21.1 line added that a Mac client can use is here, each behind a capability flag so older hosts keep working exactly as before:

- **Cron**: create a job paused, choose failure delivery, and see dispatch diagnostics on the job; the Review column of the Kanban board now has both exits (approve to Done, send back to Up Next) on hosts that support them, and dragging a card to Running confirms before it runs a dispatcher pass over the board.
- **Kanban completion contracts**, with the real failure reason shown on the card.
- **MCP device-code OAuth**: sign in to an MCP server that shows you a code, and a login that finds the token where Hermes actually stores it.
- **Credential pools**: reorder a pool and clear one credential's cooldown.
- **Settings**: the fast-mode tier picker, split telemetry opt-ins, the Perplexity and Keenable web backends (Tavily is back too), and the new v0.21 config keys.
- **Health**: `debug share` that reports what it actually uploaded, `plugins compat`, and a Computer Use permissions card.
- **Fleet apply** copies a job's repeat limit and tells you when a model pin can't be copied to another host.

**Hermes v0.21.2** (the state.db reliability patch) was verified at the tag and against a live host: the schema, the ACP wire, and every command Scarf issues are unchanged. One thing did change: `hermes backup` now deletes older `hermes-backup-*.zip` files in its output folder by default. Scarf's Backup Now passes `--keep 0` on v0.21.2 hosts, so it never deletes a backup you kept.

## Settings that tell the truth

Scarf reads config.yaml with its own YAML reader so it can show a setting without shelling a command. The audit ran that reader against PyYAML across hundreds of thousands of generated documents and fixed every disagreement on the keys Scarf reads: folded long strings, quoted escapes, `yes`/`on`/`1` and their quoted forms, block scalars (a personality with a multi-line system prompt used to render empty), flat dotted keys, and the exact `busy_ack_enabled` rule Hermes applies. Several defaults were wrong in the misleading direction — approval mode shown as Manual on a host running `smart`, memory limits parsing to zero, toggles shown on against a false default — and are now read from Hermes's real defaults at the target version. The writers were fixed too: Scarf no longer emits YAML that PyYAML rejects, no longer deletes your comments, and no longer corrupts a config whose list key holds a block scalar (which made Hermes discard the whole file).

## Buttons that report what Hermes did

Hermes prints a refusal and exits 0 more often than you'd think: a managed install refusing a config write, `auth logout` with nothing to log out, `sessions optimize` with nothing to do, a plugin that installed but could not be enabled, a webhook that was never subscribed. Scarf used to read exit 0 as success. Every verb Scarf shells is now judged on what Hermes printed, with three honest states: it worked, it refused (and why), or it printed nothing recognisable (and Scarf says so instead of guessing). Restore from backup, which failed on every live Hermes home because the CLI waited on a confirmation prompt nobody could answer, now works.

## Gated to the version that actually shipped it

Every capability flag was walked against the Hermes source at its floor tag and the tag before. Twelve floors were wrong, in both directions: the Kanban board was offered to v0.12 hosts that have no `kanban` command (every click routed to the agent), while MCP identity headers, bot chat creation, and the model chip were hidden from hosts that support them. `/goal` and `/subgoal`, which the chat composer treated as commands, were never commands over ACP on any version and are now sent as ordinary prompts with a notice. The Web Dashboard row is hidden on hosts without the `dashboard` verb.

## The app stops blocking itself

Backup, restore, the Logs pane's `tail -F`, the four streaming spawns, every gateway and skills command, and the launch-time shell probe all ran blocking work on Swift's cooperative thread pool or the main actor. On a slow SSH host one of these could freeze the window whose whole purpose is showing you what the agent is doing. They now run on real threads or through the transports' async seam, every subprocess has a timeout, and a source-scan test fails the build if a new blocking call sneaks back in. The Logs pane also stopped dropping blank lines, and the Activity section stopped showing "check the SSH connection" on a local Mac that simply had no state.db yet.

## iOS

ScarfGo's cron editor writes `jobs.json` directly, so every validation `cron edit` performs now lives in the form: a re-timed job no longer fires at its old time, a spent one-shot can't be re-enabled, and malformed schedules are refused before they're written. iOS shares the corrected YAML reader, the three-state verdicts, and the async transport seam. The iOS build rides the next TestFlight release.

## Usage analytics

The anonymous install identifier now persists across launches so active installs and retention can be counted. It is a random value stored only on your Mac and sent as a hash; nothing else about what is collected changed, and the opt-out in Settings → Advanced still turns everything off. The privacy policy, README, and the Settings disclosure describe it.

## Under the hood

- A UI release gate: Smoke (every section renders), Full (nine journeys: install a skill, model presets, settings persistence, cron and kanban, projects, template install) and Live (a real chat over ACP) XCUITest plans, wired into `release.sh`.
- ScarfCore grew from 2,176 to **3,293 tests**; the Mac app target from 745 to **1,442**, including source-scan sweeps for spawn discipline, catalogue coverage, argv separators, and citation accuracy.
- A provider-table gate that reads Hermes at the target tag and fails closed.
- Every Hermes citation in the code was re-opened at its tag; the memory that guides this work carries the lessons.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight; the iOS fixes above ride its next build.
- Compatible with Hermes v0.6.0 through v0.21.2. Everything newer than your host's version stays hidden; nothing changes on a host you don't upgrade.
- If you use Backup Now on a Hermes v0.21.2 host, Scarf keeps every backup; the CLI's own default keeps three.
