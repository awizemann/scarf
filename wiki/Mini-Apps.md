---
title: Mini-Apps
type: note
permalink: scarf-wiki/mini-apps
created: 2026-06-28
updated: 2026-06-28
---

# Mini-Apps

_Sandboxed web panels that live inside a project and can drive its agent._ (Scarf v2.15+, Mac)

A **mini-app** is a small web UI — plain HTML/CSS/JS — that Scarf renders in a slide-in panel inside a project's [cockpit](Projects-&-Profiles). Unlike a static dashboard widget, a mini-app is interactive and can talk to the project's Hermes agent and read project data, through a tiny, versioned JavaScript bridge called `window.scarf`. They're ideal for custom dashboards, approval queues, task boards, charts, or any tailored panel you wish a project had.

Mini-apps are designed to run **untrusted code safely** — including code the agent itself wrote. Two mechanisms make that possible: a locked-down browser sandbox, and a default-deny permission model you review the first time you open each one.

## Where mini-apps live

Each project's mini-apps live under its repo:

```
<project>/.scarf/miniapps/<id>/
├── miniapp.json     ← the manifest (identity + declared permissions)
├── index.html       ← entry document
├── state.json       ← per-mini-app key-value store (auto-created)
└── …                ← any local CSS / JS / images
```

Scarf discovers them automatically — there's no install step. Every directory under `.scarf/miniapps/` with a parseable `miniapp.json` shows up in the cockpit's **Mini-apps** panel, sorted by id. Because they live in the repo, mini-apps travel with the project (and across your [fleet](Fleet-&-Portfolio)).

## Opening a mini-app — the permission sheet

Select a project → open its cockpit → **Mini-apps** panel → **Open**. Agent-generated mini-apps are flagged with a wand icon; hand-authored ones get a grid icon.

The **first** time you open a mini-app, Scarf shows a **permission sheet** — this is the trust boundary. It lists every capability the mini-app declares:

- **Non-sensitive** surfaces (read-only project data) are pre-checked.
- **Sensitive** surfaces (sending the agent prompts, reading files, querying non-allowlisted data) are flagged — and for **agent-generated** mini-apps they're **pre-unchecked**. You opt in deliberately.
- **Unknown** permissions (anything Scarf doesn't recognize) are shown greyed-out and can never be granted.

You toggle what you'll allow and click **Approve & Run**. Your decision is saved per `(project, mini-app)` to `~/.hermes/scarf/miniapp_grants.json`, so you're not re-asked every time. Re-open the permission sheet later to change grants — narrowing them **live-revokes** access (Scarf recreates the web view with the new, smaller permission set; in-flight bridge calls on the old view are dropped).

> **Default-deny is the baseline.** A mini-app with no granted permissions can still show its UI and call the ungated surfaces (`context`, `ui.*`), but every data or agent surface stays closed until you approve it.

## The `window.scarf` bridge

Mini-app code talks to Scarf through `window.scarf`, injected at document start. Every async call returns a Promise that **rejects with `permission_denied`** if the required permission isn't granted.

| Surface | Permission | What it does |
|---|---|---|
| `scarf.version` | — (ungated) | Bridge semver string (`"1.0"`) |
| `scarf.context` | — (ungated) | Frozen `{ bridgeVersion, projectId, projectName, projectRoot, serverId, miniAppId, generated }` |
| `scarf.ui.toast(msg)` | — (ungated) | Show a host toast |
| `scarf.ui.setTitle(t)` | — (ungated) | Set the panel title |
| `scarf.ui.resize(w?, h?)` | — (ungated) | Layout hint to the host (advisory) |
| `scarf.ui.requestClose()` | — (ungated) | Ask the host to close the panel |
| `scarf.store.get(key)` / `scarf.store.set(key, value)` | `store` | Per-mini-app persistent key-value (JSON) |
| `scarf.query(kind, params?)` | `query:<kind>` | Read whitelisted data; `kanban.tasks` is the wired kind |
| `scarf.kanban.read()` | `query:kanban.tasks` | Convenience for the project's Kanban tasks |
| `scarf.file.read(path)` | `file:read` | Read a UTF-8 file at a **relative** path under the project root (≤ 4 MB, symlink-contained) |
| `scarf.prompt(text, opts?)` | `prompt` | Send a prompt to the mini-app's agent session; resolves with the full reply |
| `scarf.onEvent(cb)` | `events` | Subscribe to the agent session's streamed output |

## Driving the agent

When a mini-app calls `scarf.prompt(...)`, Scarf spawns it a **dedicated `hermes acp` session** — lazily, on first use, torn down when the panel closes. This session is **isolated from your chats**: a mini-app can't reach into other conversations or other projects.

- **`scarf.prompt(text)`** resolves with the agent's full reply, accumulated from the streamed chunks. One prompt is allowed in flight at a time (a second returns `busy`).
- **`scarf.onEvent(cb)`** streams the session's events as they arrive — `message` (text chunk), `thought`, `tool` / `tool_update`, and `complete` (turn end). Use it to render live agent output.
- **Rate limit:** a sliding window of **8 prompts per 60 seconds** caps runaway loops (e.g., a buggy generated mini-app). The 9th is rejected with `rateLimited` before it reaches Hermes.
- **Unsupervised, so tool permissions are auto-denied.** Because no human is watching a mini-app's agent turn-by-turn, any tool-permission request the agent raises mid-turn is automatically cancelled. In v1, a mini-app's agent can run reasoning and produce text but cannot perform permissioned tool actions.
- **No project context files.** Unlike a project [chat](Chat), a mini-app's agent session deliberately does **not** load the project's `AGENTS.md` / `CLAUDE.md` / `.cursorrules` — the web content driving it is less trusted than a chat you opened yourself.

## The sandbox

Every mini-app runs in a hardened `WKWebView`:

- **No persistent storage** — a non-persistent data store means no cookies or `localStorage` bleed across mini-apps or projects.
- **Scoped assets** — files are served only through a `scarf-miniapp://` scheme handler rooted at the mini-app's own directory. Navigation to any other scheme (`file://`, `http(s)://`) is blocked.
- **No network** — a strict Content-Security-Policy (`default-src 'none'; connect-src 'none'`) blocks all outbound requests. A mini-app is **entirely self-contained**: no `fetch()` to the internet, no external scripts or CDNs.
- **Contained file reads** — `scarf.file.read` and asset requests resolve through symlink-containment: `..` escapes are rejected and both the directory and the resolved file are symlink-resolved and re-checked to be inside the mini-app dir. A planted symlink can't read its way out to, say, `~/.hermes/`.
- **Version-gated** — the manifest's `minBridgeVersion` is checked at launch; a mini-app that needs a newer bridge than the running Scarf is refused with an "update Scarf" message rather than running degraded.

## Building a mini-app

Ask the agent — the bundled **`scarf-miniapp-author`** skill scaffolds the manifest, directory, and a working starter, and knows the full bridge contract. Or run **Upgrade Project** (see [Projects & Profiles](Projects-&-Profiles)), which has the agent build one or two starter mini-apps tailored to your project as part of enrichment.

A minimal manifest:

```json
{
  "id": "task-board",
  "name": "Task Board",
  "version": "1.0.0",
  "entry": "index.html",
  "minBridgeVersion": "1.0",
  "permissions": ["query:kanban.tasks", "store"],
  "generated": true
}
```

Manifest fields: `id` (kebab-case, must match the directory), `name` (shown in the cockpit), `version`, `entry` (default `index.html`), `minBridgeVersion` (default `1.0`), `permissions` (default `[]` = nothing beyond the ungated baseline), `panelHint` (optional layout metadata), and `generated` (`true` for agent-authored apps → sensitive permissions default OFF in the preview sheet). Prefer the **fewest, least-sensitive** permissions a mini-app needs — non-sensitive ones (`events`, `file:read`, `store`, `query:kanban.tasks`) run immediately without a sensitive-permission prompt.

## v1 scope and limitations

This release wires the **read + prompt** surfaces. A few declared permissions are intentionally not yet enabled:

- **`kanban:write`** (create/move tasks) and **`file:write`** (write files) — declared in the permission model and gated, but no handler yet. They'll arrive in a later release.
- **`net`** (outbound HTTP) — declared, but the CSP blocks all network regardless until an allowlist ships.
- **`query` kinds** — only `kanban.tasks` is implemented; other kinds reply `not_implemented`.
- **Agent tool actions** — auto-denied (see above).

## Related

- [Projects & Profiles](Projects-&-Profiles) — the cockpit, Upgrade Project, first-class project object
- [Fleet & Portfolio](Fleet-&-Portfolio) — your project across multiple machines
- [Chat](Chat) — project chats and how they load `AGENTS.md` (and why mini-apps don't)
- [Project Templates](Project-Templates) — `.scarftemplate` bundles can ship hand-authored mini-apps
