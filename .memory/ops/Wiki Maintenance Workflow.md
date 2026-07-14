---
title: Wiki Maintenance Workflow
type: note
permalink: scarf/ops/wiki-maintenance-workflow
tags:
- docs
- wiki
created: 2026-05-29
updated: 2026-07-14
---

## Observations
- [location] Public docs at https://github.com/awizemann/scarf/wiki — separate git repo cloned to .wiki-worktree/ in repo root (gitignored, sibling to .gh-pages-worktree/) #paths
- [scope] Wiki is public-facing reference; internal dev notes stay in scarf/docs/ #scope
- [workflow] Standard cycle: `./scripts/wiki.sh pull` → edit .wiki-worktree/*.md → `./scripts/wiki.sh commit "docs: …"` → `./scripts/wiki.sh push`. Both commit and push run a secret-scan #workflow
- [security] NEVER commit API keys, tokens, .env files, private keys, or real hostnames/IPs to the wiki. Two-pass secret-scan blocks common patterns + user blocklist at scripts/wiki-blocklist.txt (gitignored). Do not bypass without explicit approval #security #rule
- [update-trigger] Update wiki when: new feature module added → relevant User Guide page; new core service → Core-Services.md; architecture changes → Architecture-Overview.md + sub-page; Hermes version bumps → Hermes-Version-Compatibility.md; non-draft release → bump Home.md latest version + append to Release-Notes-Index.md; keyboard shortcut/sidebar changes → those pages #triggers
- [skip] Skip wiki updates for: bug fixes with no user-observable change, pure refactors, typos, test-only changes, internal cleanups #triggers

## Relations
- complements [[Build and Release Workflow]]

- [gotcha] `wiki.sh sync` re-adds a trailing newline to EVERY page (its awk `print` terminates the last line) while the published GitHub-wiki versions lack it — so a fresh `sync` shows ~50 phantom `+1/-1` diffs even when only a handful of pages truly changed. To find the REAL edits, ignore the +1/-1 pages; substantive edits are the only ones with larger numstat. Don't publish the newline noise — it's cosmetic churn, not content. #quirk
- [fact] The wiki publish is SEPARATE from `release.sh` and Alan-run manually (pull→sync→commit→push via scripts/wiki.sh to scarf.wiki.git); commits land as "docs(wiki): sync from wiki/ (<memophant-sha>)". Not automated by a release cut — a release does NOT publish the wiki; that's a distinct manual step. #release-boundary

- [decision] SUPERSEDED 2026-07-14: the wiki is now published by Memophant's built-in **GitHubWikiPublisher** (Memophant Services/Wiki), NOT the manual scripts/wiki.sh flow. It derives the wiki remote from the repo URL (repo.git→repo.wiki.git), clones to `.memophant/wiki-publish/` (gitignored), runs the two-tier secret scan, strips frontmatter, and pushes — "auto-published on commit" when enabled in Memophant settings. Evidence: publish commit 42811e2 "docs(wiki): sync from wiki/ (1c55f75)" at 11:36 came from `.memophant/wiki-publish/`, not `.wiki-worktree/`. #memophant-publish
- [gotcha] `scripts/wiki.sh` + `.wiki-worktree/` are the LEGACY manual path and are now VESTIGIAL — DO NOT commit/push through them (it creates a divergent clone racing the Memophant publisher). To publish a wiki change: edit the `wiki/` source (via edit_memory / the Memophant bar), then Memophant's GitHubWikiPublisher pushes it on the wiki-tier commit. Retire scripts/wiki.sh + .wiki-worktree once confirmed (proposed 2026-07-14). #retire
- [gotcha] Publish faithfully mirrors the SOURCE — a stale `wiki/Home.md` publishes stale (Home's "Latest release" block sat at v2.15.1 across 4 releases, 2.16.0→2.17.0, because release-prep never bumped it). Auto-publish does NOT fix stale source; the Home.md bump must be part of release prep (now folded into the scarf-release-prep skill). #source-staleness
