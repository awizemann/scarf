---
id: t-1a1a9ce3
title: Projects R2: doctor trust fixes, YAML registrar hardening, denylist scope
status: done
added: 2026-09-03
priority: urgent
---

## Description

Remediation batch 2 from the fresh-eyes branch audit (after R1 t-50a20782). Doctor (ProjectDoctorService.swift): H4 — adoption collision guard checks folder basename but writes record.name (:625-632): guard on the name that will actually land; M4 — adoption writes to record.rootPath from an agent-writable file, can clobber another project's record (:632): refuse when record.rootPath != adopted path; M5 — sidecarState checks JSON-validity not ScarfProject-decodability (:716-720), so {"note":"wip"} project.json gets overwritten by adopt; require decodability or refuse; M6 — indexInRegistry raw == path match vs normalizedPath causes phantom rows on trailing-slash spellings; normalize at the chokepoint (coordinate with R1's guard work); M7 — deadRootPath removeAll can delete N same-path rows + write empty via allowEmpty (:634-643): remove exactly the found row(s) with accurate messaging, drop allowEmpty blanket; M9 — SSH scan home-exclusion inert for tilde homes (:383-395,422-425): resolve or skip non-comparable homes so /home/user never becomes a scan root. Registrar/YAML: H5+M11 — HermesFileService replaceOrInsertScalar (:1112-1128) falls through to mixed-indent insert breaking whole config.yaml; make it fail-closed on unexpected indentation/block-scalars/anchors, take a timestamped backup before first patch, and make the read-back guard a REAL validation (at minimum re-parse via `hermes mcp list` or refuse+log); M11 — parser misses CRLF/quoted-keys/comments → repeated 90s `hermes` spawns every launch: harden trim + cache a "config unmanageable" marker to avoid the per-launch retry storm; LOW — dev-app detection matches only -dev.app (ProjectsMCPRegistrar.swift:80) while build-detached and scarf-dev-next.app exist → command churn war between copies: widen the dev heuristic; backslash quote/unquote asymmetry (yamlScalar:1337/unquote:1344); misnamed space-quoting test. SkillBootstrap: M10 — pruneKnownBadSkills also deletes from the FLAT skills level contradicting its own doc (:134-138,155): restrict to the scarf/ namespace + legacy flat path ONLY when the flat dir is Scarf-authored (or check content signature), and test the flat branch; LOW — partial install on companion-subdir throw (:299); semverCompare prerelease ordering (:353). Watcher LOWs: dead-inode race between open() and resume() (HermesFileWatcher.swift:241-267 — stat/compare inode after arm, re-arm if changed); core paths never re-established after delete-with-gap (:284-287); assertionless deletedPathDropsOut test; wrong comment at HermesFileWatcherAtomicReplaceTests.swift:60-61. MCP stdio LOW: emit does not break read loop on closed stdout (StdioLoop.swift:86-93). Tests for each; keep fixes surgical.

## Plan



## Artifacts



