---
title: A managed Hermes install refuses every config write at exit 0 — one marker, five verbs, one probe
type: note
permalink: scarf/architecture/a-managed-hermes-install-refuses-every-config-write-at-exit
tags: [hermes-cli, verification, capability-gating]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesManagedInstall.swift, scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift]
source_paths_inferred: false
source_sha: 05eabf021b7b7ec9739248f139e2a0f54619eeb7
created: 2026-09-11
updated: 2026-09-12
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

Shipped by P39 of the round-4 whole-surface remediation (`t-ba727c07`), implementing round-4 decisions 1 and 11.

Hermes has ONE lock (`is_managed()`) and THREE places it prints: `managed_error` → `format_managed_message` (exit 0, a bare `return` under it), `_exit_if_key_managed` (exit 1), and `_env_write_blocked`'s managed-scope arm (returns True — and the caller prints its own success line anyway). Every one of those lines carries `is managed by`, which is why one marker covers every verb Scarf shells onto that lock — `config set`, `config unset`, `plugins enable/disable/update`, `skills trust`, `memory off`, and (P47, round 5) `plugins install --enable`, which reaches `save_config` through `_set_plugin_enabled`; the list is a floor, not a total, see the Round 5 section below — and why every verdict using it runs `failureWins: true`.

Scarf can see only ONE of `get_managed_system`'s two signals: `HERMES_MANAGED` belongs to the systemd service, not to the shell Scarf's transport opens, so only `$HERMES_HOME/.managed` is readable. The probe locks the surface when it can; the marker catches the rest.

## Observations
- [constraint] `is managed by` appears in EVERY spelling of Hermes's managed refusal from v2026.3.28 (`config.py:65-72`, `configuration is managed by NixOS`) through v2026.9.7 (`format_managed_message`, `:445-450`), so one marker is host-independent. It carries the `is ` on purpose: the two NON-refusal `managed by` lines in the same file (`_strip_managed_keys_for_save` `:2289-2291`, `_show_managed_banner` `:2768`) read `were not saved (managed by` and `are managed by`, and matching those would flip a real write #hermes-cli
- [gotcha] A refusal and a success line arrive in the SAME run, at exit 0. `set_config_value`'s `.env` branch prints `✓ Set <key> in <env>` (`config.py:3468`) after `_env_write_blocked` refused (`:2560-2564`), and `plugins disable` / `skills trust` / `memory off` each print their own success line after `save_config` returned without writing (`:2316-2318`). Any verdict on a `save_config` door needs `failureWins: true`, not just the marker #verification
- [fact] Scarf cannot detect an env-var-only managed host. `get_managed_system` (`config.py:276-290` @ v2026.9.7) reads `HERMES_MANAGED` OR `$HERMES_HOME/.managed`; only the marker file is on the transport. `_IGNORED_MANAGED_VALUES` (`brew`, `homebrew`, `:273`) means NOT managed — mirroring that is what keeps a Homebrew Hermes out of a false read-only lock #hermes-cli
- [convention] `config set`/`config unset` pass `--` before their positionals. Both are `nargs="?"` (`subcommands/config.py:24-34`), so a value like `-1` exited 2; `--` is accepted at every tag and verified live #hermes-cli
- [gotcha] Extracting a shared argv builder re-balances `AllConfigWritersParityTests` — the P35 lesson, twice over. Moving `config set` onto `HermesConfigSet.argv` made `SettingsViewModel`'s previously-invisible `HermesConfigUnset.argv` site visible AND pulled in `IOSSettingsViewModel`, which had hidden its whole surface from the gate by building argv into a shell-script string. Teach the scan the new shape in the same commit #testing

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[A host-default picker row clears its key with `hermes config unset`, gated on hasConfigUnset]]


## P39b — what the round-4 review changed here (`cd3e90d5`)

The shape above holds; three of its details did not survive an independent audit.

- [gotcha] **The marker is matched ANCHORED now, not as a bare substring.** `set_config_value`'s success line echoes the user's VALUE (`✓ Set {key} = {value} in {config_path}`, `hermes_cli/config.py:3521` @ v2026.9.7), so `is managed by` inside a QuickCommands prompt or any platform-setup field turned a completed write into a reported failure — unconditionally, since these verdicts run `failureWins: true`. `HermesCLIVerdict.judge` gained `anchoredFailureMarkers`, and the shared marker is `managedRefusalAnchored`, which contains the FULL action prefixes — every refusal on these paths is at column 0 and opens with them (`format_managed_message` `:445-450`, `_env_write_blocked` `:2560-2565`, `_exit_if_key_managed` `:3363-3371`). The prefixes are `Cannot save configuration`, `Cannot set`, `Cannot unset`, and `Cannot remove`. The plugins sets keep their mid-sentence markers as substrings and carry the anchored list alongside #verification
- [decision] **There are TEN arms on `set_config_value`, and the tenth is a partial write.** config.yaml is written (`:3508`); a `terminal.*` key's `.env` mirror is then refused by `_env_write_blocked`'s managed-SCOPE arm (`:3511`, `:2574-2578`) and `:3521` prints `✓ Set …` anyway. Alan's call: success with a warning, not a failure. `HermesConfigMirror` discriminates it from the `.env`-only branch (`:3461-3468`) by the file Hermes names on its own success line
- [fact] **The `.managed` marker's contents are only READ from v0.20.5 (v2026.8.19).** Below that, `get_managed_system` is `if managed_marker.exists(): return "NixOS"` — so a `brew` marker means MANAGED there, the opposite of the target tag's answer. `hasManagedMarkerContents` gates it and is threaded into the probe on both platforms
- [done] **iOS has the probe now** (`IOSSettingsViewModel`), and the read-only lock no longer blacks out the Advanced tab's reads — `.disabled` reaches every descendant, and it was taking Config Diagnostics' "Check", "Backup Now", the Raw Config disclosure, ScarfMon's "Copy as JSON" and all text selection with it



## Round 5 (P47) — the SIXTH door, and why the lock and the verdict are both required

The title's "five verbs" was the round-4 enumeration and is now a FLOOR, not a total: P47
(round-5 decision 1, `f093af74` + `1e88ab3e`) found a sixth door and the enumeration method that
finds the next one.

- [gotcha] **A `save_config` door is a call PATH, not a verb named after a config write.** Round 4
  enumerated five doors by walking `save_config`'s named callers; round 5's sixth,
  `plugins install --enable`, hides inside an *install*: `cmd_install`
  (`hermes_cli/plugins_cmd.py:702`) → `_set_plugin_enabled` (`:754`) → `_write_config_value`
  (`:115-120`) → `save_config`, whose managed arm prints `Cannot save configuration: …` and bare
  `return`s (`hermes_cli/config.py:2315-2318` @ `v2026.9.7`) — and `:755` prints
  `✓ Plugin <name> enabled.` on top of it, at exit 0. The enumeration that finds these is a grep
  of `runHermesCLI(` CALLERS judged on their tagged output, not a list of verbs #verification
- [decision] **The read-only lock and the output verdict are not redundant, and P47 shipped both.**
  Alan chose the lock for the Plugins pane; the verdict is the fallthrough, because
  `HERMES_MANAGED` belongs to the systemd service and not to the shell Scarf's transport opens, so
  an env-var-only managed host is invisible to the `.managed` probe and reaches the refusal anyway.
  "Never *Installed and enabled* on a refused enable" is the invariant; two mechanisms hold it on
  the two host shapes. `managedRefusalAnchored` + `failureWins` now run before
  `HermesPluginInstallOutcome.parse` #verification
- [gotcha] **A `.disabled` control keeps the value it held.** The install sheet's "Enable after
  installing" toggle DEFAULTS to on, so greying it out on a managed host would have left it
  sending `--enable` — a decorative lock. Its `Binding` reads `false` while locked, and
  `enableOnInstall` itself is untouched so unlocking restores the user's choice #scarf
