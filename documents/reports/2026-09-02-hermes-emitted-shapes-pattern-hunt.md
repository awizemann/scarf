# Pattern hunt: Scarf parsers vs Hermes's own serializer emissions (2026-09-02)

Read-only audit of every Scarf reader/writer of Hermes-authored files, checked against emissions
generated with the exact serializer options at Hermes tag `v2026.8.31`:
YAML — `utils.atomic_yaml_write` → `yaml.dump(Dumper=IndentDumper(SafeDumper), default_flow_style=False, sort_keys=False, allow_unicode=True)`, default width 80;
JSON — `utils.atomic_json_write` / `cron/jobs.py` → `json.dump(indent=2, ensure_ascii=False)`.

Context: this class already shipped 3 bugs (bot-create refusal etc.). Convention note:
`.memory/conventions/hermes-authored-file-fixtures-must-come-from-hermes-s-own.md`.

## AT-RISK (ranked by user impact)

### 1. Unquoted colon-bearing map keys — `agent.reasoning_overrides` (HIGH)
PyYAML emits `llama3:8b: high` unquoted (colon-not-followed-by-space is a plain scalar) and
round-trips it fine. Scarf's `HermesYAML.parseNestedYAML` only handles colon-in-key when QUOTED;
the plain branch splits at the first colon (`HermesYAML.swift:129`) →
`maps["agent.reasoning_overrides"]["llama3"] = "8b: high"` (built :194-197, consumed
`HermesConfig+YAML.swift:611`). Downstream `PowerSettingsWriter.setReasoningOverrides`
(`Services/PowerSettingsWriter.swift:55`) validates values via `HermesReasoningEffort.isValid`,
`"8b: high"` fails → writer returns nil → the ENTIRE reasoning-overrides editor silently refuses
to save. Ollama/LM Studio ids (`llama3:8b`, `qwen2.5-coder:32b`) are the normal case. Scarf's own
writer quotes correctly; this detonates only after Hermes rewrites the file — which the very next
`hermes config set` does (including ones Scarf itself runs).

### 2. PyYAML ~80-col line folding truncates long scalars — worst at `quick_commands` (HIGH)
`HermesYAML.swift:84` drops continuation lines by design, so a folded
`quick_commands.<name>.command` parses as its PREFIX only — the slash menu EXECUTES a silently
truncated shell pipeline (prefix runs without its trailing guard/cleanup), and saving the row in
the editor writes the truncation back via `hermes config set` (`QuickCommandsViewModel.swift:152`),
making the loss permanent. Any command with spaces past ~80 cols folds. Readers:
`QuickCommandsViewModel.swift:71-73`, `RichChatViewModel.swift:1857-1864`.
Same truncation, lower impact: `secrets.command.command` (`HermesConfig+YAML.swift:349`,
round-tripped by SettingsViewModel), `agent.personalities.<n>.system_prompt` (read-only, display).
Also: a quoted folded scalar leaves a dangling opening quote — `stripYAMLQuotes`
(`HermesYAML.swift:271`) requires both ends — cosmetic (`bot_peers.<n>.note`).

### 3. `HermesBotProfileYAML` folded `description:` truncated on read, dropped on rewrite (HIGH)
`applyMeta` (`Parsing/HermesBotProfileYAML.swift:170-176`) computes `bodyEnd` via
`continuationEnd` but takes only `rawValue` from the key line; continuation lines are neither
parsed nor kept. Hermes writes descriptions via `write_profile_meta` → `atomic_yaml_write`
(`hermes_cli/profiles.py:992`) — sentence-length descriptions fold. → HANDED to the in-flight
fix agent already editing this file.

### 4. `GatewayConfigWriter` misses flow-style top-level section `slack: {}` (MEDIUM)
`firstIndex(of:headerLineEqualTo:indent:)` (`Services/GatewayConfigWriter.swift:452-456`) accepts
`slack:` and `slack:  # note` but not `slack: {}` (Hermes emits `{}` for a preserved-but-empty
section via `_strip_default_values` preserve_keys). Miss → `.platformMissing` → appendScaffold
appends a DUPLICATE top-level section. PyYAML resolves last-wins so it "works", but the file is
malformed for stricter parsers. Nested-key equivalent IS handled (`keyLineKind` → `.inlineValue`,
:287); only the top-level header lacks it.

### 5. `jobs.json` strict decode of `enabled`/`schedule` (MEDIUM)
`Models/HermesCronJob.swift:130,139,140` hard-decode fields Hermes's own reader treats as optional
(`cron/jobs.py`: `_normalize_job_record` is read-only-tolerant; `job.get("enabled", True)`;
`(job.get("schedule") or {})`). One legacy/hand-edited record → whole-file decode throws in
`HermesFileService.loadCronJobsOutcome` (`HermesFileService.swift:161-166`) → entire cron board
blanks with a "corrupt" banner. Reachable via hand edits, which Hermes documents as supported.
Fix shape: per-record tolerant decode; skip/flag the bad record, keep the board.

### 6. `RichChatViewModel.loadQuickCommands` drops dotted command names (LOW)
`RichChatViewModel.swift:1857` uses the naive `split(separator: ".", maxSplits: 2)` the Mac copy
documents as wrong (`QuickCommandsViewModel.swift:53-58`). `v1.2_deploy` falls out of the iOS
slash menu while the Mac list shows it.

## SAFE
- `HermesBotPeersYAML` — folding guard complete (only surface with a generated-folding test:
  `HermesV021PeerParityTests.swift:121`). Dangling-quote cosmetic from #2 applies.
- `ProfileRoutesYAML` — models the shape directly; reports `.unsupported` on populated flow lists;
  falsy-scalar set over-matches YAML-1.1 bools correctly.
- `GatewayConfigWriter` block geometry (indent 2 nested / 4 bullets matches IndentDumper).
- JSON surfaces byte-level (`gateway_state.json`, `webhook_subscriptions.json`,
  `models_dev_cache.json`, `jobs.json`) — risk is schema-level only (#5).
- Stdout parsers (`HermesCronRunsParser`, `HermesCronDoctorParser`, `HermesCronIncidentsParser`,
  `HermesWebhookList`, `HermesSkillsHubParser`) — different emitter class; spot-checked.
- `MEMORY.md` / `SOUL.md` — free-text passthrough.

## UNTESTED — every YAML surface
No generated fixtures exist anywhere in the repo; every YAML test string is inline and
hand-written. The peer-note test is the sole folding coverage.

## Fixture-test backlog (highest value first; each seeded from a real python3 emission)
1. `quick_commands` (both readers) — long folded command with spaces.
2. `agent.reasoning_overrides` — unquoted `llama3:8b` key + Scarf-write→Hermes-rewrite→Scarf-read round trip.
3. `HermesConfig+YAML` free-text scalars (`secrets.command.command`) — folded, quoted + unquoted.
4. `agent.personalities` — folded `system_prompt` + multi-line form.
5. `GatewayConfigWriter` — top-level `platform: {}` + empty allowlist `[]`.
6. `jobs.json` — record missing `enabled` / `schedule: null`; rest of board still loads.
7. `HermesBotProfileYAML` — folded `description` top-level + under `ui_meta.hermes-bots` (in-flight agent's scope).

Recommended closer: a shared test helper that shells out to `python3` with the pinned dumper
options (or a checked-in generated corpus refreshed per Hermes tag) — closes the CLASS, not just
these seven instances.
