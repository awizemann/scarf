# Scarf 3.0.0

Scarf 3.0 is two releases' worth of ambition landing at once: **Bot Mode grows up**, and **the entire application went through a full audit and came out harder, faster, more honest, and more accessible**. There are no breaking changes — 3.0 marks a milestone, not a migration. Compatibility spans Hermes v0.6.0 through v0.21.0, unchanged.

## Bots, complete

The Bots section introduced in v2.24 now configures the *agent*, not just its face — closing the gap with (and in places passing) Hermes's own desktop:

- **Per-bot model pins** with honest provenance: an unpinned bot says "Hermes default" — because profiles genuinely don't inherit your main profile's model, and now the UI tells the truth about it.
- **SOUL.md editing** with a real conflict guard: external edits are detected, and you choose reload or overwrite — never a silent clobber.
- **Per-bot toolsets and MCP servers**, toggled from the bot's Agent pane; skills shown honestly read-only (the CLI offers no write path, and we don't fake one).
- **A roster that scales**: search, recent-activity ordering with carrier-aware last-message previews, live presence, custom avatars with graceful fallbacks — and a rebuilt scanner that paints a 12-profile SSH roster in **one** round-trip instead of sixty.
- Routines gained delete, input validation, and delegation parity with Hermes desktop; remote bots share async-run state with the Peers section instead of drifting.

## The 3.0 audit

Every sidebar section was independently audited across five lenses — correctness, security, performance, translation, accessibility — and everything blocking was fixed:

**Security.** Dashboard widgets can no longer be tricked into reading files outside the project via symlinks; mini-app permission grants are fingerprinted, so an app that widens its permissions must be re-approved, and agent-generated apps no longer arrive with file access pre-ticked; webview widgets are pinned to their declared https host (Mac *and* iOS); links in agent-authored markdown pass a scheme allowlist everywhere; a remote-shell escape through tool-call metadata is closed with encoding, not hope; secrets moved out of process argv where an env path exists; remote `.env` writes are now private-mode; and every place user or agent text meets a command line got an end-of-options guard.

**Repaired surfaces.** Five sections were quietly lying and now aren't: **Plugins** showed fabricated enable state (it read a marker file Hermes never writes) and reported installs that landed disabled; **Webhooks** listed nothing because its parser predated the CLI's format — and the auto-generated signing secret it used to discard is now shown once, copyable; **Profiles** export produced `.tar.gz` while promising `.zip` (remote export literally could not work) and delete claimed success without deleting; **MCP** server adds piped blind confirmations that could write a junk credential — replaced with state-aware plans and honest outcome parsing, and the editor now edits the *remote* host's config when you're on one; **one-shot cron jobs** can be edited again.

**Honest numbers.** The Dashboard's "Last 7 days" now means seven days; Insights computes every card from one session population; Sessions' Model column has data, "Updated" reflects activity, deletes report failures, and the Memory editor **never discards your unsaved text** because the agent happened to write a file.

**Performance.** Mutation actions across a dozen surfaces moved off the main thread (no more beachballs pressing Start on a remote gateway); Logs reads are bounded and capped; the sessions table is lazy; Kanban's polling pauses with the window and backs off on failure; Health probes run concurrently.

**Fully localized, for real this time.** An entire class of UI chrome — settings rows, section headers, empty states, loading overlays — was structurally invisible to the translation catalog; translations we'd already paid for were unreachable at runtime. The components were fixed, 216 keys added, and the catalog now stands at **2,374 keys across six languages** with plural forms that use real grammar agreement, guarded by tests that make silent regressions fail the build.

**Accessible throughout.** VoiceOver and Voice Control coverage extended to the surfaces the earlier pass missed: sessions tables (with a structural fix — the project chip is now genuinely focusable), Kanban cards (the "this task will never run" warning is finally audible), tools, logs, health, curator, and chat transcripts; animations respect Reduce Motion.

## Under the hood

- 561 tests added since v2.24.0 (ScarfCore at 1,818, app suites at 607); Mac and iOS both green.
- The audit itself was adversarial: findings were verified before fixing (six were refuted with evidence), the security and contract fixes were independently re-audited, and that re-audit caught three regressions in the fixes themselves — including a BSD/GNU `cp -n` divergence — all closed before this cut.
- Known edges, documented not hidden: remote-project symlink containment is best-effort (the guarantee is verified locally); view-model status banners remain English pending an app-wide policy pass; group chats between bots remain deliberately out of scope.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release. Nothing to migrate.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight.
- Compatible with Hermes v0.6.0 through v0.21.0. Capability-gated surfaces appear only when the connected host supports them; older hosts render exactly as before.
