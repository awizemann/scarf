# Scarf v3.9.1

**Scarf now supports Hermes v0.23.4, and the Gateway screen sees gateways started by Hermes v0.23.** Every change below is checked against the Hermes v0.23.1–v0.23.4 releases themselves, and each appears only on a Hermes that has it. On an older host, Scarf looks and behaves exactly as 3.9.0 did.

## Gateway status on Hermes v0.23 (gh#154)

Hermes v0.23 starts its gateway through a small inline launcher (`python -c …`) instead of the `hermes gateway` command. Scarf looked only for the old command line, so a running gateway showed as stopped. Scarf now recognises both forms, and reads the full command line (`ps -ww`) so long paths aren't cut off.

## Faster chat reopen in ScarfGo (gh#150)

- Reopening a chat now looks the session up in Hermes's database once, instead of three to five times.
- The "is a model set up?" check is remembered per server, so it no longer runs on every chat open.
- Each step of opening a chat is now timed in **Settings → Diagnostics → Performance**, so slow opens can be pinned down.

## Hermes v0.23.1–v0.23.4

- **Webhooks (v0.23.2+).** Hermes now masks a new webhook's secret in its output; Scarf reads the real secret so the copy-once sheet shows it again. A new **Signature** picker sets the signing scheme, and re-adding an existing webhook keeps its current scheme unless you choose another.
- **Profiles (v0.23.4).** An interrupted profile delete no longer shows up as a phantom "Deletion" profile.
- **Prompt caching (v0.23.3).** The cache TTL setting offers **auto**, Hermes's new default.
- **Clarify timeout (v0.23.1+).** A new field in Agent settings; 0 means no limit. It respects the older `clarify.timeout` key if you set it before.
- **Yuanbao (v0.23.1+).** Yuanbao moved out of Hermes core into a plugin; Scarf now points you to the Plugins tab to set it up.
- **Cron (v0.23.2+).** Duplicating a job keeps its reply-formatting setting.
- **Gateway restart (v0.23.2+).** When Hermes waits for idle before restarting, Scarf says so, and no longer reports a false failure after about 32 minutes.

## Smaller fixes

- Remembered Hermes versions are kept in one capped settings entry instead of growing without limit.
- Copies of Scarf launched in test mode disable **Check for Updates** instead of showing a Sparkle error.

## Under the hood

- New tests cover each Hermes v0.23.x version floor, the webhook output parsing, profile-list parsing, settings, and the gateway restart wording.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 15.0+ (Apple Silicon and Intel).
- Compatible with Hermes v0.6.0 through v0.23.4. Features named above need the Hermes version given next to them.
- The ScarfGo chat-reopen improvements reach iPhone with the next TestFlight build.
