# Scarf v3.7.0

This release brings Scarf up to **Hermes v0.22.5**, covering everything Hermes shipped from v0.21.6 through v0.22.5. The biggest change on Hermes's side is that, from v0.22.3, chat no longer runs in its own process: `hermes acp` became a window onto Hermes's gateway, the same background service your other apps and bots talk to. Scarf now follows that new chat model end to end, so you can resume chats you started in the Hermes CLI, TUI or Desktop app, answer Hermes's clarifying questions, and close Scarf without stopping a reply that's still running. Scarf also respects Hermes's new safety rules: it no longer kills a gateway that Hermes refused to stop because chats were still live, and it stops you from saving a `config.yaml` that the new, stricter Hermes would refuse to load. Everything new is gated to the Hermes version that introduced it. Nothing changes on a host you don't upgrade.

## Chat on Hermes's gateway

From Hermes v0.22.3, every chat is a gateway session. The protocol Scarf speaks didn't change, but the way Hermes behaves behind it did, in ways that would have made Scarf quietly do the wrong thing on the day you upgraded:

- **Resuming chats started elsewhere works.** Hermes now stores chats started in the CLI, TUI, Desktop app or over ACP as one "local" kind, with the real origin kept separately. Scarf only resumed chats marked as its own kind, so opening one of these silently started a fresh chat instead. Scarf now loads them, so the transcript and the model's context carry on. A reopened chat also keeps its own working folder: Scarf used to send the project or home folder, and Hermes then quietly moved the chat to your home folder. If the chat's folder no longer exists, Scarf reopens it in the project or home folder instead. If Hermes still refuses (for example, no model is set for it), Scarf shows the error with a hint, rather than quietly starting a new chat and losing the conversation.
- **`/queue` keeps the chat working.** A queued prompt is now its own turn on Hermes's side, and the running reply finishes before the queued one starts. Scarf used to clear its queue and say "done" at that point. It now stays in the working state until the queued prompt has its answer.
- **Clarifying questions are question cards.** When Hermes needs you to pick an option, the question arrives the way a tool approval does. Scarf showed it as "Tool Approval Required", and pressing **Skip** counted as yes. It now has its own heading, and Skip is a decline. Scarf reads every approval answer by what the option means rather than its position, on every Hermes version.
- **Model switches can ask first.** Hermes may now ask you to confirm a model change mid-chat. Scarf shows that as its own card, and a switch you decline reverts quietly.
- **Closing Scarf no longer stops a running reply.** The gateway keeps working after Scarf disconnects. Scarf's "connection lost" line no longer says the reply stopped, and the "Allow edits for this session" button is hidden mid-turn where Hermes can't change it.
- **Smaller chat changes.** Long chats that Hermes compresses are followed from the database, because the gateway no longer announces it. The approval-mode chip follows mode changes Hermes reports. `/goal` and other commands Hermes handles itself no longer get a "sent as an ordinary prompt" note. If chat can't start because an old gateway is still running or the gateway belongs to another profile, Scarf explains it in plain words.

## Gateway safety

From v0.22.3, Hermes refuses to stop or restart the gateway while chats are live, to protect the work in progress. Your open Scarf chat counts. Scarf read that refusal as a failure and fell back to killing the gateway process, interrupting exactly the work Hermes was protecting.

Now Scarf shows Hermes's reason and asks: **Interrupt N live sessions and stop/restart the gateway?** Only a yes passes Hermes's own confirmation. Scarf never falls back to killing the process after a refusal, on any Hermes version. This applies in Health, the Gateway pane, Platforms, MCP and the menu bar.

Also on the gateway:

- A gateway you started by hand (with no installed service) now restarts in the background through Hermes's own `restart --detach` on v0.22.3+, instead of being refused or tied to Scarf.
- Right after an upgrade, the gateway can be running but unable to serve the new Hermes. The Gateway pane now says so, with Hermes's reason and a Restart button, instead of showing "running".

## Strict config loading

From v0.21.6, Hermes loads `config.yaml` strictly: **a key written twice in the same section stops Hermes, its gateway and cron from starting.** Older Hermes quietly used the last one. On these hosts, Scarf now finds duplicate keys, shows the error on the Dashboard (Mac) and in Settings (ScarfGo), and refuses to save a file that contains one, whichever screen is saving. Hermes also now reads a bare `y` or `n` as yes or no, so Scarf puts quotes around those values when it writes them, keeping them as text on every Hermes version.

## Features that moved into Hermes plugins

Hermes moved several built-in features into installable plugins from its catalog: the memory providers (Honcho, mem0, OpenViking, Supermemory, Hindsight, Holographic), Home Assistant, Spotify and the Singularity terminal. Your settings stay put, but the feature only works once the plugin is installed and enabled. Scarf now shows a short note where you use each of these, with **Install Plugin** or **Enable**. Spotify sign-in uses the plugin's own `hermes spotify login`, with your client ID passed along as before. A memory provider that needs its own setup points you to `hermes memory setup <name>` in Terminal.

## Sessions show where a chat was created

The Sessions list, badges and icons now show where a chat really started (CLI, TUI, Desktop or ACP) instead of "local" for all of them. When Hermes refuses to delete a session that is still active or has a turn running, Scarf shows Hermes's reason instead of "exited 1".

## Fixed on every Hermes version

- **Token usage was double-counted.** Hermes reports each chat's prompt tokens as a running total, and Scarf added each turn's total to the previous ones. Scarf now uses the total as reported.
- **Health no longer asks old Hermes for API keys in plain text.** Hermes v0.21.6 shortened `hermes status` to a one-screen summary, which left Scarf's Health status panel empty. Scarf now asks for the full report with `status --all`, but **only on v0.21.6 and later**: on Hermes versions from about v0.6 to v0.19, that same flag printed API keys unredacted, so Scarf never sends it there.
- **No more false "stale provider" banner for vLLM or llama.cpp.** Hermes treats `vllm`, `llamacpp`, `llama.cpp`, `llama-cpp` and `local` as the custom provider, and always has. Scarf now does the same.

## Smaller fixes

- Enabling or disabling a plugin on v0.22.3+ no longer shows a failure banner when it worked.
- A plugin that needs your consent to install its dependencies no longer reads as "Installed" while it's off. Scarf asks, then enables it with Hermes's own `plugins enable`, never a forced reinstall that would also skip Hermes's security scan.
- An import that only partly restored reads as partial success again, with Hermes's notes, instead of a failure.
- Duplicating a cron job keeps its interpreter setting.
- New providers and catalog entries: Solstice routing (v0.21.6+), the `krea-3` image model and the `rentahuman` MCP server (v0.22.3+).
- The Tirith Sandbox settings are hidden on v0.21.6+, where Hermes removed them.
- When Hermes's chat (ACP) packages are missing from an install, Scarf says so and shows the command Hermes suggests to add them.
- Also: kanban shows two new diagnostic kinds, restoring a built-in skill reads as success, Health recognises a Hermes newer than the stable release, the Plugins pane no longer runs a removed compatibility check on every load, and session recency ignores bad timestamps the way Hermes does.

## Under the hood

- New capability flags for Hermes v0.21.6, v0.21.7, v0.22.3 and v0.22.5, with tests for every floor. v0.22.2 reverted v0.22.1's gateway work and v0.22.3 restored it, so Scarf treats v0.22.1 and v0.22.3+ as gateway-backed.
- Hermes now tags releases `vX.Y.Z`, and the date in `hermes --version` stays at 2026.9.24. Scarf reads the version number, so detection is unaffected.
- The provider-table checker now reads providers that new Hermes plugins register inline, and checks against v0.22.5.
- The UI tests now run in a Tart virtual machine, against a chosen Hermes version, so they never take over the Mac's screen.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 15.0+ (Apple Silicon and Intel). ScarfGo (iOS 18.6+) gets the shared fixes in its next App Store and TestFlight build.
- Compatible with Hermes v0.6.0 through v0.22.5. Older Hermes versions keep working exactly as before; features from v0.21.6 and later appear only on hosts that have them.
- After upgrading Hermes to v0.21.6 or later, check the Dashboard for a duplicate-key warning before restarting the gateway, and install the plugins for any memory provider, Home Assistant, Spotify or Singularity setup you use.
