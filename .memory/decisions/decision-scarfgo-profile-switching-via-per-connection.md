---
title: Decision: ScarfGo profile switching via per-connection scoping (Design B, #120)
type: note
permalink: scarf/decisions/decision-scarfgo-profile-switching-via-per-connection
tags: [ios, scarfgo, profiles, decision, issue-120]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesProfileScope.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHTransport.swift, scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift, scarf/Packages/ScarfIOS/Sources/ScarfIOS/ACPClient+iOS.swift]
created: 2026-06-25
updated: 2026-09-26
---

GitHub #120 ("profile switching with ScarfGo"): Alan runs an `admin` profile and a locked-down `gateway` profile; ScarfGo lists them read-only but can't switch/operate against them.

## Observations
- [decision] ScarfGo gets profile switching via **per-connection scoping (Design B)**: the phone points its OWN reads/writes/CLI at `<base>/profiles/<name>` using `remoteHome` (file layer) + `HERMES_HOME`/`-p` (process layer). It does NOT run `hermes profile use` and does NOT mutate the host's `~/.hermes/active_profile`. #decision
- [why] A companion phone should inspect/operate a profile without disrupting the host. Mutating `active_profile` (Design A) changes the profile for the Mac app, terminal, cron daemon, and the running gateway on that host — the exact destructive side-effect that kept switching off-phone (ProfilesView.swift v2.6). #rationale
- [why-not-A] Mac's canonical switch (`ProfilesViewModel.switchAndRelaunch`) RELAUNCHES the whole app to flush in-process state; iOS cannot relaunch cleanly, so A would rely on the in-process refresh Mac deliberately avoids. #rationale
- [mechanism] Verified intended + safe — see [[Hermes profile / HERMES_HOME resolution (source-verified v0.16)]]: `HERMES_HOME` env wins; named-profile env is clobber-proof (main.py early-return); `-p default` defeats a non-default host active_profile for the default case. #mechanism
- [bug-fixed] Reuses `IOSServerConfig.remoteHome` → `paths.home` → all HermesPathSet paths, so dashboard/memory/cron/sessions/gateway/scarf follow the profile. This also fixes a latent half-switch: `HermesProfileResolver` is local-only, so remote direct-file reads currently ignore profiles entirely (static `~/.hermes`) while CLI surfaces honored active_profile. #bug
- [scope] In: switch + scope all read/operate surfaces from the phone. Out: profile create/rename/delete/import/export (stay Mac-only); global `hermes profile use` from phone. #scope
- [delivery] Phased B0–B4 under epic task t-873f7df9; each phase plan→execute→test→fresh-eyes-audit→commit. #delivery
- [mac-port] #126/PR#127 (external, JonLaliberte) ported Design B to the Mac remote window as a per-window "viewing profile" (`WindowProfileScope` + `ServerContext.scoped(toProfile:)` + `ProfileScopedRoot` `.id()` rebuild). Merged 2026-07-13 with our follow-up commit. #macos
- [two-layers-invariant] Design B is TWO layers and both are mandatory: **file** (`remoteHome` → `paths.*`) and **process** (`HERMES_HOME=` prefix on every remote command). PR#127 shipped only the file layer; review caught that Mac `SSHTransport` (unlike iOS `CitadelServerTransport:489`) injected no `HERMES_HOME`, so chat/cron/config CLI ran against the host's `active_profile` while file reads showed the viewing profile — chats landed in the wrong `state.db`. Fixed by `SSHTransport.composedRemoteCommand` (shared by runProcess/makeProcess/streamLines) prepending `HermesProfileScope.hermesHomeShellAssignment` — `""` for root homes. Any future transport or remote-exec path MUST inject this too. #invariant #macos
- [invariant] **The root home is pinned too, by argv (R02, audit S13-F1, 2026-09-26).** `""` for a root home was a bug: Hermes ignores `HERMES_HOME=<root>` (`hermes_cli/main.py:603-605` @ v2026.9.24) and follows the sticky `active_profile`, so a remote window viewing default ran chat/cron/config in the host's active profile. `HermesProfileScope.pinnedRemoteArguments` now puts `-p default` in front of any hermes argv for a root home (skipped for non-hermes executables, argv already starting with `-p`/`--profile`, and bare `--version`/`-V`). Applied in `SSHTransport.composedRemoteCommand`, `CitadelServerTransport.asyncRunProcessImpl`, `ACPClient+iOS.buildACPCommand` and the Mac remote terminal launch (`ChatViewModel.launchTerminal`); callers that run hermes inside `sh -c` add `rootPinShellFragment` to the script text (iOS config set/unset, memory reset, chat preflight, `HermesConfigReader` probes). Local spawns stay unpinned by design (local files follow `active_profile`). Verified on the real CLI at v2026.9.24: only `-p default` returns the root config path. #invariant #profiles

## Relations
- implements [[Hermes profile / HERMES_HOME resolution (source-verified v0.16)]]
- relates_to [[ScarfGo iOS Companion App]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
