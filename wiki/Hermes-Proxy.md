---
title: Hermes-Proxy
type: note
permalink: scarf-wiki/hermes-proxy
created: 2026-05-29
updated: 2026-05-29
---

# Hermes Proxy

A user-facing surface for Hermes v0.14's new `hermes proxy` CLI. Scarf wraps the long-running child process in a Configure → Hermes Proxy sidebar destination so you can launch an OpenAI-compatible local server that attaches your authenticated upstream credentials to outbound requests — then point Codex CLI, Aider, Cline, or VS Code Continue at the endpoint and any bearer token works.

**Available in:** Scarf 2.9+ on Hermes v0.14+. Capability-gated on [`HermesCapabilities.hasHermesProxy`](Hermes-Version-Compatibility) so the sidebar entry stays hidden on pre-v0.14 hosts.

**Local server only in v2.9.** SSH-deployed Hermes hosts would need an additional port-forward step on top of starting the child — the panel renders an explanatory notice on non-local server contexts instead of broken controls. SSH proxy launching is a follow-up.

## What it does

`hermes proxy start --provider nous --host 127.0.0.1 --port 8645` runs a small aiohttp server on your Mac that:

1. Accepts OpenAI-compatible `POST /v1/chat/completions` (and related) requests on `http://127.0.0.1:8645/v1`.
2. Accepts **any** bearer token in the `Authorization: Bearer <whatever>` header — your client doesn't need real upstream credentials.
3. Forwards each request to the upstream adapter (Nous Portal in v0.14) with the freshly-minted bearer token Hermes mints from your OAuth state in `~/.hermes/auth.json`.
4. Streams the response back to your client.

The net effect: any tool that talks OpenAI Chat Completions can use your Hermes-managed subscription, including subscription-gated providers (Claude Pro, ChatGPT Pro, SuperGrok) once their adapters land in a future Hermes version.

## The panel

The view ([`HermesProxyView`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Features/Proxy/Views/HermesProxyView.swift)) is composed of four cards:

**Status badge** — `ScarfBadge` next to the page title. Green "Running" when the child is alive; grey "Stopped" otherwise.

**Controls card** — Provider picker (populated from `hermes proxy providers`; defaults to `nous` which is the only adapter shipped in v0.14), Port field (defaults to 8645 from `hermes_cli/proxy/server.py`'s `DEFAULT_PORT`), and Start / Stop buttons. Both inputs disable while the proxy is running so you can't change them mid-flight. The Start button uses `ScarfPrimaryButton`; Stop uses `ScarfDestructiveButton`. Any launch failure (port in use, missing aiohttp dependency, adapter not authenticated) renders inline below the controls in `ScarfColor.danger` — no alert sheet.

**Endpoint card** (rendered only while running) — surfaces the full endpoint URL (`http://127.0.0.1:8645/v1`) in monospace with a copy-to-clipboard button. Below it: "Forwarding via \<provider\>. Use any bearer token in your client — the proxy attaches your real credential." This is the affordance you hand to Codex / Aider / Cline.

**Log card** — Capped 200-line tail of the child's stderr (Hermes writes the startup banner + ongoing chatter to stderr; stdout is reserved for proxied request bodies). Auto-scrolls to the latest line. A Clear button surfaces when the buffer is non-empty so a fresh launch after a failure isn't cluttered with old output.

**Help card** — Static usage hint: "Point any OpenAI-compatible client at the endpoint above." with a sign-in suggestion (`hermes login <provider>`) if the adapter reports not authenticated.

## What runs under the hood

[`HermesProxyService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/HermesProxyService.swift) — a `@MainActor @Observable` service that owns the long-running `Process` and the log buffer. Spawn flow:

1. Resolve the `hermes` binary path from the active `ServerContext.paths.hermesBinary`.
2. Build args: `["proxy", "start", "--provider", provider, "--host", host, "--port", String(port)]`.
3. Inherit the PATH-enriched env from [`HermesFileService.enrichedEnvironment()`](Core-Services) — without this, Scarf launched from Finder hands the child macOS's stripped launch-services PATH and any tooling the proxy spawns (e.g. for browser-tools setup) can't find dependencies on PATH. Same fix [`LocalTransport.environmentEnricher`](Core-Services) applies for the rest of Scarf's subprocess spawns.
4. Wire stderr to a `Pipe` with a `readabilityHandler` that batches incoming bytes and hops to MainActor to append to `logLines` (capped at 200 to prevent memory growth on a misbehaving proxy).
5. `terminationHandler` drains any trailing buffered bytes (so the last "stopped" message isn't dropped), then hops to MainActor to clear `isRunning` / `endpoint` / `routedProvider`.

Stop is `Process.terminate()` (SIGTERM) — Hermes's proxy traps SIGINT/SIGTERM and exits cleanly with a "proxy: stopped" line on stderr.

Provider list is probed via `hermes proxy providers` (parsed defensively from the box-drawn CLI output) at `.task` time + on user-requested refresh. Falls back to `["nous"]` on any probe failure so the picker stays usable.

## Wire defaults

Mirror upstream constants from `hermes_cli/proxy/server.py`:

| Field | Default | Source |
|---|---|---|
| Host | `127.0.0.1` | `DEFAULT_HOST` |
| Port | `8645` | `DEFAULT_PORT` |
| Provider | `nous` | first registered adapter in `ADAPTERS` |

When Hermes bumps any of these, mirror the change in `HermesProxyService`'s static defaults.

## Authentication

The proxy doesn't auth requests — it auths the **upstream**. Sign in to the provider first via `hermes login <provider>` on the CLI (Scarf doesn't drive this from the panel in v2.9 because the OAuth flow is interactive and varies per provider). The Help card surfaces this hint when the adapter reports not authenticated. v0.14 ships with `nous` only; future Hermes versions will add `claude-pro`, `chatgpt-pro`, `supergrok`, etc.

## Using the proxy

Set the OpenAI-compatible endpoint in your client config:

| Tool | Setting |
|---|---|
| **Codex CLI** | `OPENAI_BASE_URL=http://127.0.0.1:8645/v1` (env var) |
| **Aider** | `--openai-api-base http://127.0.0.1:8645/v1` |
| **Cline** | OpenAI Compatible provider → Base URL `http://127.0.0.1:8645/v1` |
| **VS Code Continue** | `"apiBase": "http://127.0.0.1:8645/v1"` in `config.json` |
| **Anything else** | Any client that takes a base URL override for OpenAI-format chat completions |

The bearer token in your client config doesn't need to be real — any string works. The proxy strips it and substitutes the upstream credential.

## What it isn't

- **Not a multi-tenant server** — listens on 127.0.0.1 only by default. Don't expose it on a public interface; there's no per-request authorization.
- **Not a router** — single upstream provider per running proxy. Switch upstreams by Stop → pick a different provider → Start.
- **Not a cache** — every request hits the upstream. Hermes's prompt-cache benefits apply normally (cross-session 1h Claude prefix cache in v0.14, etc.) but the proxy itself doesn't add caching.
- **Not a model alias layer** — your client's `model:` field forwards verbatim. Pick model names the upstream accepts.

## Pre-v0.14 hosts

Pre-v0.14 Hermes doesn't have the `proxy` subcommand; Scarf's `HermesCapabilities.hasHermesProxy` flag is false on those hosts and the sidebar entry is hidden entirely (no broken Start button surfaces). Upgrade Hermes (`hermes update`) to unlock the panel.

## Related

- [Hermes Version Compatibility](Hermes-Version-Compatibility) — the full v0.14 capability flag map
- [Core Services](Core-Services) — `HermesProxyService` implementation notes
- [Sidebar and Navigation](Sidebar-and-Navigation) — where Hermes Proxy slots in the Configure section