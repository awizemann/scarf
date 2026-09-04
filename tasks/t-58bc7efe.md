---
id: t-58bc7efe
title: Projects G2: HMAC injectivity, signer-fail refusal, unknown-key parity, quarantine parity, beacon consent + lows
status: done
added: 2026-09-04
---

## Description

P8 audit SEC M2/M4/L1/L2/L4/L5, DI H2/M1/M2/M3/L3: length-prefix the HMAC permissions field and reject 0x1F/comma in components (query:sessions,store re-splits into an unapproved store grant); a signer that can't reach its key must refuse the write, not purge all grants; ScarfProject + SessionProjectMap gain unknown-key preservation; project.json gains quarantine parity (and GuardedJSONStore must not overwrite a good .bak with quarantined bytes); image-widget beacon gets per-host consent; slash-command regex \A..\z anchors; TransportPrivateMode for .bak/.corrupt copies; consent-sheet query-kind validation; memory-block strip bounded.

## Plan

All nine fixes landed on main (working tree, uncommitted). Verified: ScarfCore 2134 tests + 42 (MCP kit), scarf scheme 712 tests, iOS "scarf mobile" build — all green with private DerivedData.

1. SEC-M2 + L4 — HMAC payload v2. `canonicalPayload(for:)` now `throws`, prefixes `"v2"`, and renders each sorted permission as `<utf8 byte count>:<permission>`; any component holding 0x1F or a comma is refused at sign time (`MiniAppGrantSignerError.uninjectiveComponent`). `isAuthentic` returns false for such rows without consulting the key. v1 tags no longer verify → one-time re-ask. Consent-time kind validation moved into `MiniAppPermission.init(rawValue:)`: a `query:` kind outside `[a-z][a-z0-9._-]{0,63}` demotes to `.unknown` (denied, sensitive, never pre-checked). Added `displaySafe` for `.unknown` raw rendering on the sheet.
2. DI-M3 — signer-unavailable refuses. New `signedTag(for:)` / `isKeyAvailable()`; `MiniAppGrantStore.mutateLocked` throws `signingKeyUnavailable` BEFORE inspecting, so every row survives. `setGrant` signs outside the mutation. Reads keep default-deny. `ProjectLifecycleService` already surfaced the throw as a warning; `MiniAppLaunchView.save` upgraded from `try?` to a logged catch.
3. DI-H2 + L3 — `ScarfProject.extra` and `SessionProjectMap.extra` (`[String: JSONValue]` via `AnyCodingKey`), excluded from `ScarfProject`'s now hand-written Equatable/Hashable.
4. DI-M1 + M2 — `ProjectStore.inspectRecord` quarantines undecodable/oversize bytes through `GuardedJSONStore.quarantine` and reports `quarantined`; `save` passes `skipBackup:` so the good `.bak` survives. `GuardedJSONStore.write` skips the `.bak` refresh on a `.quarantined` predecessor. A FAILED quarantine still refreshes the `.bak` (the bytes would otherwise exist nowhere).
5. SEC-M4 — new `ImageHostConsentStore` (UserDefaults, per project root + normalized host; NOT agent-writable — every `~/.hermes` candidate is writable by the agent doing the asking). `ImageWidgetView` shows a naming placeholder + Allow button; nothing is fetched until pressed. Local images unaffected. Decision recorded.
6. SEC-L1 — `validNamePattern` → `\A[a-z][a-z0-9-]*\z`.
7. SEC-L2 — `TransportPrivateMode.originalBasename` strips `.bak` / `.corrupt-<stamp>` repeatedly before matching, so `.env.bak` and `.env.corrupt-*` are 0600 again.
8. SEC-L5 — `stripMemoryBlock` with a begin marker and no end marker strips NOTHING (logs + returns). The uninstall preview was corrected to match: it reports the block present only when BOTH markers are found.
9. t-05a7c23d — `KeychainEnvMirror` (`.env`) and `ProjectTemplateInstaller` (MEMORY.md, both preflight and append) go through `GuardedJSONStore`: stat-confirmed proof, refusal on undecodable UTF-8, one-deep `.bak`. New `KeychainEnvMirror.EnvMirrorError` and `ProjectTemplateError.memoryFileUnreadable/.memoryFileNotText`. `GuardedJSONStore.Inspection.init` made public so prose writers can reclassify zero-bytes as `.absent`.

Self-audit findings acted on: (a) `MiniAppLaunchView.save`'s `try?` would have swallowed the new refusal — now logged; (b) the uninstall preview would have promised a memory-block removal the SEC-L5 bound then refuses — fixed; (c) `writeRecord(replacing: nil)` re-reads, so the quarantine skip needed an explicit `skipBackup:` flag rather than passing nil.

Residuals, accepted and documented: image consent is host-level, so an allowed host can still be varied by path/query (URL-level would re-prompt on every legitimate image change and train click-through); an unrooted dashboard shares the `""` project bucket; `.env.bak` puts a second copy of secrets in the hermes home (0600, beside a file with the same secrets).

## Artifacts

Changed (11 source + 2 test files, all uncommitted on main):

ScarfCore:
- Services/MiniAppGrantSigner.swift — payload v2, signedTag/isKeyAvailable, MiniAppGrantSignerError, test seam
- Services/MiniAppGrantStore.swift — signer-unavailable refusal, sign-before-mutate
- Services/GuardedJSONStore.swift — no .bak refresh on a quarantined predecessor; public Inspection init
- Services/ProjectStore.swift — record quarantine parity + skipBackup
- Services/ImageHostConsentStore.swift (NEW)
- Models/ScarfProject.swift — extra + hand-written Equatable/Hashable
- Models/SessionProjectMap.swift — extra + custom Codable
- Models/MiniAppPermission.swift — query-kind charset gate, displaySafe
- Models/ProjectSlashCommand.swift — \A..\z
- Transport/TransportPrivateMode.swift — originalBasename

scarf app:
- Core/Services/KeychainEnvMirror.swift — guarded .env splice
- Core/Services/ProjectTemplateInstaller.swift — guarded MEMORY.md splice (preflight + append)
- Core/Services/ProjectTemplateUninstaller.swift — SEC-L5 bound + preview parity
- Core/Models/ProjectTemplate.swift — two new error cases
- Features/Projects/Views/Widgets/ImageWidgetView.swift — beacon consent gate
- Features/Projects/MiniApp/MiniAppLaunchView.swift — displaySafe + logged save failure

Tests (NEW):
- ScarfCore/Tests/ScarfCoreTests/ProjectsG2HardeningTests.swift — 13 tests: comma re-split refused + v1/v2 payload divergence, 0x1F in any field refused, tampered row inauthentic, signer-unavailable refusal preserves rows, query-kind demotion, display sanitization, ScarfProject + SessionProjectMap unknown-key round-trips, ScarfProject identity ignores extra, decode-failure quarantines bytes, .bak survives a quarantine cycle (both ProjectStore and GuardedJSONStore), .bak/.corrupt private mode, `deploy\n` rejected, image host gate
- scarfTests/ProjectsG2SpliceBoundsTests.swift — 7 tests: missing end marker strips nothing, well-formed block still strips, non-UTF-8 MEMORY.md refused, absent/empty MEMORY.md writable, non-UTF-8 .env refused and left intact, .env.bak written at 0600

Memory:
- edited scarf/decisions/integrity-is-not-authenticity-agent-writable-scarf-sidecars (payload v2 + refusal semantics)
- edited scarf/decisions/absent-vs-unreadable-is-the-discriminator-every-scarf-json (new G2 section; corrected the now-stale "SessionProjectMap does NOT preserve unknown keys")
- created scarf/decisions/remote-image-widgets-are-a-per-project-host-beacon-gate
- created scarf/conventions/validate-untrusted-names-with-a-z-anchors-and-gate-the

Follow-up filed as a background task: audit the remaining `^...$` validators (ProfilesViewModel, SkillInstallValidator, HermesProfileScope/Resolver) for the same ICU newline hole.

