---
title: Hermes Bot Mode Profile Storage Format
type: note
permalink: scarf/architecture/hermes-bot-mode-profile-storage-format
tags: [hermes, bot-mode, profiles, yaml, wire-format]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesBotIdentity.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesBotProfileYAML.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/BotsService.swift]
source_paths_inferred: false
source_sha: 6f67608679153925b5c6d55816c917ddd76bc3a2
created: 2026-09-01
updated: 2026-09-01
---

On-disk format of a Hermes bot, source-verified at tag v2026.8.31 (0.21.0). A bot IS a profile: no separate store exists. Identity lives in `<profile_dir>/profile.yaml` — top-level `display_name` / `description` / `description_auto` (owned by `hermes profile describe`/`rename`) plus `ui_meta['hermes-bots']` (owned by the desktop plugin). Avatar bytes live at `<profile_dir>/assets/avatar.{png,jpg,webp}`. The roster is the profile roster: root `~/.hermes` as `"default"` plus sorted directories under `<root>/profiles/`.

## Observations
- [fact] Bot-managed detection = `ui_meta['hermes-bots']` is a MAPPING (`tools/bot_mode_probe.py:60-76` `_is_bot_managed`). A bare `hermes-bots:` header loads as None and fails `isinstance(..., dict)` — not a bot; `hermes-bots: {}` is an empty dict — is a bot #detection
- [fact] BotMeta field set (apps/desktop/src/plugins/hermes-bots/types.ts): color, custom, description, groups[], hidden, image, imageKind ('photo'|'shape'), legacy `group` scalar projected alongside groups, pinned, shape, title, created (ms). All optional — three different code paths produce a roster row and older gateways omit whole keys #fields
- [gotcha] `image` is a data URL the desktop STRIPS before `profiles.configure` and ships via `profiles.set_asset` instead, so a real install keeps the avatar in assets/, not the YAML. Scarf deliberately does not model it — a multi-KB base64 scalar is the last value you want a line-oriented writer reformatting #avatars
- [constraint] Two server-side caps Scarf mirrors: `ui_meta` payload rejected over 65536 bytes of json.dumps (methods_profiles.py:789-791, because it rides profiles.list on every roster paint), and an avatar rejected over 2_000_000 bytes (error 4069). Avatar extension probe order is png, jpg, webp — the gateway's own dict order #caps
- [gotcha] Hermes' own `write_profile_meta` (hermes_cli/profiles.py:951-991) round-trips profile.yaml through yaml.safe_load + atomic_yaml_write(sort_keys=False): unspecified top-level keys survive but every COMMENT is destroyed. Scarf's surgical line writer is strictly more conservative — it preserves comments, key order, and blank lines outside the three regions it edits #preservation

## Relations
- relates_to [[Bot Mode Phase A Decisions]]
- relates_to [[Hermes v0.21.0 Audit Findings]]
