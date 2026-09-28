---
id: t-6d767ade
title: B05 Gateway & platforms: Slack, WhatsApp, restart drain, Mattermost, iMessage, Spotify, defaults, webhooks
status: done
added: 2026-09-27
priority: high
---

## Description

Wave 2. Findings: S07-F1…F8. Spotify (F6) per Alan: add a Client ID field so first-time local sign-in completes; on remote show the exact host command. Plan: documents/plans/hermes-v0215-blind-reaudit-remediation-plan.md.

## Plan

B05 plan (worktree Scarf-wt/b05, branch fix/hermes-v0215-blind-b05)
- F1 Slack reply_to_mode: re-verified no Slack reader @v2026.9.24 (only discord/telegram/buzz read _reply_to_mode). Remove the picker + write from SlackSetupViewModel/View and the iOS read-only "Slack: reply mode" row. Tests: save plan no longer carries the key.
- F2 WhatsApp reply_prefix: write only when non-blank or the key was present on load (presence via raw config text); caption explains blank = Hermes default header; "Use Hermes default" = `config unset` gated on hasConfigUnset. Tests: save-plan cases.
- F3 gateway restart drain: verdict recognises the launchd/systemd/supervised drain announcement on a timed-out restart -> .unconfirmed "waiting for the current turn" note; new ScarfCore parser (announcement PID+budget) + gateway_state.json drain phase (active_work, pid change). Gateway pane + Platforms restart watch progress off-main with a Stop waiting control, bounded by Hermes's budget. MCP pane gets honest note. Tests: verdict arms, parser, phase.
- F4 Mattermost require_mention: on >=0.21.3 (v2026.9.14 flip, extra_or_secret) a non-blank MATTERMOST_REQUIRE_MENTION wins on load; save writes config and unsets the .env line so both old/new hosts agree. Tests.
- F5 BlueBubbles read receipts: absent -> true, save writes explicit true/false. Tests.
- F6 Spotify: local = Client ID field when none known (.env HERMES_SPOTIFY_CLIENT_ID/SPOTIFY_CLIENT_ID or auth.json providers.spotify.client_id), pass --client-id (argv verified at 4.30+); remote = show exact ssh -L 43827 ... hermes auth spotify command (copy/open Terminal) instead of sign-in. Tests: argv + command builder.
- F7: Feishu default "feishu", WhatsApp mode default "self-chat".
- F8: Mac webhook list uses HermesWebhookList.listing + exit code; error state instead of empty.
Blast radius: Mac platform forms, Gateway/Platforms/MCP restart callers, iOS settings row, Plugins/Skills Spotify sheet. Memory: hermes-v0-21-1 decisions (Slack reply_to_mode, Mattermost precedence), wiki Gateway page, platform notes.

## Artifacts

Merged into fix/hermes-v0215-blind as 0438a013 (tree = audited 3b7ccd53 state; follow-up reverted per Alan's scope rule). ScarfCore builds after merge. App-hosted suites deferred to B10. Env-first platform-form list logged in plan for Alan's decision.

