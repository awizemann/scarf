---
title: Sparkle Key Recovery
type: note
permalink: scarf/ops/sparkle-key-recovery
tags: [release, sparkle, signing, gotcha, setup]
source_paths: [scripts/release.sh, scarf/scarf/Info.plist]
source_paths_inferred: false
source_sha: 20f286c14389245de47c0c93a461d7bcc3a002d6
created: 2026-06-06
updated: 2026-06-06
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

## Observations
- [canonical-pubkey] The production Sparkle EdDSA public key embedded in every shipped Scarf binary's `Info.plist:SUPublicEDKey` is `sxHR0OGLmx9I4Fyx1GdPANR9WUiVAz/rI38x3cLYnMU=`. Every Sparkle auto-update on any installed copy of Scarf will only accept appcast `sparkle:edSignature` values produced by the matching private key. Lose that private key and every existing install is permanently orphaned from auto-updates — a `SUPublicEDKey` rotation cannot reach them because they verify against the OLD baked-in pubkey #key
- [per-machine] The private key lives in the macOS login Keychain as a generic-password item with service `https://sparkle-project.org`, account `ed25519`. Keychain items are per-machine and do NOT sync via iCloud Keychain by default (Sparkle's `generate_keys` does not opt in). On a fresh release machine, if you run `generate_keys` instead of importing, you get a brand-new keypair whose public key does NOT match the embedded `SUPublicEDKey` — releases will sign cleanly but no installed Sparkle will accept them. v2.10.2 (2026-06-05) shipped this way and had to be re-signed #setup #gotcha
- [self-documenting] Sparkle's `generate_keys` writes the corresponding **public** key into the Keychain item's comment field (`icmt`): `"Public key (SUPublicEDKey value) for this key is:\n\n<base64>"`. The `release.sh` preflight reads this back via `security find-generic-password ... -g | grep '"icmt"' | grep -oE '[A-Za-z0-9+/]{43}='` and compares it to `Info.plist:SUPublicEDKey`. Mismatch → `die` before any state mutation #fix
- [export-from-old-machine] On the machine that already has the production keypair: `security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w` prints the base64 private key (prompts for Keychain unlock). Verify it's the right one first: `security find-generic-password -s "https://sparkle-project.org" -g 2>&1 | grep -i 'public key'` should mention `sxHR0OGLmx9I4Fyx1GdPANR9WUiVAz/rI38x3cLYnMU=` #recovery
- [import-on-new-machine] On a fresh release machine, first delete any auto-generated key (`security delete-generic-password -s "https://sparkle-project.org" -a ed25519` — precedence is order-dependent if duplicates exist), then import the production key with the public-key comment populated and `sign_update` pre-authorized:
    ```
    security add-generic-password \
      -s "https://sparkle-project.org" -a ed25519 \
      -j "Public key (SUPublicEDKey value) for this key is:

    sxHR0OGLmx9I4Fyx1GdPANR9WUiVAz/rI38x3cLYnMU=" \
      -D "private key" \
      -T "$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f -perm +111 | grep -v old_dsa | head -1)" \
      -w
    ```
    The `-w` with no value triggers an interactive prompt; paste the base64 from the source machine. Never put the private key on a command line — it lands in shell history. #recovery #setup
- [transfer-channel] Move the base64 private key between machines via 1Password (Secure Note) or AirDrop of an encrypted file. NOT email, NOT Slack, NOT pasted into a Claude transcript — `sign_update` reads the key from the Keychain itself, no human needs to see it after import #security
- [preflight-guard] [scripts/release.sh] now refuses to run if `Info.plist:SUPublicEDKey` doesn't match the Keychain item's comment-field pubkey. So a future "release from a fresh machine" will fail loudly at the preflight stage, BEFORE touching git or building anything. The `die` message points the operator back here #fix
- [postflight-guard] After `sign_update` runs, [scripts/release.sh] also base64-decodes `ED_SIGNATURE` and asserts it's exactly 64 bytes (Ed25519 signature size). Catches "sign_update returned something but it's malformed" — e.g. multiple matching Keychain items causing surprising output #fix
- [incident-history] v2.10.0 (2026-05-29) and v2.10.1 (2026-06-04) were released from the canonical key-holding Mac. v2.10.2 (2026-06-05) was released from a different Mac whose Keychain held an auto-generated keypair with public key `aDXuHMvJGmDbk8yKrDtd8QVu724nq5GsBTvxBQmEOqE=` — wrong. Every installed user trying to update from v2.10.1 → v2.10.2 got "signing was incorrect". Recovered same-day: §1 reverted the appcast (gh-pages commit `f37058d`), §2 imported the production key onto the fresh machine, §3 re-signed the existing v2.10.2 zip and republished the appcast (commit `8b57b46`). The v2.10.2 GitHub release ZIP itself was always valid (Developer-ID signed + notarized); only the Sparkle EdDSA appcast signature was wrong #incident

## Relations
- referenced_by [[Build and Release Workflow]]
- referenced_by [[Release Distribution and Updates]]
- referenced_by [[Releases under iCloud Drive]]
