---
title: MCP-Servers-Plugins-Webhooks-Tools
type: note
permalink: scarf-wiki/mcp-servers-plugins-webhooks-tools
created: 2026-05-29
updated: 2026-05-29
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
- Tool include / exclude filters (whitelist / blacklist what the server exposes).
- Resources / prompts toggles.
- Request and connect timeouts.
- OAuth token detection and clearing.
- **Test Connection** runs `hermes mcp test` and surfaces the discovered tool list inline.

A gateway-restart banner appears after config changes that require a reload.

MCP servers are stored in `config.yaml` under the `mcp_servers` key; the model is `HermesMCPServer`.

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
- Detects the "platform not enabled" state and links to the gateway setup.

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
_Last updated: 2026-05-28 — Scarf v2.10.0 (MCP mTLS client certs for HTTP + SSE servers + read-only `hermes mcp catalog` browse sheet)_