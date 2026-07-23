---
title: Uninstalling
type: note
permalink: scarf-wiki/uninstalling
created: 2026-05-29
updated: 2026-05-29
---

# Uninstalling

> **Removing ScarfGo from your iPhone?** Standard iOS app delete — long-press the icon → Remove App → Delete App. iOS purges the Keychain group (your SSH keys) and app container along with the binary, so nothing lingers. The Hermes host's `~/.ssh/authorized_keys` line you added during onboarding stays — clean it up manually if you want.

This page covers the macOS app. Scarf is a self-contained `.app` bundle with no installers, launch agents, or kernel extensions. Removing it is two steps; cleaning up its caches is one more.

## Quit and remove the app

1. Quit Scarf (⌘Q).
2. Drag **Scarf.app** from `/Applications` to the Trash.

That's the minimum. Scarf is gone.

## Clean up Scarf's caches and prefs

If you want a complete uninstall, also remove:

```bash
rm -rf ~/Library/Caches/scarf            # remote SQLite snapshots
rm -rf /tmp/scarf-ssh-$(id -u)           # ssh ControlMaster sockets (auto-cleared on reboot)
rm -f  ~/Library/Preferences/com.scarf.app.plist   # app preferences + server registry
```

The Caches dir holds atomic SQLite snapshots pulled from remote Hermes hosts. The `/tmp` dir holds SSH ControlMaster sockets — both are safe to delete; Scarf rebuilds them on demand. (As of v2.0.2 the ssh sockets live under `/tmp` rather than Caches, to stay within the 104-byte macOS Unix domain socket path limit. Older versions kept them at `~/Library/Caches/scarf/ssh/`.)

## What Scarf does NOT touch

Scarf reads Hermes's data; it does not own it. The following are **not** removed by uninstalling:

- `~/.hermes/` — your Hermes install, sessions, memory, config, etc.
- `~/.ssh/` — SSH keys and config used to reach remote servers.
- `~/.local/bin/hermes` (or wherever your `hermes` CLI lives).

To uninstall Hermes itself, follow the Hermes documentation — that's a separate process.

## What about the wiki?

Just for completeness: the GitHub wiki at <https://github.com/awizemann/scarf/wiki> is a separate git repo from the main one. Uninstalling the app has no effect on the wiki.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (added ScarfGo iOS uninstall note)_