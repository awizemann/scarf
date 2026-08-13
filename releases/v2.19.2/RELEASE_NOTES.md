# Scarf v2.19.2

A focused point release for one nasty failure mode reported in [gh#138](https://github.com/awizemann/scarf/issues/138): if your SSH connection sits behind something that reacts to every connection attempt — Cloudflare Zero Trust being the reported case — a dropped connection could make Scarf's reconnect behavior spawn hundreds or thousands of browser OAuth tabs while you were away. Scarf now stops dialing a dead host after a few failures and backs off instead.

## Fixed: runaway SSH reconnects (the browser-tab explosion)

Scarf deliberately uses your system `ssh`, so everything in `~/.ssh/config` — ProxyJump, agents, and ProxyCommands like Cloudflare's `cloudflared access ssh` — just works. The flip side: with a side-effectful ProxyCommand, *every* fresh connection attempt has consequences. Cloudflared opens a browser tab for OAuth; hardware-key and Secretive agents prompt for a touch.

Normally one shared ControlMaster session absorbs all of Scarf's SSH traffic. But when the connection dropped and re-authentication was required, the master died — and Scarf's background pollers (the remote file watcher checks every 3 seconds, the connection status pill every 15) each kept trying to establish a fresh connection, forever, with no backoff. Overnight with an expired Zero Trust session, that's over a thousand attempts an hour, each one a new tab.

v2.19.2 adds a per-host **circuit breaker** in front of every outbound SSH attempt:

- After **3 consecutive connection-level failures**, the breaker opens: further attempts fail instantly *without launching ssh at all* — so no ProxyCommand runs, no tabs open, no agent prompts fire.
- While open, a **single probe** retries on exponential backoff (30 seconds, doubling to a 5-minute cap). The moment a probe succeeds, everything resumes at full speed.
- **Your intent overrides the breaker.** Test Connection, the chat Reconnect button, and re-adding a server all reset it immediately — an explicit action always gets a real attempt.
- Only connection-level failures count. A remote command that runs and fails proves the connection is alive, and closes the breaker.

The chat session's own reconnect was already capped at 5 attempts with backoff; the breaker now brings every background code path — file watching, status polling, file reads/writes, remote SQLite queries — under the same discipline.

## Under the hood

- New `SSHConnectionGate` in ScarfCore with 9 deterministic unit tests covering the full backoff schedule, single-probe admission, and per-host isolation, plus an end-to-end test that trips the breaker with real `ssh` processes and proves the fail-fast path never spawns one.
- `scp` invocations participate in admission but never score the breaker — scp's exit codes can't distinguish a connection failure from a file error.
- Local-only ControlMaster maintenance (`ssh -O check` / `-O exit`) is exempt: it never dials the remote and must not poison the breaker.
- Full suite green: 1,162 ScarfCore tests.

## Upgrade notes

Scarf updates automatically via Sparkle; this release requires macOS 14.6+ as usual. No Hermes version change — v0.20.0 remains the target, and every earlier host back to v0.6.0 keeps working. Local (non-SSH) setups are entirely unaffected. No ScarfGo/TestFlight build is needed: iOS uses its own Citadel-based transport, which already has connection pooling and is not part of this code path.
