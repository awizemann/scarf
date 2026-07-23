---
title: Hermes-Paths
type: note
permalink: scarf-wiki/hermes-paths
created: 2026-05-29
updated: 2026-05-29
---

# Hermes Paths

Canonical layout of `~/.hermes/`. Scarf reads these paths through [`HermesPathSet`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesPathSet.swift) in the ScarfCore package — same path resolution on Mac and iOS. Updates here should mirror to the **Key Paths** block in `scarf/CLAUDE.md`.

## Hermes-owned paths

| Path | What lives here | Scarf access |
|---|---|---|
| `~/.hermes/` | Hermes home | read-only base |
| `~/.hermes/state.db` | SQLite (WAL mode) — sessions, messages, activity, costs | **read-only**, never written |
| `~/.hermes/config.yaml` | Hermes runtime config (platforms, models, LLM settings, ~60 fields) | read + write (Mac Settings; iOS Quick Edits via `hermes config set`) |
| `~/.hermes/.env` | Secrets and env vars referenced by `config.yaml` | read + write (preserves comments + blanks) |
| `~/.hermes/auth.json` | Auth tokens (Nous Portal subscription, Spotify OAuth, other provider tokens) | read-only — Hermes owns the write path |
| `~/.hermes/SOUL.md` | Top-level personality | read + write |
| `~/.hermes/memories/MEMORY.md` | Hermes's project/topic memory | read + write |
| `~/.hermes/memories/USER.md` | Hermes's user memory | read + write |
| `~/.hermes/sessions/session_*.json` | Session metadata files | read-only |
| `~/.hermes/cron/jobs.json` | Scheduled job definitions | read + write |
| `~/.hermes/cron/output/` | Cron job output captures | read-only |
| `~/.hermes/logs/agent.log` | Agent log (per-session tagged) | read-only, tail |
| `~/.hermes/logs/errors.log` | Error log | read-only, tail |
| `~/.hermes/logs/gateway.log` | Messaging-gateway log | read-only, tail |
| `~/.hermes/gateway_state.json` | Gateway live state (PID, connected platforms) | read-only |
| `~/.hermes/skills/` | Installed skills (with v0.11 SKILL.md frontmatter) | read + write (install/update/uninstall) |
| `~/.hermes/plugins/` | Installed plugins (cloned from Git URLs) | read + write |
| `~/.hermes/personalities/` | Personalities + their `SOUL.md` | read + write |
| `~/.hermes/profiles/<name>/` | Isolated Hermes instances (Hermes v0.11+) — each profile carries its own `state.db`, `sessions/`, `config.yaml`, `.env`, `memories/`, `cron/`, etc. | read + write |
| `~/.hermes/active_profile` | Single-line text file holding the active profile name (or absent / empty for default). _v2.5.1+:_ Scarf reads this via [`HermesProfileResolver`](Core-Services) and routes every derived path under it, so `hermes profile use coder` followed by a Scarf relaunch correctly reads the new profile's data. | read-only |
| `~/.hermes/mcp-tokens/*.json` | Per-server MCP OAuth tokens | read (detect) + delete (clear) |

## Scarf-owned paths under `~/.hermes/scarf/`

These are written by Scarf, never by Hermes. Both clients (Mac + iOS) read and write the same files so attribution and project context survive across platforms.

| Path | What lives here | Notes |
|---|---|---|
| `~/.hermes/scarf/projects.json` | Project registry — every directory you've registered as a Scarf project | Mac authors via Projects sidebar; iOS reads via SFTP. |
| `~/.hermes/scarf/session_project_map.json` | Attribution sidecar — maps Hermes session IDs to project paths | Written when project-scoped chat starts. Drives the project-filter UI on both Mac global Sessions and ScarfGo Dashboard. |
| `<project>/.scarf/dashboard.json` | Per-project dashboard JSON | Lives inside the project, not under `~/.hermes/`. |
| `<project>/.scarf/template.lock.json` | `.scarftemplate` install manifest (when a project was installed from a template) | Drives clean uninstall. |
| `<project>/.scarf/manifest.json` | Cached `template.json` for templates with a config schema | Drives the post-install Configuration sheet. |
| `<project>/.scarf/config.json` | Non-secret configuration values | Secrets are `keychain://...` URIs; resolved at use time. |
| `<project>/.scarf/slash-commands/<name>.md` _(v2.5+)_ | Project-scoped slash commands | See [Slash Commands](Slash-Commands). |
| `~/.hermes/scarf/nous_models_cache.json` _(v2.5.2+)_ | Cached Nous Portal model list (24h TTL) | Populated by `NousModelCatalogService` from `GET /v1/models`. Survives offline so the picker still has a model list to render. |
| `<project>/AGENTS.md` (between `<!-- scarf-project:begin -->` markers) | Auto-managed project context block | Idempotent, secret-safe. See [Projects & Profiles](Projects-and-Profiles). |

## ACP

Chat does not go through the filesystem. It is a subprocess: `hermes acp` (local) or `ssh -T host -- hermes acp` (remote), with JSON-RPC over stdio. See [ACP Subprocess](ACP-Subprocess).

## Mac-side caches

| Path | What lives here |
|---|---|
| `~/Library/Caches/scarf/snapshots/<server-id>/` | Atomic `state.db` snapshots pulled from remote servers via `sqlite3 .backup` |
| `~/Library/Application Support/com.scarf/skill-snapshots/<serverID>.json` | Per-server skill snapshot for the v2.5 "What's New" pill |
| `/tmp/scarf-ssh-<uid>/` | SSH ControlMaster sockets (per-host `%C` hash). Mode 0700; per-uid suffix isolates between local users. Lives under `/tmp` to stay within macOS' 104-byte Unix domain socket path limit. |
| `~/Library/Preferences/com.scarf.app.plist` | App preferences + the server registry |

## iOS-side (ScarfGo) state

ScarfGo can't write to `~/Library/Caches/scarf/...` — it lives in its own iOS app sandbox. Equivalent paths:

| What | Where |
|---|---|
| SQLite snapshots | iOS Caches dir → `<sandbox>/Library/Caches/scarf/snapshots/<server-id>/state.db` |
| Skill snapshots ("What's New" pill) | `UserDefaults` (the iOS sandbox doesn't have a clean Application Support equivalent for tiny per-server JSON) |
| Server registry (multi-server) | `UserDefaults` key `com.scarf.ios.servers.v2` (auto-migrated from legacy `ScarfGo.servers.v1`) |
| SSH private keys | iOS Keychain — service `com.scarf.ssh-key`, account `server-key:<UUID>`. Default accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + `kSecAttrSynchronizable=false` (device-local). _v2.5.1+:_ opt-in System → Security toggle flips writes to `kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable=true` so the key syncs to iCloud Keychain across the user's signed-in Apple devices. Off by default. |
| Template config secrets | iOS Keychain — service `com.scarf.template.<slug>`, account `<fieldKey>:<project-path-hash>` |

## Log line format

Hermes log lines may carry an optional `[session_id]` tag between the level and the logger name. `HermesLogService.parseLine` treats the session tag as an optional capture group, so older untagged lines still parse correctly.

---
_Last updated: 2026-04-29 — Scarf v2.5.2 (Nous live catalog cache path)_