# v0.23.0 parity: handoff (2026-11-08)

Worktree `../Scarf-v0230` (branch feat/hermes-v0230-parity @ 64ce114b plus uncommitted fixes). Earlier report: documents/plans/2026-11-07-hermes-v0-23-0-branch-review-and-release-readiness.md

## Uncommitted fixes in the worktree
- `HERMES_TARGET_TAG` = v0.23.0
- Copilot/Camofox plugin checks now require the plugin to be enabled, not just installed
- The `ultra` service-tier floor is v0.22.0
- Five new UI journeys and their accessibility ids; `requireHermes(atLeast:for:)` in UITestIsolation.swift
- The plugins test's Update All check now matches the outcome banner by substring and remembers a sighting
- The applyClassifiesEveryRow test has a count guard
- **Error display:** `ACPClientError.fullServerDetails` adds Hermes's full error text to the chat "Show details" area, with a test in M1ACPTests. ChatJourney also expands Details when a chat times out.

## Gate status
- ScarfCore: 4,498 tests pass when run serially. A parallel run crashed once (the pre-existing flake t-3eed315b).
- scarfTests: 2,198 pass.
- Full plan: passes, apart from the plugins test fix above, which hasn't been re-run.
- Live plan: fails. Root cause: from v0.22.6, Hermes on macOS starts the gateway as a gui/<uid> launchd job (`gateway_runtime_start.py` → `gateway_launchd_runtime.start_gateway_job`). That job can't work with a Hermes home inside the XCUITest runner's container (`~/Library/Containers/com.scarfUITests.xctrunner/...`).
  - A/B in the guest GUI session: home in /tmp → PONG; home in the container → fails.
  - Over SSH (no GUI session) Hermes falls back to a plain child process, which works.
  - Real users are fine.

## Alan's direction: VM tests run as a real user
1. **Rebuild the scarf-ui VM with a bigger boot disk** (NEXT). The boot disk currently has 8.6 GiB free, under the 10 GiB point where runningboardd kills the test runner. Notes: memory operations/scarf-ui-gate-runs-in-the-scarf-ui-tart-vm; the clone comes from ScarfRack's scarfrack-uitest-27, display 1920x1440, work disk ~/.tart/scarf-ui-logs/scarf-work.img.
2. **Then the gate changes.** In VM mode only (host runs unchanged):
   - Install Hermes with the tag's own `scripts/install.sh --commit <sha> --non-interactive --skip-browser --skip-computer-use`. Verified in the guest: about 2 GB, lands at ~/.hermes/hermes-agent with ~/.local/bin/hermes, v0.23.0.
   - Seed the fixture in place in ~/.hermes, snapshot everything except hermes-agent/, and restore that snapshot before each test after stopping the gateway.
   - Launch the app with no SCARF_HERMES_HOME.
   - Re-sign the runner with a read-write exception for ~/.hermes (and the resolved path if it is a symlink).
   - Skip ConfigJourney's real-home tripwire in VM mode.
   - Cleanup removes ~/.hermes, the snapshot and the ~/.local/bin entries.
   - With a big enough boot disk, ~/.hermes can be a plain directory rather than a symlink to the work disk.
3. **Leftover from the experiment:** ~/.hermes in the guest is a symlink to /Volumes/ScarfWork/probe/hermes-home (a real install with a .env). Remove it, or discard it with the VM rebuild.

## Still open
Update All drift (apply per name?), the unused `hasSessionsNonZeroExit`, manual checks of Cron Stop and service tier, commits, memory notes, release prep.
