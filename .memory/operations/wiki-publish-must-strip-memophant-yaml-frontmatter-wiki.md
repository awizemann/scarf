---
title: Wiki publish must strip Memophant YAML frontmatter (.wiki-worktree)
type: note
permalink: scarf/operations/wiki-publish-must-strip-memophant-yaml-frontmatter-wiki
created: 2026-06-28
updated: 2026-07-14
source_sha: 2b9ef15cdddcb1fde12a88556bf755a623ae7758
source_paths: scripts/wiki.sh
tags:
- wiki
- release
- gotcha
- memophant
reviewed: 2026-07-12
reviewed_by: audit:claude-code (audit)
source_paths_inferred: false
---

# Wiki publish must strip Memophant YAML frontmatter

## Observations

- [gotcha] The repo keeps TWO copies of every wiki page: `wiki/*.md` (Memophant-managed source — carries YAML frontmatter `---\ntitle: …\ntype: note\npermalink: scarf-wiki/…\n---`) and `.wiki-worktree/*.md` (the clone of `github.com:awizemann/scarf.wiki.git` that actually publishes). The published GitHub wiki pages are frontmatter-FREE (they start with the `#` H1). #wiki
- [gotcha] GitHub wikis do NOT parse YAML frontmatter. A page that starts with `---\ntitle: Home\n…\n---` renders the frontmatter as a literal **setext H2 heading** ("title: Home type: note permalink: scarf-wiki/home") at the top of the page (and in `_Sidebar`). Seen live 2026-06-28 after the v2.15.0 wiki push. #wiki #bug
- [root-cause] A naive `cp wiki/Foo.md .wiki-worktree/Foo.md` copies the frontmatter into the publish clone → the stray-heading artifact. The publish step MUST strip the leading `---`…`---` block first. `scripts/wiki.sh sync` (added in commit 64bb87b) now does exactly this — copies `wiki/*.md` → `.wiki-worktree/` (top-level only via the `$WIKI_SRC/*.md` glob, so `wiki/roadmap/` is skipped) stripping the leading frontmatter — so the sync is no longer a manual awk on the operator. #wiki #rule
- [fix] Strip only the FIRST frontmatter block; leave mid-document `---` horizontal rules (e.g. the `---` before the `_Last updated:` footer) intact. This is the awk `cmd_sync` runs: `awk 'NR==1 && $0=="---"{infm=1;next} infm{if($0=="---"){infm=0;closed=1};next} closed&&!body&&$0~/^[[:space:]]*$/{next} {body=1;print}' in.md`. Then `./scripts/wiki.sh commit "…"` + `push`. #wiki
- [verify] After push, confirm with `curl -s https://raw.githubusercontent.com/wiki/awizemann/scarf/<Page>.md | head -3` — it should start with the `#` heading, not `---`. #wiki
- [done] The durable fix shipped: `scripts/wiki.sh sync` (`cmd_sync`, commit 64bb87b) copies `wiki/*.md` → `.wiki-worktree/` stripping leading frontmatter; additive (overwrites/adds, never deletes) and idempotent (frontmatter-free files pass through unchanged). Publish is now `sync` → `commit` → `push` instead of a hand-run awk that release-prep could forget. #wiki

## Relations
- relates_to [[Build and Release Workflow]]
- part_of [[Wiki Maintenance Workflow]]


## Superseded 2026-07-14
- [decision] The `scripts/wiki.sh` sync/awk mechanism this note documents is RETIRED (removed in chore commit e5944eb). The frontmatter-strip LEARNING still holds — but it's now done natively by Memophant's **GitHubWikiPublisher**, which strips the leading `---…---` block at publish time before pushing to `repo.wiki.git`. No manual awk, no `.wiki-worktree/`. This note is kept as the historical root-cause record for why publish must strip frontmatter (the stray setext-H2 artifact seen v2.15.0). See [[Wiki Maintenance Workflow]]. #superseded
