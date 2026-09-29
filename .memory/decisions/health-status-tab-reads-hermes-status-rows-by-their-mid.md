---
title: Health Status tab reads hermes status rows by their mid-line mark; ✗ is a neutral off state
type: note
permalink: scarf/decisions/health-status-tab-reads-hermes-status-rows-by-their-mid
tags: [health, hermes-status, parsing]
source_paths: [scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift, scarf/scarf/Features/Health/Views/HealthView.swift]
source_paths_inferred: false
source_sha: ebfef32ea30937a78516be06e7bba5bbf07f0ac3
created: 2026-09-26
updated: 2026-09-26
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

R05 / S14-F4. `hermes status` prints `_row` as `  name  ✓|✗ text` (no colon) and `_kv_flag` as `  Label:  ✓|✗ text` (hermes_cli/status.py:35-52 @ v2026.9.24); the Status tab's parser (`HealthViewModel.parseOutputStatic`, shared with doctor) only knew glyph-first lines.

## Observations
- [decision] A mark right after the label sets the row status: ✓ → ok, ⚠ → warning, ✗ → `HealthCheck.CheckStatus.off` (grey mark, counted as neither passing nor failing, section accent muted when a section is all-off). Most status ✗ rows are things not in use (unset API keys, unconfigured platforms, stopped gateway, sudo off); `hermes doctor` is where missing pieces are judged. Exception: ✗ under `Deep Checks` (live probes, status.py:330-345) → error #health
- [gotcha] `_detail` lines (4-space indent, `Auth file:`/`Error:`) fold into the row above; a `\r`-rewritten progress line is read as its last segment (doctor's 'Running N connectivity checks…' hid the first result), after stripping a CRLF `\r` #parsing
- [convention] Fixtures in scarfTests/HealthStatusRowParsingTests.swift were captured from the tagged 0.21.5 CLI against scratch HERMES_HOMEs; recapture from the CLI rather than hand-writing rows when Hermes changes status output #fixtures
