---
title: Wiki-Maintenance
type: note
permalink: scarf-wiki/wiki-maintenance
created: 2026-05-29
updated: 2026-05-29
---

# Wiki Maintenance

This wiki is the public reference for Scarf. It is a separate git repo (`scarf.wiki.git`) at <https://github.com/awizemann/scarf/wiki>. This page documents how it is edited, what should and should not go in it, and how it stays in sync with the code.

## Local clone

The wiki is cloned to `.wiki-worktree/` in the main repo (gitignored, sibling to `.gh-pages-worktree/`).

```bash
git clone git@github.com:awizemann/scarf.wiki.git .wiki-worktree
```

If the directory is deleted, re-run the clone — the remote is authoritative.

## The helper: `scripts/wiki.sh`

All routine work goes through `scripts/wiki.sh`, which wraps the local clone with a two-pass secret-scan.

```
./scripts/wiki.sh status                 # git status inside .wiki-worktree/
./scripts/wiki.sh pull                   # fetch + fast-forward (aborts if dirty)
./scripts/wiki.sh new <Page-Name>        # create a stub page with dashed filename
./scripts/wiki.sh stub-check             # list pages still containing the TODO marker
./scripts/wiki.sh commit "<msg>"         # secret-scan, then git add -A && git commit
./scripts/wiki.sh push                   # secret-scan again, then git push
./scripts/wiki.sh touch <Page-Name>      # bump "Last updated" line to today
./scripts/wiki.sh --help                 # full usage including bootstrap
```

`pull` always runs first in any session — it aborts if the worktree is dirty, which prevents accidental overwrites of UI-edited pages.

## When to update

Update the wiki when work changes user-visible behavior, adds a feature module or core service, changes architecture, bumps the Hermes version, or ships a full release.

**Skip** for bug fixes with no observable behavior change, pure refactors, typos, test-only changes, internal cleanups.

## What never goes in the wiki

- API keys, OAuth tokens, GitHub tokens, AWS keys, Slack tokens, etc. The secret-scan blocks common patterns by default.
- Private-key headers (`-----BEGIN ... PRIVATE KEY-----`, OpenSSH).
- Real `.env` file contents.
- Real hostnames or IPs of the maintainer's machines. A user-maintained blocklist at `scripts/wiki-blocklist.txt` (gitignored) catches these as hard blocks.
- Screenshots that include any of the above, or third-party chat content.

The scan has two tiers:

- **Hard patterns** — token regexes + the user blocklist. Any match aborts the commit or push with a non-zero exit.
- **Soft assignments** — `key = value` style lines where the key looks like a secret name (password, api_key, secret_key, token, auth_token, bearer). Matches print a warning and require `--force-terms` on the commit/push to proceed. This page is exempt because it documents the patterns.

Do not bypass the scan without explicit approval from the maintainer.

## Page conventions

- **Filenames** use dashes for spaces (`Memory-and-Skills.md`). GitHub URL-encodes the title automatically.
- **Internal links** use Markdown syntax with the dashed name: `[Memory & Skills](Memory-and-Skills)`. **Not** `[[Page]]` — GitHub wikis don't support MediaWiki-style brackets.
- Every page **ends with**:
  ```
  ---
  _Last updated: YYYY-MM-DD — Scarf v<current>_
  ```
  Stub pages use `— stub` in place of the version.
- Sidebar lives in `_Sidebar.md`; footer in `_Footer.md`; root is `Home.md`.

## Stub workflow

`./scripts/wiki.sh new Some-Page` seeds a page with this template:

```markdown
# Some Page

> **TODO: document.** This page is a stub. See [Wiki Maintenance](Wiki-Maintenance).

---
_Last updated: YYYY-MM-DD — stub_
```

`./scripts/wiki.sh stub-check` lists every page still containing that marker so unfinished pages are visible.

## Source-of-truth rules

- **Release Process** on the wiki is a pointer; the canonical instructions live in `CLAUDE.md` and the header of `scripts/release.sh`.
- **Hermes Paths** mirrors the Key Paths block in `CLAUDE.md` — update both when paths change.
- **Release notes** stay in `releases/v<ver>/RELEASE_NOTES.md` on `main`. The wiki's [Release Notes Index](Release-Notes-Index) only links out.
- **TestFlight + App Store metadata** stay in `releases/v<ver>/TESTFLIGHT_CHECKLIST.md` and `APP_STORE_METADATA.md` on `main`. The wiki's [ScarfGo](ScarfGo) page links to the live TestFlight URL but doesn't duplicate Apple-side metadata.
- **Privacy Policy** has two copies on purpose: the canonical one at `awizemann.github.io/scarf/privacy/` (linked from the iOS Info.plist + App Store Connect), plus a wiki mirror at [Privacy Policy](Privacy-Policy) for in-wiki readability. The wiki copy is updated alongside major releases.
- **Internal dev notes** (PRD, Hermes API discovery, raw architecture) live in `scarf/docs/` in the main repo. The wiki carries the public-relevant parts in distilled form, not full duplicates.

## For external contributors

The wiki is **not forked** when someone forks the main repo — it is a separate hidden repo. Two ways to contribute:

- **Small fixes (typos, clarifications):** click **Edit** on any wiki page in the GitHub UI. Push access to the main repo is required (editing is restricted to collaborators).
- **Larger changes:** clone `git@github.com:awizemann/scarf.wiki.git` directly, or open an issue describing the proposed change and we'll work it in.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (added TestFlight + App Store metadata + privacy-mirror source-of-truth rules)_