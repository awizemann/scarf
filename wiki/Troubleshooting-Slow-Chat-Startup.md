---
title: Troubleshooting-Slow-Chat-Startup
type: note
permalink: scarf-wiki/troubleshooting-slow-chat-startup
created: 2026-05-29
updated: 2026-05-29
---

# Troubleshooting: Slow Chat Startup

**Symptom.** You connect to a server (or use the local context), tap **Chat** in ScarfGo (or open Rich Chat in the Mac app), and the chat sits on a connecting / loading state for **10+ seconds** before it becomes interactive. Subsequent prompts feel fine — only the *first* one after opening Chat is slow.

This page is for that case. If chat never connects at all, see [Servers & Remote](Servers-and-Remote) first.

## What's actually happening

When Chat starts, Scarf opens a stdio JSON-RPC channel to `hermes acp` (locally as a subprocess; remotely over an SSH exec channel) and sends two requests in sequence:

1. `initialize` — handshake, completes in ~100 ms.
2. `session/new` — creates a fresh ACP session.

`session/new` blocks until **every enabled MCP server has finished its initial connection attempt**. If you have an MCP server entry that points at a missing package, an unreachable URL, or a binary that isn't on the SSH non-interactive PATH, hermes-agent retries the connection three times with exponential backoff (1 s → 2 s → 4 s) before giving up. That's **7+ seconds of dead time stacked on top of any healthy MCP server's normal init**, all of which `session/new` waits for.

So one bad MCP entry can stall every chat startup until you fix it.

## Step 1 — Read the ACP stderr stream

When you open Chat, Scarf forwards everything `hermes acp` writes to its stderr into the Console / system log under the `com.scarf.ios` (or `com.scarf` on Mac) subsystem. Look for lines like:

```
ACP stderr: ... [WARNING] tools.mcp_tool: MCP server '<name>' initial connection failed (attempt 1/3), retrying in 1s
ACP stderr: ... [WARNING] tools.mcp_tool: MCP server '<name>' initial connection failed (attempt 2/3), retrying in 2s
ACP stderr: ... [WARNING] tools.mcp_tool: MCP server '<name>' initial connection failed (attempt 3/3), retrying in 4s
ACP stderr: ... [WARNING] tools.mcp_tool: MCP server '<name>' failed initial connection after 3 attempts, giving up
```

The `<name>` is the offending entry under `mcp_servers:` in `~/.hermes/config.yaml`. Note it down — that's the one to fix.

If you see no such warnings and chat is still slow, the bottleneck is elsewhere (network, large session history, slow model). The rest of this page won't help; check [Servers & Remote](Servers-and-Remote).

## Step 2 — Inspect the entry

On the host hermes-agent runs on (your Mac for local, your remote box over SSH):

```bash
ssh you@host 'grep -A4 "  <name>:" ~/.hermes/config.yaml'
```

Replace `<name>` with the name from Step 1. You'll see something like:

```yaml
  fetch:
    command: npx
    args:
    - -y
    - '@some/missing-package'
    enabled: true
```

## Step 3 — Pick a fix

| Failure mode | Symptom | Fix |
|---|---|---|
| Wrong package name | `npm error 404` if you run the command yourself | Use the correct package name. The official MCP fetch server is the **Python** package `mcp-server-fetch`, not an npm one — `command: uvx`, `args: [mcp-server-fetch]`. |
| `npx` / `node` not on the SSH non-interactive PATH | `which npx` fails over `ssh host 'which npx'` even though it works in your interactive shell | Either install `node` to a location on the default sshd PATH (`/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`), or switch the entry to a Python equivalent invoked through `uvx` (which is on `~/.local/bin`, already PATH-augmented by Scarf). |
| Server binary missing | Whatever binary `command:` names doesn't exist | Install it, or change `command:` to an absolute path to the install location. |
| Network unreachable | The MCP needs network and you're offline | Set `enabled: false` for now; revisit when you're online. |

After editing `~/.hermes/config.yaml`, **disconnect and reconnect** in Scarf — or just exit the Chat tab and re-enter — to pick up the new config. Hermes only reads MCP config on `session/new`.

## Step 4 — Verify

Open Chat again and watch stderr. Expect:

- No more `MCP server '<name>' initial connection failed` lines.
- A single line per healthy server: `MCP: registered N tool(s) from M server(s) (0 failed)`.
- `session/new` round-trip drops by ~7 seconds.

If something else is still slow, it's likely Python startup + a working but heavy MCP server. There's no fix for that on Scarf's side today; consider trimming the `mcp_servers` list to only the ones you actually use.

## Why Scarf can't just disable a bad MCP for you

`session/new` accepts a `mcpServers` field in the ACP protocol, but it only adds *additional* servers — it can't suppress server-defined ones. Scarf currently sends an empty list there, so the ACP-level surface to "skip MCP X for this session" doesn't exist. Fixing the entry in `config.yaml` is the only path until Hermes adds a per-session disable knob.

## Related

- [Chat](Chat) — what Rich Chat actually does.
- [MCP, Plugins, Webhooks, Tools](MCP-Servers-Plugins-Webhooks-Tools) — the in-app editor for `mcp_servers`.
- [ACP Subprocess](ACP-Subprocess) — how Scarf talks to `hermes acp`.
- [Servers & Remote](Servers-and-Remote) — connectivity issues that aren't MCP-related.
- [ScarfGo Onboarding](ScarfGo-Onboarding) — iOS-specific PATH workarounds (Citadel inlines `$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin` on every command in v2.5+ so pipx-installed tools resolve, but `hermes` sub-tools may still be missing if their PATH isn't covered).

---
_Last updated: 2026-04-25 — Scarf v2.5.0_