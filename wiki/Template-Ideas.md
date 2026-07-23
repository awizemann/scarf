---
title: Template-Ideas
type: note
permalink: scarf-wiki/template-ideas
created: 2026-05-29
updated: 2026-05-29
---

# Template Ideas

We track candidate `.scarftemplate` ideas here. Each Scarf release cycle we ship one official template from this list as part of the pre-release dogfooding pass — see [Test Harness](Test-Harness) for how that works in practice. Once shipped, templates surface in the in-app [Template Catalog](Template-Catalog).

If you have an idea, [open an issue](https://github.com/awizemann/scarf/issues/new) or jump straight into [`templates/CONTRIBUTING.md`](https://github.com/awizemann/scarf/blob/main/templates/CONTRIBUTING.md). Community templates are merged via PR after `tools/build-catalog.py --check` passes.

## Status legend

- 🟢 **Shipped** — published in the catalog at [awizemann.github.io/scarf/templates/](https://awizemann.github.io/scarf/templates/).
- 🟡 **In progress** — being built this release cycle.
- ⚪ **Idea** — fits today's primitives (config + cron + dashboard + optional webview-to-public-URL).
- 🔵 **Blocked** — needs a core Scarf feature that doesn't exist yet (uploads, local server, OAuth provider plug-in, …).

## Shipped

| Template | Author | Version | Highlights |
|----------|--------|---------|------------|
| 🟢 [Site Status Checker](https://awizemann.github.io/scarf/templates/awizemann/site-status-checker/) | awizemann | 1.1.0 | Configurable URL list, daily uptime check, Site tab webview |
| 🟢 [Template Author](https://awizemann.github.io/scarf/templates/awizemann/template-author/) | awizemann | 1.0.0 | Meta-template — scaffolds new Scarf templates conversationally |
| 🟡 [HackerNews Daily Digest](https://github.com/awizemann/scarf/tree/dogfooding-templates/templates/awizemann/hackernews-digest) | awizemann | 1.0.0 | First template built under the dogfooding-templates pass — no secrets, public Firebase API |

## Backlog

All entries below fit today's capabilities (config + cron + dashboard, no uploads, no local server). The "Secrets" column flags whether the template needs a Keychain-backed config field. Templates with no secrets are easier first builds because the test harness doesn't need to fake-Keychain anything.

| # | Idea | Category | Secrets | Notes |
|---|------|----------|---------|-------|
| 1 | GitHub Repo Health Tracker | dev | GitHub PAT | Open issues / stale PRs / last-release-age across a list of repos. High dogfood value — every Hermes user has GitHub repos. |
| 2 | Crypto / Stock Portfolio | finance | optional API key | List of holdings → live price + P/L. Showcases the `chart` widget (value over time, persisted to a status log). |
| 3 | RSS / Newsletter Watcher | news | none | List of feed URLs → new-since-last-check → digest. Builds on Hermes's good summarization. |
| 4 | Domain + TLS Cert Expiry | ops | none | `whois` + `openssl s_client` per domain → days-till-expiry stats. Pure shell, exercises Hermes's shell-tool. |
| 5 | Local Disk + Folder Health | ops | none | Watch path sizes / disk free / largest-files-changed. All local I/O. Useful for the dev mac. |
| 6 | Weather + AQI Board | personal | none | List of `(label, lat, lon)` → daily forecast + air quality via open-meteo / openaq. |
| 7 | Spotify Listening Stats | personal | OAuth via Hermes | Reuses `hermes auth spotify` (added in v0.11). Recently-played + top-tracks digest. Tokens never leave Hermes. |
| 8 | CI Status Board | dev | GitHub PAT | GitHub Actions runs across configured repos. Failure-focused; chart of failure rate over time. |
| 9 | Obsidian Vault Stats | personal | none | Note count, daily-note streak, tag distribution from a configured vault path. Filesystem-only. |

## v3 Epic — Project Site as Living Surface

🔵 **Blocked on core features.** The eBay Listings Manager idea (drop photos + condition notes → agent prices via eBay's APIs → drafts a listing the user reviews + publishes from Scarf) is the motivating use case for a broader v3 capability: **make project sites two-way.** Today's `webview` widget renders a single URL; v3 turns it into an interactive surface backed by a per-project loopback HTTP server.

### Components

| Component | Description |
|-----------|-------------|
| **Per-project loopback HTTP server** | New `ProjectSiteServer` service wraps `Network.NWListener`, binds 127.0.0.1 on a random port written into `<projectDir>/.scarf/site.runtime.json` (gitignored). One process-wide instance multiplexes by project ID. Dies on app quit. |
| **Bearer-auth + CSP** | Server requires `Authorization: Bearer <token>` on every request; token generated at first project open, stored in Keychain (`com.scarf.project.<slug>:site-token`), injected into the served page via a templated header. Default CSP forbids any non-loopback origin. |
| **Static + dynamic routes** | `GET /<path>` serves files from `<projectDir>/site/`; `POST /api/<endpoint>` is dispatched to handlers the template registers in `template.json` under a new `site.endpoints[]` block: `{path, method, handler: "append-json-line" \| "save-upload" \| "trigger-hermes-prompt"}`. v3 starts with these three handlers — no arbitrary code execution. |
| **Upload handler** | `multipart/form-data` parsed; files land at `<projectDir>/uploads/<uuid>/<original-name>`; manifest entry appended to `<projectDir>/uploads/index.json`. |
| **Trigger handler** | Posts a JSON-RPC message to Hermes via the existing webhook gateway, with a templated prompt + the upload UUID. The agent picks up the work and writes back to the dashboard. Reuses Hermes's existing webhook infra rather than inventing a new IPC channel. |
| **OAuth provider plug-in** | Generalizes the existing `SpotifyAuthFlow` shape: a template can declare `auth.providers: ["ebay"]`, and Scarf renders a "Connect eBay" button that runs `hermes auth ebay` (Hermes side adds the provider). Tokens never leave Hermes; the template addresses the connection by provider name only. |
| **Webview ↔ server bridge** | The existing `webview` widget gains a `siteRoot: true` option that points at the loopback server instead of an external URL. Page can call `fetch('/api/...')` because same-origin to the bound port. |
| **Manifest changes** | `template.json` `schemaVersion` bumps to **4** (gated; pre-v4 hosts refuse to install). New `site` and `auth` blocks. `tools/build-catalog.py` mirrors the new schema. |

### Risks

Serving HTML in a per-project sandbox, processing user uploads, and holding OAuth tokens are each independent security boundaries. The epic explicitly calls out:

- **Threat-model review** before merge. Loopback only is necessary but not sufficient — local CORS, malicious tabs in the user's browser, and other co-resident processes are all attack surfaces.
- **Feature flag** in `config.yaml` (`scarf.experimental.project-site-server: true`). Off by default; users opt in.
- **No arbitrary handlers in v3.** The three named handlers (`append-json-line`, `save-upload`, `trigger-hermes-prompt`) cover ~90% of legitimate use cases without giving templates a code-execution channel.

### Canonical use case: eBay Listings Manager

User flow once v3 ships:

1. Drop a photo into the Site tab. The template's HTML form `POST`s to `/api/uploads`; `save-upload` handler stores it under `<projectDir>/uploads/`.
2. Add a one-line condition / notes field; `POST /api/items` adds an entry to `<projectDir>/items/<uuid>.json` via `append-json-line`.
3. The form's "Suggest pricing" button hits `POST /api/research` which `trigger-hermes-prompt` translates into a Hermes prompt: *"For the item described in `<projectDir>/items/<uuid>.json`, fetch comparable completed-listing prices from eBay's Browse API and write a price recommendation back to the item file."* The agent runs, writes the result, dashboard refreshes.
4. User reviews price + photos in the Site tab; clicks "Create draft listing." Another `trigger-hermes-prompt` calls eBay's Trading API `AddItem` with `DraftFlag=true`, capturing the draft ID.
5. Listing tracking: a daily cron polls `GetMyeBaySelling` for status + `GetMessages` for buyer questions, populating dashboard widgets (chart of sell-through rate, list of buyer messages).

### Out of v3 scope

Even with the epic done:

- Arbitrary JS execution in the served page (handlers are named + bounded).
- Cross-project navigation (each project's loopback server is sandboxed to its own dir).
- Served pages reading other projects' data.
- Anything that talks to non-loopback addresses.
- Auto-publishing listings without user confirmation (drafts only; user always reviews + clicks Publish in eBay's own UI or via a future `respond-to-buyer` named handler).

### Other v3+ ideas (one-paragraph treatments)

- 🔵 **Gmail Triage / Calendar Today** — needs OAuth + token refresh model. Pattern overlaps with Spotify's existing flow but Gmail's token churn is harder.
- 🔵 **Linear / Jira / Notion mirrors** — needs OAuth provider plug-ins (same v3 epic) plus a webhooks-back-into-Scarf flow we don't have.

## Submitting an idea

Open an issue in [awizemann/scarf](https://github.com/awizemann/scarf) tagged `template-idea`. Include:

- One-line summary.
- Category (dev / ops / news / personal / finance).
- Whether it needs secret config (and if so, what kind — API key, OAuth, etc.).
- Whether it fits today's capabilities or needs a v3 core feature (the table above is a good template).

If you're ready to build, see [`templates/CONTRIBUTING.md`](https://github.com/awizemann/scarf/blob/main/templates/CONTRIBUTING.md). The catalog validator (`tools/build-catalog.py`) is the same one CI runs on PRs.