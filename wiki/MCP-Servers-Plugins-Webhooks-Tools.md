---
title: MCP-Servers-Plugins-Webhooks-Tools
type: note
permalink: scarf-wiki/mcp-servers-plugins-webhooks-tools
created: 2026-05-29
updated: 2026-09-26
---

# MCP Servers / Plugins / Webhooks / Tools

Four sidebar items that all extend what Hermes can do. Grouped here because the workflows are similar.

## MCP Servers

Manage Model Context Protocol servers Hermes connects to. Two ways to add:

- **Curated presets** — Filesystem, GitHub, Postgres, Slack, Linear, Sentry, Notion, Stripe, Puppeteer, Memory, Fetch, and more. Picking a preset fills in the command, args, and the env keys it needs.
- **Custom** — stdio (command + args) or HTTP (URL + optional bearer auth).

**Per-server detail view:**

- Enable / disable toggle.
- Environment variable + header editor — written through [`HermesEnvService`](Core-Services) so existing comments and blanks are preserved.
- Tool include / exclude filters (whitelist / blacklist what the server exposes). A non-empty include list is a whitelist and wins over exclude; `include: []` registers **no** tools (shown as "(none — no tools registered)"). The editor rewrites the `tools:` block only when you change a filter.
- Resources / prompts toggles.
- Request and connect timeouts, in seconds. Hermes stores them as floats (`connect_timeout: 45.0`); Scarf shows `45` and only rewrites a timeout you edited.
- OAuth token detection and clearing, and **Sign in** (`hermes mcp login`, Hermes v0.18+).
- **Test Connection** runs `hermes mcp test` and surfaces the discovered tool list inline. Scarf allows `max(30, connect_timeout) + 20` seconds, above Hermes's own probe budget.

A gateway-restart banner appears after config changes that require a reload.

MCP servers are stored in `config.yaml` under the `mcp_servers` key; the model is `HermesMCPServer`.

### Adding OAuth servers _(Hermes v0.17+)_

`hermes mcp add --auth oauth` needs a terminal: without one Hermes refuses to set up OAuth and saves nothing. So on Hermes v0.17 and later Scarf adds OAuth servers itself (gated on `HermesCapabilities.hasMCPOAuthAddNeedsDirectWrite`; older hosts keep the `mcp add` path):

- **Catalog entries** picked with *Browse Catalog…* and left unedited are installed with `hermes mcp install <name>`, which brings the manifest's own OAuth client settings and tool defaults. If the host's catalog doesn't have the entry, Scarf falls back to the next step.
- **Custom and preset OAuth servers** are written straight into `config.yaml` as `url`, `auth: oauth` (and `transport: sse` for SSE) with `enabled: true`, using the same safe writer as every other MCP edit (backup, read-back, restore on mismatch). Unusual `mcp_servers` layouts are refused rather than guessed at.
- Scarf then offers **Sign in** so Hermes can fetch a token; until then the server has no tools.

On a remote (SSH) host the browser sign-in can't redirect back to Hermes. The sign-in sheet shows a field for the address of the browser tab that fails to load after you approve; Scarf passes that URL to `hermes mcp login`, which finishes the flow.

### mTLS client certificates _(v2.10.0+, Hermes v0.15+)_

HTTP and SSE MCP servers gain a mutual-TLS section in the server editor: a client certificate path (`client_cert`), a private-key path (`client_key`), and an SSL-verify control (`ssl_verify`) with an optional custom CA-bundle path. The verify toggle and the CA-bundle path are **independent** — turning verification off doesn't wipe a typed CA path. Gated on `HermesCapabilities.hasMCPClientCerts`.

### MCP catalog browse _(v2.10.0+, Hermes v0.15+)_

A read-only **Browse catalog** sheet renders `hermes mcp catalog` output (the Nous-curated MCP registry) so you can see what's available before adding a server. Browse-only — picking an entry doesn't auto-install. Gated on `HermesCapabilities.hasMCPCatalog`.

## Plugins

Hermes plugins are git-cloned into `~/.hermes/plugins/`. Scarf reads the directory directly for reliable state.

**Operations:**

- Install via Git URL or `owner/repo` shorthand.
- Update (pulls latest).
- Remove.
- Enable / disable.

## Webhooks

Create, list, test-fire, and remove webhook subscriptions:

- Endpoint URL, event filter, optional secret.
- **Test fire** sends a synthetic event so you can verify the receiver before going live.
- Detects the "platform not enabled" state. `hermes webhook` checks only `platforms.webhook.enabled` in config.yaml, so turn it on in Platforms → Webhook (which writes that key as well as `WEBHOOK_ENABLED`); `hermes gateway setup` writes only the `.env` flag.
- ScarfGo lists subscriptions read-only with the same parser as the Mac.

## Tools

Enable / disable Hermes toolsets per platform.

- Each platform (Telegram, Discord, Slack, etc.) gets its own toolset list.
- Connectivity-aware platform menu: green / orange / grey / red dots match the gateway's reported state.
- Toggling calls `hermes tools enable/disable` via `context.runHermes`.

**Fixed in 1.6:** all 13 platforms now appear here (was previously stuck on CLI only).

## Credential Pools

(Same Configure section, related concept.) Per-provider credential rotation:

- API key + OAuth flow handling. The OAuth flow does URL extraction → browser open → code paste; `--type api-key` is correctly inferred for direct API keys.
- API keys are never stored in UI state — only the last 4 chars are previewed.
- Strategy picker: `fill_first` / `round_robin` / `least_used` / `random`.

## Related pages

- [Gateway / Cron / Health / Logs](Gateway-Cron-Health-Logs) — the gateway is what actually consumes platform / tool config.
- [Hermes Paths](Hermes-Paths) — `~/.hermes/plugins/`, `config.yaml` `mcp_servers` key.

---
_Last updated: 2026-09-26 — Hermes v0.21.5 audit R01 (OAuth add without a terminal, remote sign-in paste, tool-filter and timeout round trips)_