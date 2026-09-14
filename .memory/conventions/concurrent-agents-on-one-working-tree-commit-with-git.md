---
title: Concurrent agents on one working tree: commit with `git commit -- <paths>`, never `git add` then `git commit`
type: note
permalink: scarf/conventions/concurrent-agents-on-one-working-tree-commit-with-git
tags: [git, workflow, multi-agent, round-4]
created: 2026-09-11
updated: 2026-09-11
---

Scarf's multi-phase audit remediation runs several agents against the SAME checkout and the same branch. The git index is shared process-wide, so it is not yours alone.

Found in round 4: commit `a1e333cc` (P44) accidentally carries P43's files as well as its own — the P43 agent had staged work in the shared index, and P44 ran `git add <its paths>` then `git commit`. Nothing was lost and every P43 change is on the branch, but its authorship sits in a P44 commit.

## Observations
- [gotcha] `git commit` after `git add <my paths>` commits the WHOLE index, not the paths just added — on a shared working tree that silently absorbs another agent's staged work into your commit #git
- [convention] Commit by path: `git commit -- <paths>` (or `git commit -o <paths>`), which takes a snapshot of exactly those paths and ignores everything else staged. Never `git add -A` / `git add .` on a shared tree either #git
- [convention] The managed Memophant tiers (`.memory/`, `wiki/`, `design/`, `code/`, `sessions/`, `documents/`, `vendors/`, `templates/`, `TASKS.md`, `tasks/`) are never staged by an agent at all — Alan commits each through Memophant's per-tier secret-scanned bar. Leave them dirty; a path-scoped commit is what keeps them out #memory
- [gotcha] The same sharing applies to `git stash`, `git checkout`, and `git restore` — each moves the tree under every other agent. Prefer a read-only `git show <rev>:<path>` when you need a different version of a file #git
- [convention] A worktree's copy of `.memory/`/`wiki/` is a base-commit SNAPSHOT and is stale by construction: never grep those tiers from a worktree — go to the main checkout or use the memophant tools #memory

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Build and Release Workflow]]
