---
title: Scarf UI gate runs in the scarf-ui Tart VM
type: note
permalink: scarf/operations/scarf-ui-gate-runs-in-the-scarf-ui-tart-vm
tags: [testing, ui-tests, tart, vm, release-gate]
source_paths: [scripts/ui-gate-vm.sh, scripts/release.sh, scripts/ui-gate.sh]
source_paths_inferred: false
source_sha: daa40485a10bcf22688d5e4b8f16e43de182a70c
created: 2026-10-26
updated: 2026-11-08
reviewed: 2026-11-01
reviewed_by: audit:claude-code (background)
---

Since 2026-10-26 Scarf's XCUITest plans run in a dedicated Tart VM via scripts/ui-gate-vm.sh instead of on Alan's screen (on-host UI tests take over the Mac). First full green: Hermes v0.22.5 and v0.21.5, Smoke/Full/Live all PASS at commit 85d51c42.

## Observations
- [convention] Run `scripts/ui-gate-vm.sh --hermes-tag <tag> --plans Smoke|Full|Live` one plan per invocation (UI-only by default; scarfTests unit tests run headless on the host). It builds on the host once, installs the Hermes tag in the guest with `uv sync --frozen --extra acp` from a depth-1 clone (keeps .git so v0.22.x knows its version), seeds the fixture there, runs test-without-building, retries purge-killed tests once, and verifies the guest clean. `--credentials-only` shows what would be copied (names only) without touching a VM #testing
- [fact] VM `scarf-ui`: clone of ScarfRack's scarfrack-uitest-27, `tart set --display 1920x1440 --no-display-refit` (Scarf's UI tests need a 1500x1200 window; 1920x1200 leaves only 1080 usable), 80 GB disk but the guest boot container is still 44 GB (recovery partition after it; SIP blocks removal), plus an attached 40 GB work disk. Boot: `tart run scarf-ui --no-graphics --no-audio --dir=xcode:/Applications/Xcode-beta.app:ro --disk=$HOME/.tart/scarf-ui-logs/scarf-work.img` — needs the Bash sandbox off (VZ can't see /Applications otherwise). Guest ~/work and ~/results symlink to /Volumes/ScarfWork #vm
- [gotcha] macOS kills the XCUITest runner (runningboardd CacheDelete, `deleted` lowDiskThreshold = 10 GiB) when the guest boot volume drops under 10 GiB. After Spotlight off, Software Update auto-download off and cache clears it sits at ~10.6-11 GB — thin. The script reroutes uv/pip/XDG/TMPDIR to the work disk and reruns purge-killed tests once. Real fix: a guest built with a bigger boot container #vm
- [constraint] Credentials: only the ACTIVE model provider's key variable(s), derived by `ast` from the tag's hermes_cli/auth.py registry (OpenRouter via its OPENROUTER_* constants); config.yaml rebuilt with model fields only; auth.json never copied (OAuth providers stop the run unless --allow-oauth-provider); GITHUB_TOKEN/GH_TOKEN/HF_TOKEN/AWS_*/CLAUDE_CODE_OAUTH_TOKEN never copied. Messaging-platform tokens never go in #security
- [gotcha] The XCUITest runner is App-Sandboxed (no network.server), so on Hermes 0.22.x `hermes -z` from inside a UI test can't start the gateway (loopback bind EPERM). The chat journey reads a `.scarf-provider-verified` marker the fixture builder writes after its real chats instead #testing
- [convention] Live plan can run against either a loopback "remote" (127.0.0.1, same guest sshd + scarf-ui's local home copy) or a real SSH server via `--real-remote user@host[:port] --real-remote-key FILE` (only for Live, only with both flags). Real server: throwaway Hermes home (~scarf-ui-gate-<stamp>), memory/disk watcher (stops run if available < 100 MB or disk free < 30 MB, env SCARF_VM_REAL_REMOTE_MIN_MB), cleanup on every exit. UI test can't ssh itself; watch script writes process list + state.db mirror, once/second #testing #vm
- [decision] Lock (9956e2a8, 9c68e072): a kernel `flock` on `$RIG_HOME/locks/scarf-ui.lockf`, taken on the script's own fd 9 via a one-line python3 call; no stale-lock takeover code at all. `/usr/bin/lockf` was rejected: the lock belongs to the lockf process, so `kill -9` of lockf frees it while the command keeps running. `--reuse` accepts only `scarf-ui` (ScarfRack's ui-dev uses a different mkdir lock and must not be shared). Two earlier mkdir+mutex designs failed audits on takeover races #vm

## Relations
- relates_to [[UI-test fixture home builder (make-ui-fixture.sh) contract]]
- relates_to [[Mac scarfTests run green only serially, and an unsigned test host can stall on a keychain prompt]]
- relates_to [[Hermes v0.22 Compatibility Decisions]]

- [operations] From commit 78413041 (after v3.7.0), release.sh runs the gate as host unit tests (ui-gate.sh --unit-only) plus Full,Live in scarf-ui (ui-gate-vm.sh --summary), booting a stopped VM headless; --host-ui-gate is the old on-screen gate, --gate-only is a rehearsal that stops before the bump. No usable VM stops the release; it never falls back to the screen #release
- [gotcha] Never edit scripts/release.sh or ui-gate*.sh in a checkout where a release is running: bash reads the script from its open file as it goes, so an in-place edit broke a live 3.7.0 run on 2026-10-26. Change them in a worktree #release #agents
- [flaky] ChatJourneyUITests/testKanbanChipCountFollowsTheChatAndCountsReview failed once inside the Live plan (chip 1, expected 2) and passed alone in 47 s, so it's an in-plan ordering/timing flake #testing


- [decision] 2026-11-08 (branch feat/hermes-v0230-parity, uncommitted at time of writing): the VM gate runs as a REAL USER. Hermes comes from the tag's own scripts/install.sh --commit <sha> --non-interactive --skip-browser --skip-computer-use into ~/.hermes; the fixture is seeded IN ~/.hermes; the app launches with no SCARF_HERMES_HOME/HERMES_HOME (runner env TEST_RUNNER_SCARF_UITEST_REAL_HOME=1). Before each test ScarfUITestCase.resetRealHome writes a token into the runner container's tmp; guest.sh reset_loop stops app + gateway + hermes and rsyncs the seeded snapshot back. The runner is re-signed on the host with home-relative read-write /.hermes/. Host runs (ui-gate.sh) unchanged. Fixed the v0.22.6+ Live failures (gateway as gui/<uid> launchd job can't use a home inside the runner container) #vm #testing
- [fact] The installer's payload in ~/.hermes is hermes-agent/ (code), tools/ (Python) and installs/ (dependency venv): never wipe, snapshot or copy them. A copied installs/ in a second data root fails ACP with "dependency environment is missing or outside this install". ~/.local/bin/hermes* are one-line exec scripts (not symlinks). The sandboxed runner can't run the installed hermes (git-derived version), so the gate passes SCARF_UITEST_HERMES_VERSION #vm
- [fact] scarf-ui rebuilt 2026-11-08 from its own 120 GB golden (scarf-golden-27 → scarf-uitest-27, ScarfRack rig copy with VM_DISK_GB=120): ~70 GB free on boot, no work disk. Guest needs /Applications/Xcode.app → shared Xcode + xcode-select (the /usr/bin shims reject a non-.app path) so /usr/bin/git works. First green: Full 21 pass / 0 fail, Live 17 pass / 0 fail at v0.23.0 #vm
- [gotcha] Host ui-gate.sh on a Mac whose UI automation isn't authorized dies "Timed out while enabling automation mode" (RUNNER-FAILED, no UI test runs) unless someone approves the prompt; a host whose own Hermes writes ~/.hermes/state.db mid-run trips the fixture self-check #testing
