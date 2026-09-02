---
title: Export surfaces always land artifacts on the user's Mac
type: note
permalink: scarf/conventions/export-surfaces-always-land-artifacts-on-the-user-s-mac
source_paths: [scarf/scarf/Features/Profiles/RemoteProfileExport.swift, scarf/scarf/Features/Sessions/ViewModels/SessionsViewModel.swift, scarf/scarf/Features/Profiles/ViewModels/ProfilesViewModel.swift]
source_paths_inferred: false
source_sha: cc42250a7195da79d17ebe0e2d8351d5ea93c384
created: 2026-07-17
updated: 2026-07-17
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

- [convention] Any user-facing "Export…" in the Mac app produces a file on the **user's Mac**, whichever host Hermes runs on. Decided across gh#129/PR#130 (sessions) and gh#132 (profiles). Never hand an `NSSavePanel`/`NSOpenPanel` path to a CLI that may run on a remote host, and never ask the user for a remote destination path for an export. #export #remote
- [mechanism] Two implementation shapes, chosen by CLI capability: (1) CLI has a stdout mode → pipe the payload (`hermes sessions export -`, raw `Data`, stderr kept separate — `runHermesCLIData`); (2) CLI only takes `--output <path>` → export to a generated `/tmp/scarf-*-<uuid>` scratch on the host, stream down via `transport.streamRawBytes` (RemoteBackupService shape, chunked, never in memory), atomic move into the panel destination, delete the scratch on every path. See `RemoteProfileExport` in the app target. #pattern
- [anti-pattern] `transport.readFile` is a fully-buffered `cat` scoped to <1 MB files — never use it for payload downloads. Remote-path input sheets with a "Verify" for *writable* paths are retired (gh#131's false-green class); the surviving remote-path sheet is import-only (existing-file checks). #gotcha
- [ux] Failure banners reduce Python tracebacks to their **last** non-empty line (`ProfilesViewModel.failureMessage`, Sessions `errorSummary`); success banners name the byte count so an empty file can't masquerade as a good export. #errors


## Observations
- [convention] Every Mac-app "Export…" writes the artifact to the user's Mac regardless of where Hermes runs (gh#129/#130 sessions, gh#132 profiles); never hand a panel path to a possibly-remote CLI #export
- [pattern] CLI with stdout mode → pipe payload as raw Data; CLI with only `--output` → host `/tmp` scratch + `streamRawBytes` download + atomic move + scratch cleanup (`RemoteProfileExport`) #remote
- [gotcha] `transport.readFile` is a buffered `cat` for <1 MB files only — never for payload downloads; writable remote-path "Verify" sheets are retired (gh#131 false-green class) #transport
- [ux] CLI failure banners show the traceback's last non-empty line; success banners name the byte count #errors
