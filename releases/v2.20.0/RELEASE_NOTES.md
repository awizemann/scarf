# Scarf v2.20.0

Two big things land in this release: full parity with the **Hermes v0.20.4** line (v2026.8.18) — including fixes for three breakages the upgrade would have caused — and **anonymous usage analytics** on macOS, disclosed up front with a one-click opt-out. Along the way the audit that drove this release found and fixed several bugs that predate it, including a Personalities feature that had quietly been broken twice over.

## Hermes v0.20.4 parity

Hermes shipped four patch releases (v0.20.1–v0.20.4, ~3,000 commits) since Scarf's previous v0.20.0 target. Scarf now targets **v0.20.4** while keeping every host back to v0.6.0 working — everything new is capability-gated at the patch level or schema-detected, so older hosts render exactly as before.

**Fixed ahead of your upgrade** (these would have broken the day your host moved to v0.20.4):

- **Personalities survive the move.** Hermes moved its 14 built-in personalities out of `config.yaml` into code; Scarf's pickers would have gone empty. They're now built in on both sides, unioned with your own entries — and two pre-existing Scarf bugs that made the Personalities list unreliable (a wrong config-key prefix, and reading `prompt` where Hermes writes `system_prompt`) are fixed, with previews now composed exactly the way Hermes renders them (including `tone:`/`style:` entries).
- **Cron enable/disable does what Hermes does.** Hermes v0.20.4 refuses to fire a job carrying pause markers; ScarfGo's toggle only flipped `enabled`, which would have left resumed jobs permanently dark. iOS now drives `hermes cron pause|resume` directly — same semantics as the Mac — and job state display follows Hermes's rule that an enabled job is never shown as paused.
- **"Update All" skills tells the truth.** `hermes skills update` now skips skills you've edited locally (and still exits 0); Scarf reports exactly which skills kept your local edits, with a per-skill, explicitly-confirmed "Update anyway" that is never applied wholesale.

**New in Scarf with a v0.20.4 host:**

- **Session list upgrades** — unread indicators using Hermes's own read-watermark semantics, hidden sessions now actually hidden, and post-reset conversations listed the way `hermes sessions list` shows them.
- **Curator audit trail** — browse the skill-mutation ledger, roll back a single mutation, and permanently purge old archived skills behind a dry-run preview and an explicit destructive confirmation (purge is not prune, and the UI keeps them apart).
- **Project skills** — repo-local skills (`./.hermes/skills`) appear in the project cockpit with trust/untrust controls.
- **MCP catalog** — a picker for Hermes's 20-server optional-MCP catalog prefills the add-server form; per-server `identity_header`, `strict_redirect_headers`, and stdio `cwd` are now first-class, with editor validation matching Hermes's own.
- **New settings** — wake-word capture mode, local-STT idle unload, cloud-STT silence trimming, the background-review kill switch, auxiliary concurrency limits, cron drain / gateway lease timeouts, and profile-routing warnings when a profile isn't in the new multiplex allowlist.
- **Providers** — the new Actual Computer provider, and the OpenAI Codex entry renamed to "ChatGPT or Codex Subscription" to match Hermes.

## Usage analytics (macOS, opt-out)

Scarf for macOS now records anonymous product-usage events — event names plus fixed-vocabulary properties, never chat content, prompts, file paths, hostnames, or keys — identified only by a random per-launch token, with no persistent user or device ID. **Settings → Advanced → Usage Analytics** turns it off with one click. ScarfGo on iOS sends nothing. Full details in the [Privacy Policy](https://awizemann.github.io/scarf/privacy/), rewritten for this release; the README carries the same disclosure.

An adversarial audit of the analytics code itself shipped in this release too: the wake-from-sleep reconnect metric was recording the inverse of reality (healthy connections counted as successful reconnects) and is now measured only when a dead connection is actually recovered and verified; retry-after-error is distinguished from a genuine session resume; and installed-skill counts reflect what was actually written, not what a template declared.

## Under the hood

- New patch-level capability group (`isV0204OrLater`, 8 flags) with degradation tests proving v0.20.0–v0.20.3 hosts render byte-identically; new schema probes for the `sessions.hidden` / `last_read_at` columns with a JSON1 availability check so older SQLite builds degrade to the previous listing instead of erroring.
- A YAML flow-list parser shared between the profile-allowlist and project-trust readers; malformed allowlist values now fail closed the same way Hermes does, and the top-level config spelling takes precedence exactly as upstream reads it.
- A byte-for-byte regression suite pins that editing one MCP server field preserves unknown nested config blocks — the guard against config data loss.
- Fixed a race that made a capabilities test flaky under full-suite load: a forced refresh now awaits the init-time probe instead of returning mid-flight.
- Test suite grows from 1,162 to 1,335 ScarfCore tests across 81 suites, plus new app-target analytics and MCP regression suites.
- Marker 0.9.0 (padded task checkboxes in chat markdown).

## Upgrade notes

Scarf updates automatically via Sparkle; macOS 14.6+ as usual. The Hermes target moves to **v0.20.4 (v2026.8.18)**; every earlier host back to v0.6.0 keeps working, and nothing new renders until your host is on v0.20.4. Analytics applies to macOS only and can be disabled before any event is sent on first launch's Settings visit — or leave it on and help guide development. ScarfGo (iOS) work in this range — App Store review fixes, OpenSSH key import, branded launch — ships separately via TestFlight on its own schedule.
