# Scarf v3.9.0

**Scarf now supports Hermes v0.23.0.** Every new Hermes surface in this release is checked against the v0.23.0 release itself, and each appears only on a Hermes that has it. On an older host, Scarf looks and behaves exactly as 3.8.0 did.

## New in Chat

- **Reasoning effort picker.** On Hermes v0.22.6 and later, a chip in the chat header sets how hard the model thinks. It shows the level Hermes confirms, not just the one you clicked.
- **Fast service tier.** On Hermes v0.23.0, models that offer a faster tier get a second chip to switch it on or off.
- **Reset to default model.** The model badge can put a chat back on your configured default model.

## Cron: stop a run, choose what happens to missed runs

On Hermes v0.22.6 and later:

- **Stop Run** cancels a cron job that's running now. Its run shows as cancelled.
- **Missed runs** is a per-job choice: skip runs missed while your Mac was asleep or Hermes was off, or run once when it comes back.

## Plugins: Update All and auto-update

- **Update All…** (Hermes v0.22.3 and later) previews which plugins have updates, then applies them. A plugin Hermes marks with a caution verdict asks again before it's forced.
- **Auto-update** (Hermes v0.23.0) lets Hermes keep plugins current on its own.

## GitHub Copilot and Camofox are plugins now

From Hermes v0.22.6, GitHub Copilot and the Camofox browser left Hermes's core and became plugins. Scarf follows:

- Copilot appears as a provider only once its plugin is installed **and enabled**. A chat or profile that still names Copilot without it says what's missing.
- Camofox settings show only when its plugin is ready, and the removed Record Sessions setting is hidden on these hosts.

## Smaller changes

- **Refresh running sessions** sends updated system prompts to sessions already running (Hermes v0.22.6+).
- **Lock a skill** so Hermes's curator won't change or remove it (Hermes v0.22.6+).
- Chat errors now show Hermes's full explanation under **Show details**, including what the process wrote before it stopped.
- The `ultra` fast-mode alias is only offered on Hermes v0.22.0 and later, where it exists.

## Under the hood

- The automated UI tests now run in a virtual Mac set up like a user's: Hermes installed by its own installer into `~/.hermes`, and Scarf launched with no test overrides. Every UI test passes there on Hermes v0.23.0, and on a Mac running Hermes v0.21.5.
- New UI tests cover missed-run policy, skill lock, plugin auto-update and Update All, the Camofox gating, and the reasoning picker.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 15.0+ (Apple Silicon and Intel).
- Compatible with Hermes v0.6.0 through v0.23.0. Features named above need the Hermes version given next to them.
- If you use GitHub Copilot or Camofox with Hermes v0.22.6 or later, install and enable its plugin in Hermes (`hermes plugins install github-copilot`, then enable it in Scarf's Plugins section).
