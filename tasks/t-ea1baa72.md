---
id: t-ea1baa72
title: v0205 P5: parseProfileList display-name suffix hardening
status: done
added: 2026-08-26
---

## Description

Branch feat/hermes-v0205-parity. Hermes 0.20.5 `profile list` renders profiles as `name (display_name)` via format_profile_label (hermes_cli/profiles.py); Scarf's parseProfileList (ProfilesViewModel.swift:221) would carry the parenthesized suffix into `profile use/show` argv. Installed binary is 0.20.0 so live verification is impossible — derive the exact rendering from the tagged source (fetch/read format_profile_label in a v2026.8.19 checkout at ~/.hermes/hermes-agent, tag already fetched) and harden the parser to strip a trailing " (…)" defensively (profile names themselves cannot contain the rendered suffix — verify Hermes's profile-name validation to confirm stripping is safe). Add parser tests covering old (bare) and new (suffixed) formats. Build + fresh-eye self-audit + commit.

## Plan



## Artifacts



