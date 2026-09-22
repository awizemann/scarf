---
title: Integrity is not authenticity: agent-writable Scarf sidecars need a Keychain-held MAC
type: note
permalink: scarf/decisions/integrity-is-not-authenticity-agent-writable-scarf-sidecars
tags: [security, projects, miniapps, keychain]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppGrantSigner.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppGrantStore.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedJSONStore.swift]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-09-04
updated: 2026-09-08
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

S2 (t-a2c169f0) closed the gap D1 left open. `GuardedJSONStore` made
`miniapp_grants.json` safe from Scarf's OWN read failures — salvage,
quarantine, refusal, `.bak`. It says nothing about WHO wrote the bytes, and
the file sits in `~/.hermes/scarf/`, which every agent Hermes runs can write.
The manifest fingerprint a grant records is computed from the mini-app's own
`miniapp.json`, so an agent could write the manifest, compute its
fingerprint, append a matching grant, and walk through the
trust-on-first-use gate with no permission sheet ever appearing.

Same shape one layer up: `MiniAppManifest.generated` is a self-declared bool
that defaults to FALSE when absent, and it keyed the consent sheet's
defaults — omit the key and the sensitive boxes opened pre-ticked, one
default-action Return from granted.

## Observations
- [decision] Each grant row carries an HMAC-SHA256 tag over its own fields (payload v2: literal "v2", projectId, miniAppId, permissions, decidedAt, fingerprint, 0x1F-separated), keyed by a 32-byte secret minted on first use into the login Keychain at com.scarf.miniapp-grants/hmac-key-v1 #security
- [gotcha] v1 comma-JOINED the permissions field, which is not injective when a member can itself contain a comma — `query:sessions,store` (one approved permission) produced the same payload and the same valid tag as `{query:sessions, store}`, minting an unapproved `store` grant under Scarf's own signature. v2 length-prefixes each permission as `<utf8 byte count>:<permission>` and REFUSES any component holding 0x1F or a comma at sign time; v1 tags don't verify, so the bump re-asks every grant exactly once (P8 SEC-M2) #security
- [decision] Unsigned or mis-signed rows are DROPPED at load, never refused — a dropped grant is default-deny plus a permission sheet (a recovery), while refusing would freeze every legitimate write behind one forged row the agent can re-add at will #security
- [decision] Per-row rather than per-file MAC: a whole-file signature would let one forged row invalidate every honest decision the user made #security
- [constraint] The key is per-machine, so grants another Mac wrote into a shared remote ~/.hermes verify as unsigned and are re-asked here — correct, since a consent decision belongs to a person at a machine; a Keychain that will not hand over the key means re-ask on READ, never grant #gotcha
- [decision] Signer-unavailable is a REFUSAL on the write path, not a filter (P8 DI-M3): a signer with no key calls every stored row inauthentic, so `mutate` used to publish that empty list and permanently delete every decision on the machine. `MiniAppGrantStore.mutateLocked` now throws `MiniAppGrantSignerError.signingKeyUnavailable` before inspecting. Dropping on read is a recovery; dropping on write is not #security
- [decision] A self-declared attribute can never key a security default: MiniAppManifest.generated no longer gates the consent sheet (sensitive permissions are off for EVERYONE) and survives only as a label, where a false claim can only make an app look less safe than it is treated #security

## The third borrower: per-project auto-accept edits (t-05f33e75)

The per-project "auto-accept edits" setting sends `session/set_mode
accept_edits` at chat-session boot, i.e. it REMOVES the per-edit approval
prompt — and the party that prompt guards the user from is the agent. So the
same reasoning applies a third time, and `ProjectAutoAcceptEditsStore` reuses
the same machine key rather than minting another.

- [decision] The per-project auto-accept-edits flag is NOT stored in `.scarf/`, the manifest, or the projects registry — all agent-writable, so the asker could grant itself the answer. It lives in `UserDefaults` (`com.scarf.project.autoAcceptEdits.<projectPath>`), HMAC-tagged via `MiniAppGrantSigner.tag(forPayload:)` over `("scarf-auto-accept-edits-v1", projectId, "on")` #security
- [decision] "Off" is the ABSENCE of a record, never a stored `off` — a stored negative would be something an attacker could delete to flip the setting on, while a missing key already means off. Turning it off needs no key and can never be blocked by a locked Keychain (a revocation must not depend on the environment) #security
- [constraint] `defaults write <bundle> com.scarf.project.autoAcceptEdits./p/x on` — the obvious agent move, since the agent has a terminal — reads back as OFF: untagged, so ignored, so the prompts stay. Covered end-to-end by `forgedSettingRecordNeverReachesTheWire` (the record never reaches `session/set_mode`) #security
- [gotcha] The tag binds the project PATH, not a project identity — the same residual `ImageHostConsentStore` carries. A blessed path that later holds a different repo inherits the blessing; the payload is composed so a stable uuid can replace the id without a format change #security
- [constraint] Scarf only chooses the OPENING posture — enforcement stays entirely Hermes-side, so sensitive paths still prompt exactly as they do when the mode is flipped by hand from the chat header. Gated on `hasSessionEditAutoApproval` (v0.15+); a pre-0.15 host sends no RPC at all (C1) #hermes

## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[Phase-1 Milestone 2: Mini-apps — implementation decisions]]
- relates_to [[Uninstall + keychain trust boundaries: re-derive at time-of-use (S1)]]


- [decision] A SELF-HEALING repair of an agent-owned sidecar gets a LOG LINE, not UI, when all three hold: nothing is lost (every foreign key survives the overlay), the BROKEN state was already surfaced through an existing channel, and reporting the repair afterwards would need persisted state. `ProjectManifestStore`'s wrong-shaped-`manifest.json` overlay (GW-F6) is the worked case: Project Doctor already reports it as a `malformedSidecar` finding from the moment the bad file lands and BEFORE any preset binding touches it, and after the repair the file decodes so the doctor correctly finds nothing — saying "this was repaired" there would take a repair marker with its own lifecycle and staleness. The log names the keys it wrote, kept and replaced so a console read reconstructs the before-state. Test the FIRST condition before reaching for this: a repair that drops anything is not self-healing and does owe the user a notice. (2026-09-08, `scarf/scarf/Core/Services/ProjectManifestStore.swift`) #decision #gotcha
