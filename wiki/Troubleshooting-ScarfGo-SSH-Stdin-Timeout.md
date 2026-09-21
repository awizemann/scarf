---
title: Troubleshooting-ScarfGo-SSH-Stdin-Timeout
type: note
permalink: scarf-wiki/troubleshooting-scarfgo-ssh-stdin-timeout
created: 2026-09-19
updated: 2026-09-19
---

# Troubleshooting: ScarfGo commands time out on a host whose shell rc reads stdin

## Symptom

ScarfGo connects over SSH fine (the server shows as reachable, `hermes --version` works from a terminal), but Dashboard loads, chat startup, Hermes Voice or Live Voice setup on that server hang and end in a timeout. Scarf for macOS against the same host is unaffected, or is affected only for remote profiles.

## Cause

Since v3.2, ScarfGo sends every host script on **standard input** (`head -c N | /bin/sh`) instead of in the command line, so the script never appears in `ps` output on the host. The remote login shell still sources its rc files (`.bashrc`, `.zshrc`, `.profile`) before the script runs. If one of those files reads from stdin — a "press Enter to continue" prompt, an MOTD gate, an interactive menu — that `read` consumes bytes of the script. The shell then runs a truncated script, or waits forever for input that never comes, and ScarfGo reports a timeout.

## Fix (on the host)

Guard interactive-only lines in the rc files so they never run for a non-interactive shell:

```bash
if [[ $- == *i* ]]; then
  read -r -p "Press Enter to continue"
fi
```

or move them to a file that only interactive logins source. Nothing needs to change in ScarfGo.

## Related

- [[ScarfGo]] — transport details
- `CitadelServerTransport.streamScript` doc comment in `scarf/Packages/ScarfIOS` describes the same edge from the code side.
