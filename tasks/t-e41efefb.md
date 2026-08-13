---
id: t-e41efefb
title: v2.19.1 R6: Fix uninstall leaving project registered + isolate boilerplate UI tests
status: done
added: 2026-08-13
---

## Description

ProjectTemplateUninstaller.swift:224 removes by path equality and :232 swallows saveRegistry failures — uninstalled projects survive in projects.json (the actual accumulator behind the fixture rows). Fix + make the journey UI test green. Also route scarfUITests.swift/scarfUITestsLaunchTests.swift through the same makeApp isolation.

## Plan



## Artifacts



