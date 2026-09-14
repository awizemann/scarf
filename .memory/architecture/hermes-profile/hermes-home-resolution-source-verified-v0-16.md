---
title: Hermes profile / HERMES_HOME resolution (source-verified v0.16)
type: note
permalink: scarf/architecture/hermes-profile/hermes-home-resolution-source-verified-v0-16
tags: [hermes, profiles, HERMES_HOME, integration, verified]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesProfileResolver.swift]
source_paths_inferred: false
source_sha: 40e8ab1f137314b4c9199b2bf8ce8addbef95980
created: 2026-06-25
updated: 2026-06-25
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

## Relations
- relates_to [[ScarfGo iOS Companion App]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]
- relates_to [[Hermes Integration]]
