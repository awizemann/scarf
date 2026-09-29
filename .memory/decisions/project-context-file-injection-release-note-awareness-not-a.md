---
title: Project context-file injection: release-note awareness, not a trust gate (t-42db11e9)
type: note
permalink: scarf/decisions/project-context-file-injection-release-note-awareness-not-a
tags: [security, projects, design-decision, hermes-context-files]
source_paths: [scarf/scarf/Features/Projects/MiniApp/MiniAppAgentSession.swift]
source_paths_inferred: false
source_sha: 70efa831cb229c14ceafbcddfbf611856e610c30
created: 2026-06-28
updated: 2026-09-27
reviewed: 2026-09-26
reviewed_by: audit:claude-code (background)
---

## Context

Opening a project chat or mini-app session spawns `hermes acp` with the project dir as the ACP session cwd (chats shipped in t-565f8d45 for new chats, t-24594c4a for resume/reconnect/auto-start; mini-apps via `newSession(cwd: projectRoot)`). Hermes then auto-loads that project's context files (AGENTS.md / CLAUDE.md / .cursorrules / .hermes.md — first match) from the session cwd into the agent's system prompt. A project obtained from an untrusted source (e.g. a cloned repo carrying a hostile CLAUDE.md/.cursorrules) therefore becomes a prompt-injection vector with no user opt-in beyond opening a chat or running a mini-app. (t-42db11e9, found by the 2026-06-28 fresh-eyes audit of b421280.)

## Decision (2026-06-28)

**Ship a release-note awareness line for v-next. Do NOT add a first-open "trust this project's context?" gate now.** Keep the trust-affordance ticketed as a FUTURE escalation.

## Why

- **Projects are user-chosen.** They're added deliberately (NewProjectSheet / clone / template install) — a strong implicit-trust signal. Context files are DATA injected into the prompt, not capabilities; the trust model is about user agency over which projects to work in.
- **Inherent Hermes behavior, not a Scarf vector.** `cd <repo> && hermes` loads the same context files. A Scarf-only gate would be inconsistent with the CLI and give false security; the durable fix (if any) is upstream in Hermes. Hermes already security-scans context files for prompt injection before loading (mitigates, doesn't eliminate).
- **A gate fights t-24594c4a.** The safe version ("don't load context until trusted") would degrade EVERY project chat to "no project context until you click trust" — friction on the primary action for a user-chosen, Hermes-mitigated threat.
- **Awareness already partly exists.** The chat header project chip (currentProjectName, from t-24594c4a) signals chat↔project scope; a release-note line closes the remaining awareness gap.

## Finalized release-note line — SHIPPED in v2.15.0 (t-cea43144)

**Status (shipped v2.15.0, 2026-06-28):** FINAL, covering both chats and mini-app agents. Originally the note claimed mini-app agents deliberately did NOT load context (t-0b850b5b rationale), but Hermes v2026.9.24+ changed this: Hermes pins the ACP session cwd for every turn (`acp_adapter/server.py:759-770` → `gateway/session_context.py:143` → `agent/runtime_cwd.py:84-110`) and builds context-file prompts from it (`agent/system_prompt.py:708-719` → `agent/prompt_builder.py:1733-1752`), so both chats and mini-app sessions now inject the project's context. The `hermes acp` PROCESS cwd no longer decides which files load — **it is the ACP SESSION cwd that matters.** `MiniAppAgentSession` opens `session/new` with `cwd: projectRoot`, so the project's AGENTS.md / CLAUDE.md / .cursorrules / .hermes.md ARE injected. Alan's decision (R12/S12-F6, 2026-09-26): keep mini-app sessions in the project folder so mini-app agents see the same project context a chat does. What bounds an untrusted, web-driven mini-app is the sensitive `prompt` grant, every permission request auto-denied, Hermes's context-file injection scan, and the 8/60s rate limit.

The shipped v2.15.0 release-note line originally stated "(mini-apps deliberately do not load them)" — this was corrected post-ship when Hermes's session cwd pinning became discoverable. The code comment in `MiniAppAgentSession.swift`, the Mini-Apps and Chat wiki pages, the wiki release-notes index and `releases/v2.15.0/RELEASE_NOTES.md` were corrected.

> Opening a chat or mini-app session in a project now loads that project's `AGENTS.md` / `CLAUDE.md` / `.cursorrules` / `.hermes.md` into the agent (so it has project context). Treat a project's context files like its code — only open chats or run mini-apps in projects you trust.

## Future-escalation trigger

Revisit a first-open trust affordance (persisted per project id, mirroring the mini-app permission gate via [[phase-1-milestone-2-mini-apps-implementation-decisions]]) IF the threat model changes — chiefly if Scarf ever auto-opens chats in projects the user did NOT deliberately add, or if Hermes drops its context-file injection scan. Relates to [[Hermes v0.17 Compatibility Decisions]].

## Observations
- [decision] Ship a release-note awareness line for v-next; do NOT add a first-open "trust this project's context?" gate — keep the trust affordance ticketed as a future escalation #projects
- [fact] Both project chats and mini-app sessions load context files (AGENTS.md/CLAUDE.md/.cursorrules/.hermes.md) from the ACP session cwd into the system prompt — an untrusted repo's hostile context file becomes a prompt-injection vector #hermes-context-files #mini-apps
- [fact] Hermes v2026.9.24+ pins the ACP session cwd for every turn and builds context-file prompts from it; the `hermes acp` process cwd no longer decides which context files load (acp_adapter/server.py:759-770, agent/system_prompt.py:708-719) #hermes-context-files
- [fact] MiniAppAgentSession.prompt() spawns with `newSession(cwd: projectRoot)`, injecting the project's context into the mini-app agent; the default `clientFactory` omits `projectCwd`, but that is now irrelevant (session cwd, not process cwd, decides context loading) #mini-apps
- [decision] Alan kept mini-app sessions in the project folder (R12/S12-F6) so mini-app agents see the same project context a chat does; trust is bounded by the sensitive `prompt` grant, auto-denied permissions, Hermes's context-file injection scan, and rate limit #mini-apps
- [fact] The v2.15.0 release-note line originally said "(mini-apps deliberately do not load them)" but was corrected post-ship when Hermes's session cwd behavior became clear #release-notes

## Relations
- relates_to [[phase-1-milestone-2-mini-apps-implementation-decisions]]
- (no relation: the hermes-v0-17-0-audit-findings note was never written; see [[Hermes v0.17 Compatibility Decisions]] instead)
