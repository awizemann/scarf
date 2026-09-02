---
title: Hermes Bot Mode Profile Storage Format
type: note
permalink: scarf/architecture/hermes-bot-mode-profile-storage-format
tags: [hermes, bot-mode, profiles, yaml, wire-format]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesBotIdentity.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesBotProfileYAML.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/BotsService.swift]
source_paths_inferred: false
source_sha: 466bb7f11b7652ac99876183d0968269cddcac38
created: 2026-09-01
updated: 2026-09-01
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

On-disk format of a Hermes bot, source-verified at tag v2026.8.31 (0.21.0). A bot IS a profile: no separate store exists. Identity lives in `<profile_dir>/profile.yaml` — top-level `display_name` / `description` / `description_auto` (owned by `hermes profile describe`/`rename`) plus `ui_meta['hermes-bots']` (owned by the desktop plugin). Avatar bytes live at `<profile_dir>/assets/avatar.{png,jpg,webp}`. The roster is the profile roster: root `~/.hermes` as `"default"` plus sorted directories under `<root>/profiles/`.

## Observations
- [fact] Bot is a profile with no separate storage; identity lives in profile.yaml containing display_name, description, description_auto, and ui_meta['hermes-bots'] #bot-identity
- [fact] Avatar bytes stored at <profile_dir>/assets/avatar.{png,jpg,webp}; extension detection order is png, jpg, webp; server-side cap 2MB #avatar-storage
- [fact] Roster structure: root ~/.hermes as 'default' plus sorted directories under <root>/profiles/ #roster-structure
- [fact] Agent config is per-profile only—config.yaml, .env, SOUL.md, and skills/ have no root-level inheritance #agent-config-scope
- [fact] Capability fingerprint enumerated by Hermes includes disabled skills, toolsets, mcp_servers, SOUL.md bytes, installed skill names, and roster #fingerprint-composition


## Agent-configuration files (Phase B, same tag)

A bot's *agent* configuration lives beside its identity in the same profile directory, and is per-profile with no root inheritance:

- `<profile_dir>/config.yaml` — the ONLY user layer Hermes merges for that profile (`_load_config_impl`, `hermes_cli/config.py:3936-4080`: `DEFAULT_CONFIG` → this file → the managed `/etc/hermes` overlay). Keys Scarf models: `model.default`, `model.provider`, `model.base_url`, `skills.disabled` (list), `platform_toolsets.<platform>` (list, written by `hermes tools enable|disable --platform`), `mcp_servers.<name>.enabled` (scalar, absent ⇒ true).
- `<profile_dir>/.env` — seeded empty at `create_profile`; `hermes config set` diverts credential-shaped keys here (`_is_env_config_key`), so those never read back out of `config.yaml`.
- `<profile_dir>/SOUL.md` — the agent's identity prompt, system-prompt slot #1 (`agent/prompt_builder.py:2215`) and part of a bot's capability fingerprint (`tools/bot_mode_probe.py:359`). No per-bot SOUL location other than the profile home.
- `<profile_dir>/skills/` — copied from the source at creation, independent thereafter.

`capability_fingerprint` (`tools/bot_mode_probe.py:320-380`) is Hermes' own enumeration of a bot's capability surface, and it is exactly this set: disabled skills + toolsets + `mcp_servers` + `SOUL.md` bytes + installed skill names + the roster.

- [fact] Bot-managed detection = `ui_meta['hermes-bots']` is a MAPPING (`tools/bot_mode_probe.py:60-76` `_is_bot_managed`). A bare `hermes-bots:` header loads as None and fails `isinstance(..., dict)` — not a bot; `hermes-bots: {}` is an empty dict — is a bot #detection
- [fact] BotMeta field set (apps/desktop/src/plugins/hermes-bots/types.ts): color, custom, description, groups[], hidden, image, imageKind ('photo'|'shape'), legacy `group` scalar projected alongside groups, pinned, shape, title, created (ms). All optional — three different code paths produce a roster row and older gateways omit whole keys #fields
- [gotcha] `image` is a data URL the desktop STRIPS before `profiles.configure` and ships via `profiles.set_asset` instead, so a real install keeps the avatar in assets/, not the YAML. Scarf deliberately does not model it — a multi-KB base64 scalar is the last value you want a line-oriented writer reformatting #avatars
- [constraint] Two server-side caps Scarf mirrors: `ui_meta` payload rejected over 65536 bytes of json.dumps (methods_profiles.py:789-791, because it rides profiles.list on every roster paint), and an avatar rejected over 2_000_000 bytes (error 4069). Avatar extension probe order is png, jpg, webp — the gateway's own dict order #caps
- [gotcha] Hermes' own `write_profile_meta` (hermes_cli/profiles.py:951-991) round-trips profile.yaml through yaml.safe_load + atomic_yaml_write(sort_keys=False): unspecified top-level keys survive but every COMMENT is destroyed. Scarf's surgical line writer is strictly more conservative — it preserves comments, key order, and blank lines outside the three regions it edits #preservation
- [fact] A profile's AGENT config is per-profile with NO root inheritance: `<profile_dir>/config.yaml` is the only user layer Hermes merges for it (`config.py:3936-4080`), alongside `<profile_dir>/.env`, `<profile_dir>/SOUL.md` and `<profile_dir>/skills/`. Hermes' own `capability_fingerprint` (`tools/bot_mode_probe.py:320-380`) enumerates exactly that set #agent-config #phase-b

## Relations
- relates_to [[Bot Mode Phase A Decisions]]
- relates_to [[Hermes v0.21.0 Audit Findings]]
