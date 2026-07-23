---
id: t-2ece52eb
title: Fix gh#134: render markdown tables via Marker engine
status: done
added: 2026-07-22
---

## Description

Issue #134: markdown tables show as raw pipe-text in the Skill editor preview (and chat, memory, widgets — all consumers of MarkdownContentView). Fix by swapping the hand-rolled block parser for the Marker package's core (github.com/awizemann/Marker, local checkout ~/Developer/Marker): add marker-stripped contentText API upstream in Marker, add Marker as package dependency to scarf.xcodeproj, map Marker blocks onto Scarf's MarkdownBlock enum (visual parity), add a Grid-based table block view, tests both sides.

## Plan



## Artifacts



