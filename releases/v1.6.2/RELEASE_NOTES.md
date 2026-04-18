## What's New in 1.6.2

### Fixes

- **No more bogus "missing credentials" banner on Chat.** The orange "No AI provider credentials detected" warning was firing on the Chat tab whenever no session was selected, even for users whose credentials were configured and working. Root cause: the preflight check only inspected `~/.hermes/.env` and shell environment variables, missing the Credential Pools file at `~/.hermes/auth.json` (the in-app flow introduced in 1.6.0) and `api_key:` fields in `config.yaml`. The check now covers all four locations Hermes itself reads at runtime, so if you've added credentials via **Configure → Credential Pools**, the warning stays hidden.

### Polish

- Banner subtitle updated to point users at the in-app Credential Pools flow first, rather than prescribing `.env` edits.

---

**Upgrading from 1.6.1:** Sparkle will offer the update automatically. You can also trigger a check via **Scarf → Check for Updates…** or the menu bar icon.
