# Building Scarf

Scarf is a native macOS app built with Xcode. For contributor builds, use the local script:

```bash
./scripts/local-build.sh
```

Requirements:

- macOS 14.6 (Sonoma) or newer at runtime — that's the app's `MACOSX_DEPLOYMENT_TARGET`. Sonoma support is intentional and load-bearing; do not raise this without an explicit decision to drop Sonoma users
- Xcode 16.0 or newer, selected by `xcode-select` (needed for Swift 6 strict-concurrency features the project uses)
- Metal toolchain installed
- Hermes installed at `~/.hermes/` (see the project README for setup)

If the Metal toolchain is missing, the script will offer to install it in interactive shells. You can also install it manually:

```bash
xcodebuild -downloadComponent MetalToolchain
```

`scripts/local-build.sh` resolves Swift package dependencies, detects `arm64` vs `x86_64`, and builds the Debug app unsigned. Signing is intentionally disabled for local Debug builds so contributors do not need the maintainer's Apple Developer account.

Release signing is separate from contributor builds. Maintainers should continue using the existing release process for signed distributable builds.

## UI release gate

Before every release, `scripts/release.sh` runs `scripts/ui-gate.sh`, which builds a
throwaway, seeded Hermes home (`scripts/ui-fixture/make-ui-fixture.sh`) and then runs
unit tests plus the `Full` and `Live` XCUITest plans against it. It needs:

- A real `hermes` install (`~/.local/bin/hermes` by default, override with `HERMES_BIN`)
- Your own Hermes credentials/config under `~/.hermes` (copied into the throwaway
  fixture home, never written back)

It spends a few cents of real LLM tokens per run (the fixture seeds a handful of genuine
one-shot chat sessions so the app faces real data). Typical wall time on an M-series Mac
is a few minutes for `Smoke` alone, and 10–20 minutes for the full `Full` + `Live` run
release.sh performs.

Run it standalone:

```bash
scripts/ui-gate.sh --smoke-only --summary /tmp/ui-gate-summary.md   # fast sanity
scripts/ui-gate.sh --skip-live --summary /tmp/ui-gate-summary.md    # no live/Chat coverage
scripts/ui-gate.sh --summary /tmp/ui-gate-summary.md                # full gate (Full + Live)
```

`scripts/release.sh --skip-ui-tests` bypasses the gate with a loud warning and records
"SKIPPED by --skip-ui-tests" into `releases/v<VERSION>/UI-GATE.md` instead of running it —
use only when you already know the app is broken in a way you're intentionally shipping
around (e.g. re-running a failed release step that already passed the gate).
