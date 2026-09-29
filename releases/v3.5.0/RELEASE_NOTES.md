# Scarf v3.5.0

This release is the result of three full audits of Scarf against Hermes v0.21.5, each followed by a round of fixes. More than 140 problems were found and fixed, most of which had been there for a while: Scarf reporting success when Hermes had refused, writing settings Hermes never reads, or behaving differently on a remote server than on your Mac. The final audit covered every one of Scarf's 664 source files and found nothing serious left. Along the way Scarf gained a **Stop button** in chat and Bot Chat, and the model picker now lists only providers your Hermes can actually use. Behaviour that depends on a Hermes release is gated to that release; older hosts get the fixes that apply to them.

## Things that could lose your work

- **Editing SOUL.md could wipe it.** The first time you pressed Edit in Personalities, the editor opened blank before the file had loaded, and Save replaced your SOUL.md with that. Edit now waits for the file, and saving an empty editor over existing text asks first.
- **Project chats could hide your CLAUDE.md.** Hermes loads only one project instruction file, and AGENTS.md wins. When a project had a CLAUDE.md or .cursorrules but no AGENTS.md, Scarf's first project chat created an AGENTS.md, and from then on every Hermes session in that folder ignored the project's own instructions. Scarf now adds its notes to the file your project already uses (on Hermes 0.16+ it writes no notes at all — see below), and repairs projects it had affected (only where the AGENTS.md contains nothing but Scarf's notes).
- **Long chats lost their older turns.** Hermes 0.21.5 compacts long chats in place by default. Reopening one in Scarf showed only the recent turns and "Load earlier" couldn't reach the rest. Scarf now shows the full history, the way Hermes's own resume does.
- **MCP tool blocklists turned into allowlists** on the second save of a server, and **OAuth MCP servers couldn't be added** at all. Both fixed.
- **Server Backup and Restore** no longer write to Hermes's database, take consistent read-only snapshots, match what `hermes backup` includes, and refuse to restore while Hermes has a database open.
- **iPhone memory edits** no longer overwrite changes the agent made while the editor was open.

## Stop, in chat and Bot Chat

A Stop button now sits next to Send (⌘. on the Mac), in rich chat and Bot Chat, on Mac and iPhone. Chats stay open and say "You stopped this turn". On Hermes 0.19.1 and later, your next text message goes to Hermes as a follow-up to the stopped request; start a new chat to drop it. Bot Chat stops the running `hermes chat` process the way Ctrl-C would, so Hermes saves the turn first, including over SSH.

## Chat and sessions, from your reports

- **Sessions started outside Scarf no longer pretend to resume** (#146). Hermes can only reopen sessions that were started in an app like Scarf. Opening one from hermes-webui, the CLI or a messaging platform used to start a new session silently while showing the old conversation, so the model had none of it in context. Scarf now keeps the old conversation on screen and says plainly that your next message starts a new session without it. If a resume fails for any other reason, Scarf shows the error with Retry instead of starting over. On Mac and iPhone.
- **`/title <name>` renames the chat** (#147), on Mac and iPhone. `/retry` and `/undo` are Hermes CLI commands that Hermes doesn't offer to apps yet; Scarf now says so instead of sending them to the model as text. We've asked Hermes to add them (NousResearch/hermes-agent#127870).
- **Each reply shows how long the whole prompt took** (#148), including every tool step, and older sessions show it too when you reopen them. It used to stop counting at the first bit of text and disappear on reload.
- **Branched sessions are marked** (#145). Sessions made with Hermes's `/branch` carry a **Branch** label in the Sessions list, the chat sidebar and ScarfGo; on the Mac, hovering it names the session it came from.

## Models and providers

- The model picker lists only providers your Hermes can route. It used to offer every provider in the models.dev catalog (about 220), and picking one of the ~185 Hermes can't use saved fine and then failed at the first message. This is measured per Hermes version from 0.6 on. If your config already names such a provider, chat shows a warning with a **Choose model…** button. Named custom providers are honoured everywhere, including bot and preset pickers.
- "Reasoning: none" now actually turns reasoning off; Nous users no longer see a false "chats will fail" banner; Anthropic sign-in opens one browser tab, not two; DeepSeek's retired model names follow what your Hermes sends.

## Remote servers and profiles

- Sessions lists on Ubuntu 22.04, Debian 11 and RHEL servers were missing continued and branched conversations, because Scarf guessed JSON support from the sqlite3 version. It now tests it.
- Windows showing the default profile no longer run commands against whichever profile the server last made active; the default bot can chat.
- Servers added without Test Connection can run Hermes commands again.
- Saving files into folders with spaces or accented letters works (SFTP-mode scp no longer receives quoted paths).
- Uninstalling a template on a remote server removes its folder and skills instead of reporting success and leaving them behind.
- Project chats on a remote server start in the right folder (`~` paths are expanded), and the git branch chip shows on Mac, remote and iPhone.

## Messaging platforms

- **Settings that `.env` overrides.** For Discord, Telegram, Matrix, Mattermost, Ntfy and the Slack/Mattermost/Matrix allowlists, Hermes reads the `.env` value first, so the form's toggle did nothing when `.env` held the variable (Hermes's own docs put many there). The forms now show the value Hermes uses, say when `.env` is deciding it, and Save moves it into config.yaml, removing the `.env` line only after the config write succeeds. An allowlist is never silently emptied.
- **Gateway restart while the agent is replying** now shows "waiting for the current turn", lists what's still running, and offers Stop Waiting, instead of "restart failed" after 60 seconds.
- **Spotify** sign-in works for first-time users on this Mac (Client ID field); on a remote server Scarf shows the exact command to run.
- WhatsApp Cloud saves no longer disable a working adapter; a blank WhatsApp reply prefix keeps Hermes's default header; Slack's inert Reply Mode picker is gone; iMessage read receipts show the right default; platform status dots show Connected/Error again.

## Project context, without touching your files (Hermes 0.16+)

On a project running Hermes 0.16 or later, Scarf no longer writes its notes into your AGENTS.md, CLAUDE.md or similar file at all. Instead it hands the agent a short project summary — name, path, Kanban tenant, cron attribution — directly on the chat process, the way Hermes 0.16 added support for. Anything you've set yourself for that host, in your shell or in Hermes's own config, is kept and Scarf's notes are added after it, never replacing it. Any notes block Scarf had previously written into a project's files is removed the next time you open a chat there. Older or not-yet-detected hosts keep working exactly as before, with the notes written into the project's file. Idea and research credit: **@counterposition** (issue #142, PR #144).

## Everything else, briefly

- **Cron:** Run Now no longer fires every other overdue job; monitor jobs show the right output; the time-zone note covers plain-language schedules; pause/resume failures that Hermes reported with exit 0 are caught on Mac and iPhone.
- **Kanban:** comments show again; glance counts survive assigned tasks; completing a task asks for the result Hermes requires; a card dragged to Running that Hermes didn't start goes back with the reason; "Enable kanban tools" now reaches Scarf's chats on 0.21.5 and explains the version requirement below it.
- **Skills and plugins:** flat and deeply nested skills are found; catalog plugin updates no longer read as failures; Hub search on "All Sources" searches everything on 0.21.4+.
- **Voice:** Hermes Voice finds Python on fresh official installs and says when it fell back to the system voice.
- **Sessions:** Export All no longer offers formats Hermes refuses; compressed chats export in full; kanban worker and one-shot sessions stay out of the lists, like in Hermes.
- **Projects:** the project Sessions tab finds older chats; fleet apply copies template cron jobs; Project Doctor handles symlinked folders; the same folder can't be added twice; mini-apps say they're local-only on a remote server instead of showing a 403.
- The bundled `/scarf-*` commands describe the dashboard widgets that actually exist, and the Proxy help shows the right sign-in command.

## Under the hood

- About 4,230 ScarfCore tests and 1,930 Mac app tests, all run serially; the Smoke UI gate passes against a live Hermes 0.21.5. Most fixes have a test built from Hermes's exact output at the release tag, and several round-trip through Hermes's own code.
- The provider-table check now has 8 lanes (8 of 8 pass), including one that rebuilds the routable-provider list from Hermes's source; a second script re-measures it across all 32 Hermes releases since v0.6.
- Tests no longer touch your real `~/.hermes` or kanban board.
- Every new string is translated into all six supported languages.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight and the App Store; the iOS changes above ride its next build.
- Compatible with Hermes v0.6.0 through v0.21.5. Fixes that depend on a Hermes release are gated to it; the rest apply to every supported version.
- If a project's instructions stopped reaching the agent after using Scarf, open the project's chat once: on Hermes older than 0.16 Scarf moves its notes into your CLAUDE.md / .cursorrules; on 0.16 and later it removes them from your files entirely. Either way it deletes the AGENTS.md it had created (only if that file holds nothing but Scarf's notes).
