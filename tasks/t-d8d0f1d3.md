---
id: t-d8d0f1d3
title: R6 [iOS]: Splash — use LaunchIcon asset, drop 1024px main-thread decode
status: todo
added: 2026-08-20
priority: low
---

## Description

LaunchView in ScarfIOSApp.swift renders Image("LaunchLogo") — a single 837KB 1024px PNG with empty 2x/3x slots — at 120pt with .interpolation(.high), decoded synchronously on the cold-start main thread. The purpose-built LaunchIcon.imageset (120/240/360, referenced by Info.plist UILaunchScreen) goes unused, and the comment claims they match. Switch to LaunchIcon (or add proper 2x/3x slices), verify visual parity with the UILaunchScreen image so the splash cross-fade stays seamless. Evidence: release audit finding 9.

## Plan



## Artifacts



