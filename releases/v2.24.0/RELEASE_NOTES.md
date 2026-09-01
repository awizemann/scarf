# Scarf v2.24.0

Meet your bots. Hermes v0.21 made agents into a society — named bots with faces, profiles, and their own conversations — and this release gives that society a native Mac home: a new **Bots** section at the top of the sidebar, above Chat. Create bots, give them faces, talk to them over live streaming chat, schedule their routines, and message your bots on other machines. Under it all, this release went through a five-audit pre-release review pass (Bot Mode, a two-release regression span, Chat, Bots, and Settings), and everything those audits flagged is fixed here.

## Bots — a society of agents, natively ⚙

- **The roster.** Every bot on your host (a bot is a Hermes profile with bot identity), with deterministic native avatars — your custom picture when one is set, a generated face otherwise — pinned bots first, hidden bots tucked away, and any plain profile one click from becoming a bot ("Make a Bot"). Appears on Hermes v0.20.3+.
- **Full create and edit.** Name, role, color, shape, pin, hide, avatar (images are downscaled to fit Hermes's limits), rename, and delete — with careful metadata writes that preserve everything else in the profile, including comments Hermes's own tools would destroy.
- **Live streaming conversations.** Each bot's canonical Bot Chat opens as a real Scarf chat — streaming tokens, thinking, tool cards, and inline permission prompts — over ACP, locally or across plain SSH. Messages from other bots render with the sending bot's face and name. Bots created in Hermes's desktop app appear in Scarf automatically, and vice versa: same profiles, same chats. (Starting a brand-new Bot Chat from Scarf needs Hermes v0.21; conversations that already exist work from v0.20.3.)
- **Routines.** Schedule per-bot jobs from the bot's own pane; they're namespaced and delegation-wrapped exactly the way Hermes's desktop does it, so routines made in either app are recognized — and run as the right bot, with the right memory and credentials.
- **Remote bots.** Your `hermes peer` registry shows up in the roster: DM a bot on another machine or fire an async run and watch its status, without Scarf ever touching peer keys.
- Honest edges, stated in the UI: Bot Chats Scarf creates are visible in that profile's session list (Hermes hides its own via a channel Scarf deliberately doesn't write), renaming a session titled "Bot Chat" now asks first — it detaches the bot's history — and group chats are not in this release.

## The audit pass, and what it fixed

Before this cut, five independent audits reviewed the last two releases plus the Bots work end to end. Everything blocking is fixed in this release:

- **Bot conversations get the full slash-command menu** — they now receive the host's capability information like main Chat does.
- **Failures look like failures** — a rejected routine no longer flashes green and vanishes; errors stay until dismissed, in Cron too.
- **"Remove from Bots" now actually removes** the bot identity (returning the profile to plain-profile status); "Hide" remains the gentle option.
- **A Settings toggle that did nothing now works** — the per-platform gateway restart notification was written to a key path Hermes never read.
- **Three dead Settings rows removed** (`redaction.enabled`, `tts.xai.model`, `agent.verbose`) — each verified against Hermes source before removal; the real redaction switch lives on the Security tab.
- **Groundwork for localizing everything**: Scarf's shared UI components (page headers, section headers, fields, badges) previously bypassed the string catalog entirely — ~68 screens' worth of chrome. They're now extraction-ready; translations for the new sections land in the next localization pass, so this release's new surfaces are English-first.
- **Accessibility gaps closed** on the Peers section and the prompt editors in Cron and Routines, back to the bar v2.22.0 set.

## Under the hood

- 87 new tests since v2.23.0 (ScarfCore at 1597, app suites at 502), including PyYAML round-trip proofs for every profile-metadata write shape, byte-identity checks against Hermes's avatar and routine formats, and scripted ACP failure-path coverage.
- New capability flags with source-verified floors: Bots at v0.20.3 (where the primitives actually shipped — earlier than Hermes's own release notes imply), Bot Chat creation at v0.21, peer runs at v0.21.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight; this release requires no iOS-side update.
- Compatible with Hermes v0.6.0 through v0.21.0 (target unchanged from v2.23.0). Sections marked ⚙ appear only when the connected host supports them; older hosts render identically to v2.23.0.
- The new Bots and Peers sections are English-only in this release; translations follow in the next localization pass.
