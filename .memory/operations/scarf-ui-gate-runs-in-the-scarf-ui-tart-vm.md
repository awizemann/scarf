---
title: Scarf UI gate runs in the scarf-ui Tart VM
type: note
permalink: scarf/operations/scarf-ui-gate-runs-in-the-scarf-ui-tart-vm
tags: [testing, ui-tests, tart, vm, release-gate]
source_paths: [scripts/ui-gate-vm.sh, scripts/release.sh, scripts/ui-gate.sh]
source_paths_inferred: false
source_sha: 7841304189e4c501dc42732b3af7299beae11ab4
created: 2026-10-26
updated: 2026-10-26
reviewed: 2026-10-26
reviewed_by: claude-opus-5-5
---

Since 2026-10-26 Scarf's XCUITest plans run in a dedicated Tart VM via scripts/ui-gate-vm.sh instead of on Alan's screen (on-host UI tests take over the Mac). First full green: Hermes v0.22.5 and v0.21.5, Smoke/Full/Live all PASS at commit 85d51c42.

## Observations
- [convention] Run `scripts/ui-gate-vm.sh --hermes-tag <tag> --plans Smoke|Full|Live` one plan per invocation (UI-only by default; scarfTests unit tests run headless on the host). It builds on the host, installs the Hermes tag in the guest with `uv sync --frozen --extra acp` from a depth-1 clone (keeps .git so v0.22.x knows its version), seeds the fixture there, runs test-without-building, retries purge-killed tests once, and verifies the guest clean. `--credentials-only` shows what would be copied (names only) without touching a VM #testing
- [fact] VM `scarf-ui`: clone of ScarfRack's scarfrack-uitest-27, `tart set --display 1920x1440 --no-display-refit` (Scarf's UI tests need a 1500x1200 window; 1920x1200 leaves only 1080 usable), 80 GB disk but the guest boot container is still 44 GB (recovery partition after it; SIP blocks removal), plus an attached 40 GB work disk. Boot: `tart run scarf-ui --no-graphics --no-audio --dir=xcode:/Applications/Xcode-beta.app:ro --disk=$HOME/.tart/scarf-ui-logs/scarf-work.img` — needs the Bash sandbox off (VZ can't see /Applications otherwise). Guest ~/work and ~/results symlink to /Volumes/ScarfWork #vm
- [gotcha] macOS kills the XCUITest runner (runningboardd CacheDelete, `deleted` lowDiskThreshold = 10 GiB) when the guest boot volume drops under 10 GiB. After Spotlight off, Software Update auto-download off and cache clears it sits at ~10.6-11 GB — thin. The script reroutes uv/pip/XDG/TMPDIR to the work disk and reruns purge-killed tests once. Real fix: a guest built with a bigger boot container #vm
- [constraint] Credentials: only the ACTIVE model provider's key variable(s), derived by `ast` from the tag's hermes_cli/auth.py registry (OpenRouter via its OPENROUTER_* constants); config.yaml rebuilt with model fields only; auth.json never copied (OAuth providers stop the run unless --allow-oauth-provider); GITHUB_TOKEN/GH_TOKEN/HF_TOKEN/AWS_*/CLAUDE_CODE_OAUTH_TOKEN never copied. Messaging-platform tokens never go in #security
- [gotcha] The XCUITest runner is App-Sandboxed (no network.server), so on Hermes 0.22.x `hermes -z` from inside a UI test can't start the gateway (loopback bind EPERM). The chat journey reads a `.scarf-provider-verified` marker the fixture builder writes after its real chats instead #testing

## Relations
- relates_to [[UI-test fixture home builder (make-ui-fixture.sh) contract]]
- relates_to [[Mac scarfTests run green only serially, and an unsigned test host can stall on a keychain prompt]]
- relates_to [[Hermes v0.22 Compatibility Decisions]]


- [decision] Lock (9956e2a8, 9c68e072): a kernel `flock` on `$RIG_HOME/locks/scarf-ui.lockf`, taken on the script's own fd 9 via a one-line python3 call; no stale-lock takeover code at all. `/usr/bin/lockf` was rejected: the lock belongs to the lockf process, so `kill -9` of lockf frees it while the command keeps running. `--reuse` accepts only `scarf-ui` (ScarfRack's ui-dev uses a different mkdir lock and must not be shared). Two earlier mkdir+mutex designs failed audits on takeover races #vm


- [operations] From commit 78413041 (after v3.7.0), release.sh runs the gate as host unit tests (ui-gate.sh --unit-only) plus Full,Live in scarf-ui (ui-gate-vm.sh --summary), booting a stopped VM headless; --host-ui-gate is the old on-screen gate, --gate-only is a rehearsal that stops before the bump. No usable VM stops the release; it never falls back to the screen #release
- [gotcha] Never edit scripts/release.sh or ui-gate*.sh in a checkout where a release is running: bash reads the script from its open file as it goes, so an in-place edit broke a live 3.7.0 run on 2026-10-26. Change them in a worktree #release #agents
- [flaky] ChatJourneyUITests/testKanbanChipCountFollowsTheChatAndCountsReview failed once inside the Live plan (chip 1, expected 2) and passed alone in 47 s, so it's an in-plan ordering/timing flake #testing
