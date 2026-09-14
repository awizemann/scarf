---
id: t-ios-preflight-stderr
title: gh#112 iOS preflight: `confirmModelPreflight` now captures `ProcessResult` from both `hermes config set` invocations and surfaces the failing key + exit code + first 400 chars of stderr/stdout in `.failed()` instead of the opaque "Couldn't save". Same shape `IOSSettingsViewModel.saveValue` already uses. Lets Docker-wrapper users self-diagnose missing CWD / missing TTY / container-not-running / PATH-miss without a separate log capture. The deeper read-path refactor (route Settings reads through `hermes config get`) is split out as t-ios-cfg-get.
status: archived
source: gh#112 failure 1
---

## Description



## Plan



## Artifacts



