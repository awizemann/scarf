# Scarf v2.19.1

A hardening patch centered on one long-standing mystery finally solved: uninstalled projects that reappeared in the Projects sidebar. The uninstaller was never the culprit — the cockpit's own file watcher was quietly resurrecting deleted projects. That's fixed, along with a mini-app bridge polish, honest test isolation, and a documentation catch-up for the dashboard schema.

## Fixed: uninstalled projects no longer come back

Uninstalling a project template deleted the files correctly — and then the project reappeared in the registry, sometimes with its directory re-created. The root cause was a feedback loop, not the uninstaller: the deletions fired the project cockpit's file watcher, the forced reload found `.scarf/project.json` missing, and its derive-and-save fallback silently re-created both the directory and the registry row (a `try?` hid every trace).

Three changes close the loop for good:

- **A save can only describe a project that exists.** `ProjectStore.save` now refuses to write a record for a project whose root directory is gone — nothing can conjure a deleted project back into existence. The check is transport-aware: on remote (SSH) hosts, a connection blip is *not* mistaken for a deleted directory, so a flaky link surfaces as the real connection error instead of a misleading "directory no longer exists."
- **Registry removal is rename-proof.** Uninstall now matches the registry row by the project's stable id, with a normalized-path fallback (symlinks resolved, trailing slashes dropped) covering rows minted before ids existed — and covering rows whose id was re-minted for the same directory.
- **Registry write failures are loud.** A failed registry update after uninstall now shows a real "Uninstall Failed — try again" screen instead of a false success. All destructive steps are idempotent, so retrying is safe.

A launch-time side benefit: a registry row pointing at a directory you deleted by hand no longer gets that directory silently re-created — Scarf logs it and moves on.

## Fixed: UI tests wrote into the real `~/.hermes`

The template-install UI tests launched the app without the documented test-home override, so every CI-style run installed a real project into the tester's actual `~/.hermes/scarf/projects.json` — which is exactly how the resurrection bug's leftovers were first noticed. All UI test suites (including the stock launch/performance tests) now share one isolation harness: a per-run throwaway Hermes home with the sentinel marker, applied to both the app and the `hermes` CLI it spawns. Verified by hashing the real registry before and after repeated full install/uninstall journeys — byte-identical.

## Fixed: mini-app `onEvent` no longer logs an unhandled rejection

A mini-app calling `scarf.onEvent(...)` without the `events` permission grant hit an unhandled promise rejection in the console — the bridge shim dropped the subscription's failure on the floor. It now settles the promise itself and warns once, since `onEvent` has no return value to hand the caller. Granted-permission behavior is unchanged, and the fix is pinned by a regression test.

## Docs: the dashboard schema is complete again

`DASHBOARD_SCHEMA.md` documented 7 widget types; Scarf renders 12. The missing five — `markdown_file`, `log_tail`, `cron_status`, `status_grid`, and `kanban_summary` — are now documented with examples, along with `image`, the `stat` widget's `sparkline` field, and the full `list` status vocabulary (7 canonical states plus synonyms). Every field name was verified against the decoder and renderer, not the previous docs.

## Under the hood

- New unit tests: the resurrection repro (watcher-style reload after uninstall), registry matching by drifted path / legacy path / diverged id, and a fabricated unwritable-registry failure. 306 scarfTests + 1152 ScarfCore tests green.
- Shared `ScarfUITestCase` base class replaces ~100 lines of duplicated UI-test harness.
- Stale comment fixes and a README/schema widget-list sync.

## Upgrade notes

Scarf updates automatically via Sparkle; this release requires macOS 14.6+ as usual. No Hermes version change — v0.20.0 remains the target, and every earlier host back to v0.6.0 keeps working. No ScarfGo build is needed: the mini-app bridge fix rides in the shared core and ships with the next TestFlight build alongside other iOS changes.
