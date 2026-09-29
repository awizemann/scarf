---
title: Export surfaces always land artifacts on the user's Mac
type: note
permalink: scarf/conventions/export-surfaces-always-land-artifacts-on-the-user-s-mac
source_paths: [scarf/scarf/Features/Profiles/RemoteProfileExport.swift, scarf/scarf/Features/Sessions/ViewModels/SessionsViewModel.swift, scarf/scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift]
source_paths_inferred: false
source_sha: ebfef32ea30937a78516be06e7bba5bbf07f0ac3
created: 2026-07-17
updated: 2026-07-17
reviewed: 2026-09-29
reviewed_by: audit:claude-code (background)
---

## Observations
- [convention] Stdout-capable exports (sessions jsonl/trace, profile exports) land on **this Mac** regardless of Hermes host. On a remote context Sessions offers only the stdout formats (jsonl/trace); html/md/qmd are local-only (`SessionsViewModel.availableExportFormats` filters `usesStdout` when `context.isRemote`), so every export lands on this Mac (gh#129/#130 sessions jsonl/trace, gh#132 profiles) #export
- [pattern] Stdout-capable → pipe payload as raw Data; remote profile export → host `/tmp` scratch + `streamRawBytes` download + atomic move + cleanup via `RemoteProfileExport` #remote #profile
- [gotcha] Sessions html/md/qmd formats are path-only (no stdout), so they must never be offered on a remote context — handing the Mac panel path to a remote CLI would land the file on the host (SessionsViewModel.swift ~757-775 documents this bug class) #sessions #transport
- [gotcha] `transport.readFile` is a buffered `cat` for <1 MB files only — never for payload downloads; writable remote-path sheets retired in gh#132 after gh#131 proved verification unreliable #transport
- [ux] CLI failure banners show the traceback's last non-empty line; success banners name the byte count (profiles) or destination path (sessions) #errors

## Relations
- builds_on [[scarf/architecture/transport-atomic-write-parity-is-a-per-transport-contract]]
- relates_to [[scarf/architecture/the-transport-writefile-grep-is-not-the-write-surface]]
- relates_to [[scarf/architecture/multi-server-architecture-scarf-2.0]]
