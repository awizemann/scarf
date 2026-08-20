---
id: t-a89ccf7a
title: R4 [iOS]: Key import gate — reject unusable keys at paste time
status: todo
added: 2026-08-20
---

## Description

OnboardingState.isLikelyValidOpenSSHPrivateKey (OnboardingState.swift:99-106) checks only BEGIN/END bookends, so RSA/ECDSA and passphrase-protected ed25519 keys import "successfully", persist to Keychain, and fail only at connect (opensshParseFailed) with the bad key stuck. The decoder supports unencrypted ed25519 only (SSHPrivateKeyDecoding.swift:57-64). Fix: run the actual decoder (or a cheap type+encryption sniff of the openssh-key-v1 header) at import; reject with a clear message ("only unencrypted ed25519 supported; decrypt with ssh-keygen -p …"); also verify the pasted public key matches the private key before showing the authorized_keys line (OnboardingViewModel.swift:122-160). Hygiene: add .autocorrectionDisabled/.textInputAutocapitalization(.never) to the private-key TextEditor (OnboardingRootView.swift:212) and clear importPEM after successful import. Evidence: release audit findings 6+9b.

## Plan



## Artifacts



