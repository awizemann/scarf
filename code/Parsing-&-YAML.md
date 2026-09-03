---
created: 2026-09-03
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing
source_paths_inferred: false
---

# Parsing & YAML — Reading Hermes-Authored Files

Scarf reads several Hermes-owned file formats: `profile.yaml` (bot and user profiles), `config.yaml` (Hermes config), `jobs.json` (cron jobs), cron doctor output, approvals suggestions, bot peers, etc. Each reader must handle YAML quoting, escaping, and schema quirks correctly.

## Bot Profile YAML (HermesBotProfileYAML)

`HermesBotProfileYAML` (Parsing/HermesBotProfileYAML.swift:65`) parses bot profile.yaml files. A bot profile is really just a Hermes profile with `display_name`, `description`, and a `ui_meta['hermes-bots']` block.

[[hermes-bot-mode-profile-storage-format]]

**Fixture rule**: Test fixtures must come from Hermes's own serializer output, not hand-crafted. If you mock a profile, generate it by running `hermes -p <bot> config get` and capture the output. [[hermes-authored-file-fixtures-must-come-from-hermes-s-own]]

## Cron Doctor Parser (HermesCronDoctorParser)

`HermesCronDoctorParser` (Parsing/HermesCronDoctorParser.swift:63`) decodes the structured JSON output of `hermes cron doctor`:
```json
{
  "findings": [
    {
      "type": "error",
      "title": "Invalid schedule",
      "description": "Cron schedule is malformed",
      "remediation": "Fix the schedule syntax"
    }
  ]
}
```

Returns `[HermesCronDoctorFinding]` for the UI to display.

## Approvals Suggestion Parser (HermesApprovalsSuggestParser)

`HermesApprovalsSuggestParser` (Parsing/HermesApprovalsSuggestParser.swift:39`) parses the `/v1/chat/suggest_approval_prompt` endpoint's JSON response:
```json
{
  "approval_prompt": {
    "title": "Approve tool use?",
    "tool_calls": [
      {
        "id": "...",
        "name": "run_bash",
        "arguments": {...}
      }
    ]
  }
}
```

Returns `HermesApprovalProposal` for the UI to render and the user to approve/deny.

## Browser Cloud Provider Parser

`BrowserCloudProviderTests` (Tests/ScarfCoreTests/BrowserCloudProviderTests.swift:13`) tests parsing of browser-based OAuth providers' JSON configs.

## YAML Parsing Pitfalls

**Multiline strings** — YAML `|` (literal) and `>` (folded) blocks need careful parsing. Hermes wraps long values across lines; Scarf's profile writer must not reject files with wrapped values.

**Escaping** — YAML quotes (single/double) and escape sequences (`\n`, `\t`) must round-trip correctly.

**Block structure** — A YAML block's indentation is semantically significant; parsing must preserve it for write-back.

## Testing Parsing

All parsers have comprehensive tests under `Tests/ScarfCoreTests/`. Test fixtures are generated from **live Hermes instances**, not hand-crafted. This ensures Scarf stays in sync with Hermes's serializer.

**Audit pattern** — When a new Hermes release lands:
1. Capture fixtures from the tagged release.
2. Test against Scarf's parsers.
3. If parsing fails, file a bug and fix the parser.
4. Never infer parser behavior from release notes — verify against the source code.

[[hermes-release-audit-process]]

## Round-Trip Safety

When Scarf reads and writes files (e.g., profile.yaml with user edits):
- Parse the file to a typed model.
- User edits the model (e.g., description field).
- Serialize the model back to YAML.
- The written YAML must be byte-identical to the original, except for the edited fields.

This is why hand-crafted fixtures fail — they don't match Hermes's exact serialization format. Always use Hermes-generated fixtures.