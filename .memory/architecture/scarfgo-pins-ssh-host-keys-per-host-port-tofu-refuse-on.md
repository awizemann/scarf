---
title: ScarfGo pins SSH host keys per host+port (TOFU, refuse on change)
type: note
permalink: scarf/architecture/scarfgo-pins-ssh-host-keys-per-host-port-tofu-refuse-on
tags: [ios, ssh, security, host-key]
source_paths: [scarf/Packages/ScarfIOS/Sources/ScarfIOS/HostKeyPinning.swift, scarf/Packages/ScarfIOS/Sources/ScarfIOS/PinnedHostKeyValidator.swift, scarf/Scarf iOS/Servers/HostKeyViews.swift, scarf/Scarf iOS/App/ScarfIOSApp.swift]
source_paths_inferred: false
source_sha: 6a70442921e0191e57a567cd66d0925df87ecbb5
created: 2026-10-05
updated: 2026-10-05
---

ScarfGo used Citadel's `.acceptAnything()` until 2026-10-05. It now matches the Mac's StrictHostKeyChecking=accept-new: the first connect pins silently, and a changed key is refused until the user re-trusts it in the System tab.

## Observations
- [invariant] Every ScarfGo Citadel connect goes through `PinnedSSHConnect.connect` with `PinnedHostKeyValidator` (transport ConnectionHolder.openSSH, ACPClient+iOS openSSHClient, CitadelSSHService probe); never construct SSHClientSettings with `.acceptAnything()` again #ssh
- [decision] Pins are keyed by endpoint (lowercased host + port, known_hosts spelling `[host]:port`), NOT ServerID: runtime ServerContexts use fixed per-view context ids (ChatView.sharedContextID etc.) and onboarding probes before the entry exists. Host/port change = new endpoint = fresh pin; RootModel prunes pins no server entry uses (launch, forget, onboarding finish; removeAll on full sign-out) #host-key
- [fact] HostKeyPinStore: UserDefaults key `com.scarf.ios.host-key-pins.v1`, JSON {storageKey: {endpoint, pinned{openSSHKey, fingerprint, seenAt}, rejected?}}; sync NSLock API because NIO calls the validator on an event loop; UI uses the *OffMain wrappers and didChangeNotification #ios
- [fact] A mismatch throws `HostKeyMismatchError` (endpoint, expected + presented `SHA256:` fingerprints) unwrapped from transport and ACP; Test Connection maps it to SSHConnectionTestError.hostKeyMismatch. The presented key is stored as `rejected`; `trustRejectedKey(for:expectedFingerprint:)` only trusts the exact key the user was shown #ssh
- [howto] Live proof: scripts/verify-ios-host-key-pinning.sh (ephemeral sshd, swaps host key mid-test, exercises all three funnels). Live tests must pass an isolated HostKeyPinStore — verify scripts mint a fresh host key each run #testing

- [invariant] Never retry a HostKeyMismatchError: SSHConnectPolicy retries only timeouts, PinnedSSHConnect rethrows the recorded mismatch inside the policy loop, and ChatController's reconnect ladder breaks out to `.failed(mismatch.localizedDescription)` #ssh
- [invariant] "Trust New Key" captures the presented fingerprint at first tap and passes THAT to trustRejectedKey; if the server presented another key meanwhile the store refuses and the card says so (B-then-C test in HostKeyPinningTests) #host-key
- [gotcha] Any `UserDefaults(suiteName:)` in a test leaves a plist in ~/Library/Preferences even after removePersistentDomain + deleting the file (cfprefsd rewrites it). Host-key tests use `HostKeyPinStore(backing: InMemoryHostKeyPinBacking())`; the one real-UserDefaults test uses a unique key in `.standard` and removes it #testing
- [fact] A damaged pins blob is copied to `com.scarf.ios.host-key-pins.v1.corrupt-<unix time>` before rewrite and decoded per record, so one bad entry drops alone (that endpoint re-pins on first use) #ios


## Relations
- relates_to [[ScarfGo iOS Companion App]]
- relates_to [[iOS transport must be pooled per (ServerID, SSHConfig) — un-pooled makeTransport churns SSH connections]]
