---
title: Project context-file injection: release-note awareness, not a trust gate (t-42db11e9)
type: note
permalink: scarf/decisions/project-context-file-injection-release-note-awareness-not-a
created: 2026-06-28
updated: 2026-06-28
source_sha: 1599452d48106de9c87bf5286d2b0f6eeee70adb
source_paths: scarf/scarf/Features/Projects/MiniApp/MiniAppAgentSession.swift, wiki/Release-Notes-Index.md
tags:
- security
- projects
- design-decision
- hermes-context-files
reviewed: 2026-07-17
reviewed_by: audit:claude-code (background)
source_paths_inferred: false
---

## Context

Opening a project chat spawns `hermes acp` with cwd = the project dir (shipped in t-565f8d45 for new chats, t-24594c4a for resume/reconnect/auto-start). Hermes then auto-loads that project's context files (AGENTS.md / CLAUDE.md / .cursorrules — first match) from the PROCESS cwd into the agent's system prompt. A project obtained from an untrusted source (e.g. a cloned repo carrying a hostile CLAUDE.md/.cursorrules) therefore becomes a prompt-injection vector with no user opt-in beyond opening a chat. (t-42db11e9, found by the 2026-06-28 fresh-eyes audit of b421280.)

## Decision (2026-06-28)

**Ship a release-note awareness line for v-next. Do NOT add a first-open "trust this project's context?" gate now.** Keep the trust-affordance ticketed as a FUTURE escalation.

## Why

- **Projects are user-chosen.** They're added deliberately (NewProjectSheet / clone / template install) — a strong implicit-trust signal. This is categorically different from mini-apps, which are agent-GENERATED untrusted code and therefore DO get a per-(projectId,miniAppId) permission gate (MiniAppGrantStore; sensitive perms net/file:write/kanban:write default OFF for `generated:true`). Context files are DATA injected into the prompt, not capabilities.
- **Inherent Hermes behavior, not a Scarf vector.** `cd <repo> && hermes` loads the same context files. A Scarf-only gate would be inconsistent with the CLI and give false security; the durable fix (if any) is upstream in Hermes. Hermes already security-scans context files for prompt injection before loading (mitigates, doesn't eliminate).
- **A gate fights t-24594c4a.** The safe version ("don't load context until trusted") would degrade EVERY project chat to "no project context until you click trust" — friction on the primary action for a user-chosen, Hermes-mitigated threat.
- **Awareness already partly exists.** The chat header project chip (currentProjectName, from t-24594c4a) signals chat↔project scope; a release-note line closes the remaining awareness gap.

## Finalized release-note line — SHIPPED in v2.15.0 (t-cea43144)

**Status (shipped v2.15.0, 2026-06-28):** FINAL and **chat-only**, reconciled with t-0b850b5b (shipped option (b) — mini-app agents deliberately do NOT load project context). The chat context-loading commits `b421280` ("load project AGENTS.md in ACP chats — spawn hermes acp with cwd=project") and `5538e30` ("project cwd for resume/reconnect/auto-start chats") shipped in **v2.15.0** ("Projects grow up"), the first cut after v2.13.0, and this awareness line shipped with them — folded into the security/awareness framing of the release notes (v2.15.0 verbatim: "treat a project's context files like its code — only open chats in projects you trust (mini-apps deliberately do **not** load them)") rather than a plain feature bullet that would drop the trust caution. Board task **t-cea43144** is closed. Original verbatim line below.

### Scope: chats only — does NOT need to expand to mini-apps (t-0b850b5b, 2026-06-28)

The release-note line above covers **chats only**. It does **not** need to mention mini-app agent sessions, because mini-app agents deliberately do **not** load project context.

`MiniAppAgentSession` (the `scarf.prompt` backing) spawns its `hermes acp` via the default factory `{ ACPClient.forMacApp(context: $0) }` — **no `projectCwd`** — so the process cwd is NOT the project and the project's AGENTS.md/CLAUDE.md/.cursorrules are not injected. (It still sets the ACP *session* cwd to `projectRoot` via `newSession(cwd:)`, so only TOOL dirs resolve under the project.) t-0b850b5b chose option (b): keep process cwd off the project as a deliberate trust-minimizing choice — a mini-app runs untrusted/agent-generated web content driving the agent unsupervised, a bigger injection surface than a user-opened chat, with no mini-app needing project context today. This note's own "categorically different from mini-apps" framing is the grounding.

If a future change threads `projectCwd` into the mini-app factory (revisit only behind a mini-app context-trust affordance), THIS release-note line must expand to say project context now also loads into mini-app agents. Until then: chats only. Guarded in-code by the docstring + `clientFactory` NOTE in `MiniAppAgentSession.swift`.

> Opening a chat in a project now loads that project's `AGENTS.md` / `CLAUDE.md` / `.cursorrules` into the agent (so it has project context). Treat a project's context files like its code — only open chats in projects you trust.

## Future-escalation trigger

Revisit a first-open trust affordance (persisted per project id, mirroring the mini-app gate via [[phase-1-milestone-2-mini-apps-implementation-decisions]]) IF the threat model changes — chiefly if Scarf ever auto-opens chats in projects the user did NOT deliberately add, or if Hermes drops its context-file injection scan. Relates to [[hermes-v0-17-0-audit-findings]].

## Observations
- [decision] Ship a release-note awareness line for v-next; do NOT add a first-open "trust this project's context?" gate — keep the trust affordance ticketed as a future escalation #projects
- [fact] Opening a project chat spawns hermes acp with cwd=project dir, so Hermes auto-loads that project's AGENTS.md/CLAUDE.md/.cursorrules from the PROCESS cwd into the system prompt — an untrusted repo's hostile context file becomes a prompt-injection vector #hermes-context-files
- [constraint] Context files are DATA injected into the prompt, not capabilities — categorically different from agent-generated mini-apps, which DO get a per-(projectId,miniAppId) permission gate #projects
- [fact] MiniAppAgentSession spawns hermes acp with NO projectCwd, so mini-app agents deliberately do NOT load project context; the awareness line is chats-only and need not expand to mini-apps #mini-apps
- [done] The awareness line SHIPPED in v2.15.0 (2026-06-28), folded into the security/awareness framing of the release notes ("treat a project's context files like its code — only open chats in projects you trust; mini-apps deliberately do not load them"); board task t-cea43144 closed #release-notes

## Relations
- relates_to [[phase-1-milestone-2-mini-apps-implementation-decisions]]
- relates_to [[hermes-v0-17-0-audit-findings]]