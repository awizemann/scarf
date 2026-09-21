---
title: A host-default picker row clears its key with `hermes config unset`, gated on hasConfigUnset
type: note
permalink: scarf/architecture/a-host-default-picker-row-clears-its-key-with-hermes-config
tags: [hermes, capability-gating, settings, cli-verdict]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/IOSSettingsViewModel.swift, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift, scarf/Scarf iOS/Settings/SettingEditorSheet.swift]
source_paths_inferred: false
source_sha: 18806e7c4dbac0ffd6ff7e91c12d27440d0a8cc5
created: 2026-09-10
updated: 2026-09-10
reviewed: 2026-09-19
reviewed_by: audit:claude-code (background)
---

The absence-sentinel row ("Host default (smart)") that P20 introduced for `approvals.mode` is a READ affordance with a WRITE of its own, and the write is `unset`, not `set ''`. P35 wired it on both platforms; the surrounding contract is what future sentinel rows must copy.

- `config set <key> ''` is not absence for a str-typed key: `_coerce_config_set_value` keeps the string verbatim (`hermes_cli/config.py:3306-3312` @ v2026.9.7) and `_normalize_approval_mode("")` resolves it to `manual` (`tools/approval_context.py:197-214`), while Scarf's own reader drops it and renders "Host default" over the top.
- argv is `config unset <key>` — one positional, no flags — byte-equivalent at the `hasConfigUnset` floor (`hermes_cli/subcommands/config.py:51-55` @ v2026.7.20 = 0.19.0) and at the target tag (`:33-34` @ v2026.9.7).
- Below the floor the row shells NOTHING and shows `HermesConfigUnset.belowFloorHint(key:)`, which names the host-side edit instead (charter C5).
- Mac: `SettingsViewModel.setApprovalMode(_:capabilities:)` → `unsetSetting`. iOS: a pure `SettingEditorSheet.clearAction(kind:stringValue:primedValue:capabilities:)` that precedes and returns before the `valueToWrite` path, so P29's "the sentinel row writes no scalar" pin is unchanged.

## Observations
- [decision] A host-default picker row CLEARS its key with `hermes config unset`, gated on `hasConfigUnset` (0.19.0); below the floor it is inert with a hint and shells nothing #capability-gating
- [gotcha] `hermes config unset` must be judged by OUTPUT, never exit code: the managed-install arm prints `Cannot unset configuration values: …` and RETURNS (`hermes_cli/config.py:3550-3552`), which Python turns into exit 0 #verification
- [invariant] Success is the emitter's own anchored `✓ Unset <key> from <path>`; the other two refusals (`_exit_if_key_managed`, `Config key not set:`) `sys.exit(1)` #verification
- [constraint] `config set <key> ''` is NOT an unset for a str-typed key — the empty string lands on disk and `_normalize_approval_mode('')` resolves it to `manual` #settings
- [convention] The verdict is a per-verb opt-in (`SettingsViewModel.enqueueConfigWrite(verdict:)`): both `config set` and `config unset` are judged by OUTPUT with `failureWins: true`, because both have a managed-install arm that exits 0 after printing a refusal #settings

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Hermes Capability Gating Pattern]]
