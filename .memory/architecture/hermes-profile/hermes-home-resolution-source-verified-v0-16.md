---
title: Hermes profile / HERMES_HOME resolution (source-verified v0.16)
type: note
permalink: scarf/architecture/hermes-profile/hermes-home-resolution-source-verified-v0-16
tags: [hermes, profiles, HERMES_HOME, integration, verified]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesProfileResolver.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesProfileScope.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesProfileList.swift]
source_paths_inferred: false
source_sha: 40e8ab1f137314b4c9199b2bf8ce8addbef95980
created: 2026-06-25
updated: 2026-09-27
reviewed: 2026-09-11
reviewed_by: claude-opus-5
---

Source-verified against the installed editable Hermes 0.16 at `~/.hermes/hermes-agent/` (2026-06-25). Durable reference for any Scarf profile work — especially ScarfGo per-connection profile scoping ([[ScarfGo iOS Companion App]]).

## Observations
- [model] A Hermes profile is a fully independent `HERMES_HOME` directory. Default profile = the root home itself (`~/.hermes`); named profiles live at `<root>/profiles/<name>/` with their own state.db, sessions/, config.yaml, .env, memories/, cron/, gateway_state.json. #profiles
- [resolution] `hermes_constants.get_hermes_home()` precedence: (1) in-process ContextVar override, (2) **`HERMES_HOME` env var (wins)**, (3) platform default `~/.hermes`. It does NOT itself consult `active_profile` — it only logs a one-shot stderr warning if `active_profile` is non-default while `HERMES_HOME` is unset (the "wrong profile" guard). #resolution
- [intended] Hermes' own docstring: "subprocess spawners are expected to propagate `HERMES_HOME` explicitly." Setting `HERMES_HOME=<root>/profiles/<name>` is the intended, first-class way to target a profile WITHOUT mutating `active_profile`. #intended
- [cli-entry] `hermes` CLI runs `hermes_cli/main.py:_apply_profile_override()` at import. It is what makes `active_profile` "sticky" for bare `hermes` invocations: reads `<root>/active_profile` and sets `os.environ["HERMES_HOME"]`. #cli
- [clobber-proof] main.py step 1.5 (≈L419-422): if `HERMES_HOME` is ALREADY set and points at a `profiles/<name>` dir (immediate parent dir named `profiles`), it returns early and NEVER reads `active_profile`. So an explicitly-injected named-profile `HERMES_HOME` is safe from being overridden. #clobber
- [default-edge] If injected `HERMES_HOME` is the ROOT (default profile, parent not named `profiles`), main.py falls THROUGH to `active_profile` — so a non-default host `active_profile` would override a "default" selection. Defeat this with the explicit flag. #edge
- [flag] `-p` / `--profile <name>` (and `--profile=<name>`) forces a profile regardless of `active_profile`, incl. `-p default` which resolves to the root home. Parser scans broadly (works before or after the subcommand). This is the robust lever for `hermes -p <name> acp` and scoped CLI. #flag
- [root-discovery] `get_default_hermes_root()` returns the root even when `HERMES_HOME` is a profile path (parent named `profiles` → grandparent), so `hermes profile list` sees all profiles regardless of the active scope. #root
- [name-rule] Profile id regex (Hermes): `^[a-z0-9][a-z0-9_-]{0,63}$`. Mirror it before building any profile path (path-injection safety). #validation

- [verified] Re-verified at v2026.9.24 (0.21.5) on the real CLI with a scratch HOME and `active_profile=research`: plain `hermes config path` and `HERMES_HOME=<root> hermes config path` both return the research profile's config; only `hermes -p default config path` returns the root's. `-p default` → root has held since profiles shipped (v2026.3.30, 0.6.0, `get_profile_dir("default")`). Caveat: before v2026.4.13 the default root was hard-coded `~/.hermes`, so on 0.6–0.8 Docker hosts with a custom root `-p default` pointed at `~/.hermes`; Scarf's remote root pin accepts this gap ungated (orchestrator decision, R02 2026-09-26). Test with the venv's `hermes` console script, NOT `python -m hermes_cli.main`: the latter imports the module twice and the second `_apply_profile_override` (flag already stripped) re-reads `active_profile`. #verified #gotcha
- [decision] Custom remote ROOT homes (anything but `~/.hermes`/`$HOME/.hermes`, e.g. `/home/hermes/.hermes`, `/opt/data`) get `HERMES_HOME=<root>` AND `-p default` (R18c, T6-F1): `-p default` resolves to `profile_root_for_env_home($HERMES_HOME)` (`hermes_cli/profiles.py:2345-2369` @ v2026.9.24), so without the assignment it fell back to the SSH user's own `~/.hermes` and CLI/ACP ran on a different home than the file views. Verified with the reference venv + scratch HOME: `HERMES_HOME=<custom> hermes -p default config path` → `<custom>/config.yaml`; `HERMES_HOME=<custom>` without the flag still follows `<custom>/active_profile`. `~/.hermes` still gets no assignment so hosts exporting their own HERMES_HOME (Nix/Docker) keep it. Side effect: `gateway install/status` for a custom root now uses Hermes's hashed per-home service name. `HermesProfileScope.hermesHomeShellAssignment` / `needsHomeAssignment`. #transport #profiles
- [gotcha] `hermes profile list`'s `◆` marker is `get_active_profile_name()`, derived from the PROCESS's `HERMES_HOME` (`profiles.py:1941-1955`), not the sticky file. Any pinned run (`-p x` or a profile `HERMES_HOME`) marks the pinned profile. To show the server's active profile from a pinned context, read `<root>/active_profile` (missing/empty = default). #gotcha #profiles


## Relations
- relates_to [[ScarfGo iOS Companion App]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
- relates_to [[Hermes Integration]]
