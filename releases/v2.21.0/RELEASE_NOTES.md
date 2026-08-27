# Scarf v2.21.0

This release moves Scarf's Hermes target to **v0.20.5** (v2026.8.19) — a one-patch upstream bump that nonetheless rolled up ~800 commits — and lands the one fix that genuinely could not wait: Hermes v0.20.5 removed the `hermes version` subcommand, and without this release Scarf's Health view would silently burn an agent turn on every load against an upgraded host. As always, every host back to v0.6.0 keeps working exactly as before — everything new is capability-gated at the patch level.

## Fixed ahead of your upgrade

- **Health view survives the `version` removal.** Hermes v0.20.5 dropped the bare `hermes version` subcommand; an unknown token now falls through to plugin discovery and becomes a *chat prompt* — so Scarf's version probe would have spawned a real agent turn (and burned tokens) every time the Health view loaded. The probe now selects `--version` on v0.20.5+ hosts (where it carries the full update status) and keeps `version` on older ones. When the host's version isn't yet known, Scarf probes with `--version` first — safe on every Hermes version — and it even self-corrects mid-session if you run `hermes update` while Scarf is open.
- **Profiles list stays correct.** Hermes v0.20.5 renders profiles with display names as `Display Name (canonical-id)`; Scarf now extracts the canonical id (the only argv-safe form) from the Profile column specifically, so switching, renaming, and deleting profiles keeps working on both old and new hosts — including display names that themselves contain parentheses.

## New with a v0.20.5 host

- **OpenCode Free provider** — Hermes's new zero-auth OpenCode tier (`opencode-free`, aliases `free`/`opencode_free`) is selectable in the model picker, and Scarf now understands *keyless* providers: the credential form shows "No API key needed" instead of asking for a key that doesn't exist.
- **Unlimited max turns.** Hermes v0.20.5 changed the default turn ceiling from 500 to unlimited. Scarf's Max Turns stepper (macOS and iOS) now reflects the real effective default per host version and lets you dial down to 0 = "Unlimited" on hosts that support it — older hosts keep their 1-minimum so Scarf never writes a value they can't resolve.
- **Auto speech-to-text provider.** Hermes no longer pre-seeds `stt.provider`: unset now means "autodetect the best available engine", and any stored value pins it. Scarf's STT picker gains an "Auto (unset)" option — the only way back out of a pin — while keeping the local-whisper tuning fields available either way.

## Under the hood

- New v0.20.5 capability group (`isV0205OrLater`) with the standard degradation test cluster; `hermes cron create/edit --reasoning-effort` is capability-flagged for the upcoming cron editor work.
- Provider-table invariant test that fails loudly if an aggregator entry ever drifts from Hermes's canonical ids, plus keyless-flag drift detection across all overlays.
- Analytics internals hardened: the swift-stats write key moved to a build setting, the `UsageEvent` vocabulary is now a closed contract, and usage tracking is injected behind a seam for testability. No change to what is (and isn't) collected — see the [Privacy Policy](https://awizemann.github.io/scarf/privacy/).
- 60 new tests across capabilities, provider tables, the version probe, settings resolution, and profile parsing (ScarfCore 1351 green; app-target suites green).

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight; this release requires no iOS-side update.
- Compatible with Hermes v0.6.0 through v0.20.5. On hosts below v0.20.5, all of the above stays hidden and behavior is byte-identical to v2.20.0.
