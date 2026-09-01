# Project Charters as a Scarf Feature — Design Brief

**Task:** t-94ea4f69 · **Date:** 2026-09-01 · **Status:** decision-ready, no code written
**Verified against:** Hermes agent v0.21.0 source (`~/.hermes/hermes-agent-v0.21.0-audit`), Scarf `main` @ c15060d, Orchestric + Memophant charter implementations.

---

## 1. Recommendation up front

**GO — but a narrow v1, and not the one the framing implies.**

The valuable half of a charter is not a new injection mechanism. Hermes already puts project instruction files **ahead of memory** in the assembled prompt, and Scarf already owns a managed block inside `<project>/AGENTS.md` that it rewrites before every session start. The charter should ride **in that block**, as a leading, Scarf-rendered section derived from a structured store — not as a new file Hermes would have to be taught to load.

What Scarf actually builds is: a **structured charter store + validating editor + a rendered, always-first, precedence-stating block**. That is mostly formatting, a convention, and a nice editor — and it is still worth shipping, because on Hermes ≥ 0.21 the `AGENTS.md` basename is *already* in the hardcoded protected-instruction set, so the charter inherits an un-bypassable per-write approval gate for free, with zero config.

---

## 2. Problem

A Hermes user's project accumulates instruction surfaces with no stated ranking:

- `SOUL.md` — the agent's persona, profile-scoped, not project-scoped.
- `<project>/AGENTS.md` — project instructions, part machine-managed by Scarf, part human prose.
- `~/.hermes/memories/MEMORY.md` + `USER.md` — accumulated, **agent-written** memory.

The third tier is the problem. Memory grows by the agent's own hand, is never reviewed as a whole, and over a long-lived project it quietly acquires more effective authority than anything the human wrote once. There is no place in a Hermes project where a human can say *"these N rules are absolute and outrank everything the agent has learned about this repo."*

Alan's other apps solved this. Orchestric and Memophant define a **charter**: one per project, human-owned, no agent write path, whose *core* (identity + numbered commandments) is injected into every agent's context on every request, with an explicit precedence line — `charter > memory notes > repo instruction files > agent brief` (`Orchestric/Orchestric/Services/AgentRuntime/CharterPromptText.swift:104-107`). The question is whether Scarf can give the same thing to a Hermes user.

---

## 3. Research findings

### 3.1 How Hermes assembles context (v0.21.0)

`build_system_prompt` (`agent/system_prompt.py:1036`) joins three tiers in a fixed order (`agent/system_prompt.py:1054`):

```python
joined = "\n\n".join(p for p in (parts["stable"], parts["context"], parts["volatile"]) if p)
```

| Tier | Contains | Cites |
|---|---|---|
| **stable** | `SOUL.md` identity (first slot), tool/skill guidance, execution guidance, platform hints | `agent/system_prompt.py:470-869`; SOUL at `:476-487`, loader `agent/prompt_builder.py:2192`, path `<home>/SOUL.md` `:2214` |
| **context** | coding workspace snapshot, caller `system_message`, then **Project Context = AGENTS.md/CLAUDE.md/.cursorrules** | `agent/system_prompt.py:874-909`; builder `agent/prompt_builder.py:2396` |
| **volatile** | skills index, then **MEMORY.md**, **USER.md**, external memory providers, session metadata | `agent/system_prompt.py:912-1027`; MEMORY at `:928-932` |

**The load-bearing finding: `AGENTS.md` already precedes `MEMORY.md` in the final prompt string.** The "always ahead of memory" guarantee a charter needs is a property Scarf can have *today*, with no fork and no new mechanism.

Project-context selection is **first match wins, one type only** (`agent/prompt_builder.py:2454-2459`):

```python
project_context = (_load_hermes_md(...) or _load_agents_md(...)
                   or _load_claude_md(...) or _load_cursorrules(...))
```

- `.hermes.md`/`HERMES.md` — nearest-ancestor walk from cwd to git root (`agent/prompt_builder.py:104`). **Shadows AGENTS.md entirely.** This is the known caveat already recorded in `[[Project-Scoped Chat and AGENTS.md Context]]`, and it is the charter's single biggest correctness hazard.
- `AGENTS.md` — a **merged directory chain** git-root→cwd, deeper directories appended later, each labelled `## <relpath>` (`agent/prompt_builder.py:2259-2341`). Also tries `AGENTS.override.md` first per directory (`:2304`).
- Whole block wrapped as `# Project Context\n\nThe following project context files have been loaded and should be followed:` (`agent/prompt_builder.py:2471`), scanned for prompt injection and truncated at `CONTEXT_FILE_MAX_CHARS = 20_000` (`agent/prompt_builder.py:1423`).

**There is no config key for arbitrary always-on prompt text ahead of memory.** Confirmed absent: `extra_instruction_files`, `append_system_prompt`, `system_prompt_suffix`. What exists lands in the *wrong place*:

- `agent.system_prompt` / `display.personality` (`hermes_cli/personality.py:148-158`) → appended at the **very tail** at API-call time (`agent/conversation_loop.py:1636-1637`), i.e. after memory.
- Plugin sections → `SYSTEM_PROMPT_SECTION_POSITIONS = frozenset({"after_memory"})` (`hermes_cli/plugins.py:558`) — literally the opposite of the requirement.
- `agent.platform_hints.<platform>.append` (`agent/system_prompt.py:83-129`) — stable tier and therefore early, but keyed per platform and not per project. Not a fit.

The theoretically ideal injection point — `stable_parts` right after the identity slot, before `_help_guidance_slot = len(stable_parts)` (`agent/system_prompt.py:485-497`) — **requires a Hermes fork.** Out of scope for Scarf.

### 3.2 Protected instruction files (v0.21.0) — protection is real, and free

The config key is a **boolean, not a glob list** (`hermes_cli/config_defaults.py:2673-2680`):

```
"protected_instruction_files": True,
"protected_instruction_extra_patterns": [],
```

The protected set is **hardcoded basenames** (`tools/file_tools.py:737-739`):

```python
_PROTECTED_INSTRUCTION_BASENAMES = frozenset({"agents.md", "claude.md", "soul.md", ".cursorrules"})
```

plus a structural rule: any file whose **immediate parent directory** is named `.hermes` (`tools/file_tools.py:826-832`), with the real `~/.hermes` home excluded (`:812-816`).

Enforcement and its limits:

- Gate: `_check_protected_instruction_write` (`tools/file_tools.py:942-964`), called from exactly **two** sites — `write_file_tool` (`:2255`) and `patch_tool` (`:2405`, covering V4A patches and `*** Move File:` source+dest at `:2385-2391`).
- **Not bypassable.** Deliberately routed around `_run_approval_gate` so `--yolo`, session allowlists and permanent allowlists cannot apply (`tools/file_tools.py:843-940`, docstring `:848-853`); gateway calls pass `allow_permanent: False, allow_session: False` (`:889-890`); timeout → BLOCKED, "silence is not consent" (`:905-908`); no human channel (cron/background) → fail closed (`:936-939`). Test `test_prompts_even_under_yolo` (`tests/tools/test_file_write_safety.py:445`).
- The agent cannot disable it: writes to `~/.hermes/config.yaml` are hard-blocked (`tools/file_tools.py:700-711`).
- **The hole: shell is not covered.** No gate in `tools/terminal_tool.py`; the source says so at `tools/file_tools.py:725` ("the terminal-tool vector is covered separately"). `echo > AGENTS.md`, `sed -i`, `mv` via bash are *not* gated by this feature.
- **Matching is basename-only** (`tools/file_tools.py:790-841`), lowercased, checked on both the normalized and the realpath'd candidate (defeats symlink tricks). An `fnmatch` pattern containing `/` can never match, so **path-scoped patterns are impossible**.

Consequences for a charter file:

| Candidate location | Protected on 0.21? | How |
|---|---|---|
| `<project>/AGENTS.md` | **Yes, free, no config** | basename in the hardcoded set |
| `<project>/.hermes/charter.md` | Yes, free | immediate-parent `.hermes` rule — **but Hermes never loads it into the prompt** |
| `<project>/.memory/charter.md` | Only via `protected_instruction_extra_patterns: ["charter.md"]` — which gates **every** `charter.md` anywhere on disk | basename glob |
| `<project>/.hermes.md` | **No** — not in the set, parent isn't `.hermes` | would need an extra pattern |

### 3.3 What Scarf already has

- **`ProjectAgentContextService.refresh(for:)`** (`scarf/scarf/Core/Services/ProjectAgentContextService.swift:70`) already writes a marker-delimited managed block into `<project>/AGENTS.md`, splicing via `ProjectContextBlock.applyBlock` (`:120`), rendered from the structured record by `ProjectStore.renderAgentContextBlock(for:)` (`Packages/ScarfCore/.../ProjectStore.swift:257`). Its recorded invariants — secret-safe (names not values), idempotent (byte-identical on no-delta, write skipped), bounded (everything outside markers preserved), non-fatal, and **refreshed before `client.start()`** — are exactly the invariants a charter injector needs, already tested.
- **Read-only display** of that block: `CockpitContextPanel` (`Features/Projects/Views/ProjectCockpitView.swift:395`); project MEMORY.md at `CockpitMemoryPanel` (`:467`).
- **Instruction-file editors exist but are ad-hoc.** macOS Memory pane (`Features/Memory/Views/MemoryView.swift:232`) and Personalities SOUL editor (`Features/Personalities/Views/PersonalitiesView.swift:145`) each hand-roll a bare `TextEditor`. iOS `IOSMemoryViewModel.Kind {memory, user, soul}` (`Packages/ScarfCore/.../IOSMemoryViewModel.swift:22-69`) is the closest thing to a shared model. **There is no reusable markdown editor and no frontmatter writer** (`SkillFrontmatterParser.swift:22` parses; nothing serializes).
- **Project model:** `ScarfProject` (`Packages/ScarfCore/.../Models/ScarfProject.swift:36`), canonical record `<root>/.scarf/project.json`, per-project settings `<root>/.scarf/config.json` (`ProjectConfigService.swift:28`).
- **Capability gating:** named semantic flags on `HermesCapabilities` (`Packages/ScarfCore/.../HermesCapabilities.swift:27`), e.g. `public var hasDockerExtraArgs: Bool { atLeastSemver(0, 14, 0) }` (`:303`), consumed as `capabilitiesStore?.capabilities.hasX == true` (`Features/Settings/Views/Tabs/TerminalTab.swift:39`). `isV021OrLater` already exists (`:872`). House rule: gate on the **minor** the feature shipped in.
- **Design tier:** `design/static-site/` tokens + ui-kit. A charter pane must use `ScarfDesign` tokens (never literals), the `SettingsSection` idiom with its 160pt right-aligned label gutter (`Features/Settings/Views/Components/SettingsComponents.swift:9-54`), SF Symbols, and slot into one of the five canonical sidebar sections (Projects). `design/projects-amazing/first-class-project-model-phase-1.md` is authority for anything touching `ScarfProject`.

### 3.4 The charter document shape (from Alan's other apps)

`CharterStore` (`Memophant/MemophantEngine/Memory/CharterStore.swift:44`) is a complete, reusable spec:

- **Layer 1 (core, always injected, hashed):** `identity` (2–3 sentences: what it is, who for, what it is NOT) + `commandments` (`C1`, `C2`, … each one line, absolute).
- **Layer 2 (on demand):** per-commandment `rationale` / `violations` / `see`, plus `guardrails` (soft should/prefer) and `non_goals`, plus free body prose.
- **Soft caps:** 10 commandments, 1,200 rendered core bytes, 160 chars per commandment (`:70`). Every cap and every validation failure is a **`Warning`, never a refusal** (`:286-323`) — a human mid-edit must always be able to save. The only throws are I/O, a malformed file on read, and a hard secret hit on write.
- **`renderCore`** (`:256`) emits `PROJECT CHARTER\nidentity: …\ncommandments:\nC1. …\n` plus a `charter-hash:` line = first 12 hex of SHA-256 over the core excluding the hash line (`:264`).
- **No agent write path, by design** (`CharterPromptText.swift:16-19`): "a surface that let an agent edit the rules it is judged against is a surface where the rules are negotiable." An agent proposes a change by filing a task.
- Reference charter document: `/Users/awizemann/Developer/birdwatch/.memory/charter.md` (10 commandments, guardrails, non-goals, `updated:` stamp).

---

## 4. Mechanism options

| # | Mechanism | Always ahead of memory? | Tamper-protected on 0.21 | Fork? | Verdict |
|---|---|---|---|---|---|
| **A** | Charter section rendered into Scarf's managed block in `<project>/AGENTS.md` | **Yes** (context tier > volatile tier) | **Yes, free** (`agents.md` basename) | No | **RECOMMENDED** |
| B | Standalone `<project>/.hermes.md` holding only the charter | Yes, and highest priority | No (needs an extra pattern) | No | **Reject** — first-match-wins means it *shadows AGENTS.md entirely*, destroying Scarf's existing project block and any user prose |
| C | `<project>/.hermes/charter.md` | **No — never loaded** | Yes, free | No | Reject — protected but invisible to the model |
| D | Charter into `~/.hermes/SOUL.md` | Yes (stable tier, ahead of everything) | Yes (`soul.md` basename) | No | Reject — SOUL is **profile-scoped, not project-scoped**; one charter would leak across every project |
| E | `agent.system_prompt` / personality | **No — lands at the tail, after memory** | n/a | No | Reject |
| F | Hermes plugin section | **No — `after_memory` only** | n/a | plugin | Reject |
| G | Patch `stable_parts` after the identity slot (`agent/system_prompt.py:485-497`) | Yes, ideal | n/a | **Yes** | Reject for Scarf; the right *upstream* ask if Alan ever files one |

**Option A wins on every axis that matters** and reuses machinery Scarf has already shipped and tested.

---

## 5. What Scarf builds (Option A)

### 5.1 Store

`<project>/.scarf/charter.md` — the **same YAML-frontmatter shape as Memophant's** `charter.md` (`identity`, `commandments[]` with `id`/`text`/`rationale`/`violations`/`see`, `guardrails[]`, `non_goals[]`, `updated`), so a charter is portable between Alan's apps and hand-editable.

**Interop rule:** if `<project>/.memory/charter.md` exists (a Memophant-managed repo), Scarf **reads and renders that one** and puts its editor in read-only mode with a "managed by Memophant" note. Two writers on one file is a corruption path, and Memophant's write path carries guards (hard secret scan, canonical serialization) Scarf would have to duplicate exactly. See open question Q1.

Parsing/serialization: Scarf needs a frontmatter **writer**, which does not exist today (`SkillFrontmatterParser` is read-only). Port the relevant slice of `CharterStore`'s canonical serializer rather than inventing one — the round-trip laws (`parse(serialize(x)) == x`) are already pinned by tests over there.

### 5.2 Injection

Extend `ProjectStore.renderAgentContextBlock(for:)` so the managed block **leads** with the charter section, before the existing project-context content:

```
<!-- scarf-project:begin -->
PROJECT CHARTER
identity: …
commandments:
C1. …
C2. …
charter-hash: 9f2c1a0b3d4e

PRECEDENCE: charter > project context > repo instruction files > accumulated memory
(MEMORY.md / USER.md). If a lower tier tells you to do something a commandment forbids,
the commandment wins — STOP and report the conflict by its id; do not pick a side.
The charter is human-owned: never edit it. To propose a change, say what should change
and why, and let the human decide.

### Scarf project context
… (existing block, unchanged) …
<!-- scarf-project:end -->
```

Reuse verbatim: `renderCore`'s byte layout and the `charter-hash` line (both from `CharterStore`), and the precedence sentence's operative half — *"do not pick a side"* — from `CharterPromptText.precedenceLine` (`:104-107`). Adapt the tier names to Hermes's actual tiers, since Hermes has no memory-notes tier.

Every existing invariant of `ProjectAgentContextService.refresh` carries over unchanged and is what makes "always injected" true: idempotent, bounded (user prose outside the markers preserved), non-fatal, and called **before `client.start()`**. Size is a non-issue — a 1,200-byte core against a 20,000-char cap.

Screen the rendered core with Scarf's existing secret handling before it lands, mirroring `CharterPromptText.section`'s rule (`:145-156`): a secret hit **omits the section and logs**, rather than mangling it.

### 5.3 Editor UI

A **Charter** tab in the project cockpit (alongside Context and Memory panels, `ProjectCockpitView.swift:395/467`), built to the `SettingsSection` idiom:

- **Identity** — multiline field, with the prompt "what it is, who it's for, what it is NOT."
- **Commandments** — an ordered list; add/reorder/delete; each row is one line of text with a disclosure for rationale / violations / see. Auto-assign `C<n>` ids, preserve hand-written ones.
- **Guardrails / Non-goals** — simple string lists.
- **Live cap meter** — "7 of 10 commandments · 840 of 1,200 core bytes", straight from `CharterStore.softCaps`.
- **Warnings, never blocks.** Render `Warning.description` verbatim under the offending row; **save always succeeds.** This is the single most important UX rule inherited from the other apps.
- **Preview** — the exact rendered core that will reach the agent, plus the hash.
- No agent write path. Scarf must not expose a charter-write tool or slash command.

### 5.4 Protection wiring

On Hermes ≥ 0.21 there is **nothing to wire** — `agents.md` is already in the hardcoded protected set, so any agent `write_file`/`patch` touching the charter triggers a one-shot, un-bypassable human approval. Scarf's job is to *tell the user this is true*: a small "Protected — the agent needs your approval to edit this" badge on the Charter tab, gated on `capabilities.hasProtectedInstructionFiles` (a new `atLeastSemver(0, 21, 0)` flag; `isV021OrLater` at `HermesCapabilities.swift:872` already exists to build on).

**State the hole honestly in the UI copy.** The gate covers the file tools only, not shell (`tools/file_tools.py:725`). One line: "Protects against the agent's file-edit tools. A shell command can still rewrite the file."

Also worth surfacing: if `security.protected_instruction_files` has been set to `false` in `~/.hermes/config.yaml`, show the badge as *off* — Scarf already reads config (`HermesFileService.swift:39`) and can set it back via `hermes config set` (`SettingsViewModel.swift:146-162`), which is the preferred idiom over rewriting YAML.

---

## 6. Phased scope

**v1 (minimal, ships the whole thesis)**
1. `<project>/.scarf/charter.md` store: parse + canonical serialize + `validate` → warnings + `renderCore` + hash.
2. Read-only passthrough for `<project>/.memory/charter.md` when present.
3. Charter section prepended to the existing managed AGENTS.md block, with the precedence line.
4. Charter tab: identity, commandments (text only), cap meter, warnings, preview.
5. Protection badge gated on ≥ 0.21, with the shell caveat stated.
6. Release-note line, in the same trust framing as v2.15.0's context-file line.

**v2**
- Per-commandment rationale / violations / see, with a disclosure UI.
- Guardrails and non-goals.
- Charter templates (a starter charter per project template, so `.scarftemplate` authors can ship one).
- Charter shown in the project export / template exporter's `knownInstructionFiles` awareness (`ProjectTemplateExporter.swift:22`).

**v3 / speculative**
- **Staleness notice.** Orchestric injects a "charter changed, your copy is stale" bus message (`CharterPromptText.swift:182-213`). Hermes/ACP has no equivalent channel, and the prompt is cached; the honest v3 approach is a Scarf-composed *user* message on the next turn after a mid-session charter save. Needs design.
- **Charter conflict reporting** — asking the agent to name commandment ids when it stops. Cheap to add to the precedence line; worth measuring before promising.
- Upstream ask: a Hermes config key for a project-scoped instruction block in the **stable** tier (option G).

---

## 7. Pre-0.21 degradation

Clean, and this is a strength of Option A.

| Capability | ≥ 0.21 | < 0.21 |
|---|---|---|
| Charter reaches the model, ahead of MEMORY.md | ✅ | ✅ — AGENTS.md loading and the stable/context/volatile ordering long predate 0.21 |
| Precedence stated to the model | ✅ | ✅ |
| Editor, validation, caps, preview, hash | ✅ | ✅ — entirely Scarf-side |
| Agent file-tool writes require approval | ✅ free | ❌ — no gate; the agent can rewrite AGENTS.md, charter included |
| Badge shown | "Protected" | "Not protected on this Hermes — upgrade to 0.21+" |

So on an older host the charter degrades from *enforced* to *stated*, which is still the majority of the value and matches how every other Scarf feature gates. **No feature hiding is needed** — only the badge changes.

Independent hazard, version-independent: **a `.hermes.md` or `HERMES.md` in the project or any ancestor up to the git root shadows `AGENTS.md` entirely** (`agent/prompt_builder.py:2454-2459`), silently dropping the charter. This is the already-known caveat from `[[Project-Scoped Chat and AGENTS.md Context]]` and it becomes materially more serious once a charter rides in that file. **v1 must detect it and warn loudly in the Charter tab** — "your charter is not reaching the agent, because `../.hermes.md` shadows AGENTS.md." A charter that silently doesn't load is worse than no charter.

---

## 8. Honest benefit analysis

**What a structured charter gives that a hand-written `## Rules` section in AGENTS.md does not:**

1. **A guaranteed, machine-maintained position and a stated precedence.** Scarf renders it first, refreshes it before every session, and states in the agent's own context that it outranks memory. A hand-written section drifts down the file and asserts nothing about rank.
2. **A shape that makes the rules writable.** "Identity, then ≤10 one-line absolute rules, each with a rationale" is a genuinely different authoring act from "write some prose." The caps are the feature: they force the human to decide what is actually absolute. Birdwatch's charter is 10 commandments because the form demanded it.
3. **Ids.** `C3` is quotable in a conflict report, a task, a code comment. Prose rules aren't addressable.
4. **The free tamper gate on ≥ 0.21** — the one property the human cannot get by writing prose, and cannot get by putting the rules anywhere else that Hermes actually loads.
5. **Portability with Alan's other apps** — one document shape across birdwatch, Orchestric, Memophant, and now any Hermes project.

**What it honestly is not:**

- It is **not a new enforcement mechanism.** The model can ignore a commandment exactly as it can ignore any instruction. Nothing here is a gate on the agent's behavior; it is a gate on *edits to the rules*.
- It is **not a new injection guarantee.** AGENTS.md already precedes memory. The charter block's ordering advantage over a hand-written section is *within a file*, which is a weak signal on its own — the precedence *sentence* is what carries the force, and that sentence could be pasted into any AGENTS.md by hand.
- So yes: **v1 is mostly formatting, a precedence convention, and a nice editor.** The three things that make it a product rather than a snippet are (a) the editor turning "write your rules" into a guided, validated act, (b) the always-refreshed-before-session-start guarantee Scarf already owns and a human doesn't, and (c) the protection badge on 0.21+ telling the user something true and non-obvious about their own setup.

That is a real product — small, honest, and cheap, because 80% of the plumbing already ships. It would **not** be worth building if it required a Hermes fork or a new injection path. It doesn't.

---

## 9. Open questions for Alan

- **Q1 — Memophant interop.** For a repo that already has `.memory/charter.md`, is read-only passthrough right, or should Scarf write through to it (duplicating Memophant's guards), or ignore it and keep a separate `.scarf/charter.md` (two charters, which seems clearly wrong)? Recommendation: read-only passthrough in v1.
- **Q2 — Global charter?** Should there be a user-level charter across all projects? SOUL.md is the only always-ahead-of-everything slot and it is profile-scoped — technically the natural home, but it is the persona file and overloading it is a semantic mess. Recommendation: project-only in v1.
- **Q3 — Do we gate anything on charter presence?** Orchestric *blocks* an orchestrator spawn on a project created after the feature existed, and nags older projects (`CharterGate.swift:109-111`). Scarf has no equivalent authority over a chat, and blocking a chat over a missing charter would be user-hostile. Recommendation: nag only, or not even that — offer it, don't demand it.
- **Q4 — Does the charter belong in template exports?** A `.scarftemplate` shipping a charter is a strong story ("this template comes with its rules"), but a template-authored charter is *not human-owned by the person who installed it*. Show it as a proposal to accept on install?
- **Q5 — Precedence wording.** Hermes has no "memory notes" tier, so the Orchestric sentence needs adapting. Is the draft in §5.2 the right ranking — specifically, should the charter be stated as outranking `SOUL.md`? SOUL is physically *ahead* of it in the stable tier, so the sentence would be asserting precedence against position.
- **Q6 — Shell hole.** Worth also recommending users add nothing, or should Scarf offer a one-click `hermes config set` of something that narrows the terminal vector? (Nothing in 0.21 does this specifically; approvals for terminal are a separate, coarser system.)

---

## 10. Verdict

**GO.** Build v1 as scoped in §6. The mechanism is Option A — the charter rides as the leading section of Scarf's existing managed `AGENTS.md` block, rendered from a structured `<project>/.scarf/charter.md` in Memophant's document shape.

Reasoning, in one paragraph: the expensive parts of a charter system — an always-injected position ahead of memory, an idempotent bounded writer, tamper protection — are all **already true or already built**, in Hermes's prompt tiers, in Scarf's `ProjectAgentContextService`, and in v0.21's hardcoded protected-basename set. What is missing is the small, human-facing half: a shape that makes absolute rules writable, ids that make them addressable, a validating editor that never blocks a save, and a badge that tells the user the truth about whether their rules are protected. That is a few days of work against machinery with existing tests and invariants, it degrades cleanly on older Hermes, and it fails safe. The one thing that must not be skipped in v1 is the `.hermes.md` shadowing warning — a charter that silently never loads is worse than no charter at all.
