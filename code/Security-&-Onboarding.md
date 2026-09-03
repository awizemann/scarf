---
created: 2026-09-03
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/Packages/ScarfCore/Sources/ScarfCore/Security, scarf/Scarf iOS/Onboarding
source_paths_inferred: false
---

# Security & Onboarding — SSH Keys, Keychain, and Connection Testing

Scarf's security model is **SSH-key based**. Users generate an Ed25519 private key, store it in their Keychain (macOS) or iOS Keychain (iPhone), and authorize Scarf to read it for authentication.

## Onboarding State Machine

`OnboardingLogic` (`ScarfCore/Security/OnboardingState.swift:54`) is the client-side onboarding flow:
1. **Server Details** — User enters hostname, SSH port, username.
2. **Key Source** — User chooses generate (on-device) or import (paste existing public key).
3. **Key Generation** — Generate a new Ed25519 key pair (macOS via Security framework, iOS via `Ed25519KeyGenerator`).
4. **Public Key Display** — Show the public key for the user to paste into `~/.ssh/authorized_keys` on the host.
5. **Test Connection** — Scarf connects via SSH to verify the key works.
6. **Connected** — Add the server to the registry.

`OnboardingViewModel` (`ScarfCore/Security/OnboardingViewModel.swift:14`) drives the state machine with user inputs.

## SSH Key Storage

**macOS** — Keys are stored in the system Keychain via `Security.framework`. No plaintext on disk.

**iOS (ScarfGo)** — Keys are stored in the iOS Keychain, also via `Security.framework`. Each server entry has its own key; onboarding calls `SSHKeyStore.save(_:for: entryID)` per server.

**Runtime key resolution** — On iOS, `KeychainSSHKeyStore.load()` retrieves the key from the Keychain for the current server. A prior bug loaded a singleton key globally, causing the wrong key to be used on multi-server setups. [[ios-runtime-ssh-keys-must-resolve-per-server-entry]]

## Connection Testing

`SSHConnectionTester` (ScarfCore/Security/SSHConnectionTester.swift:12`) is a protocol for testing SSH connectivity. Implementations:
- **macOS** — `ACPClient` itself can test (spawns `hermes version` and times out at 10 seconds).
- **iOS** — `CitadelSSHService` (scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelSSHService.swift:32`) uses Citadel to open a connection and close it.

## Config Validation

`OnboardingServerDetailsValidation` (ScarfCore/Security/OnboardingState.swift:40`) validates user inputs:
- Hostname not empty.
- Port is numeric, 1–65535.
- Username not empty.
- SSH key is readable.

## Keychain Contracts

**macOS & iOS both use `Security.SecItem` API** — No plaintext secrets in files. Credentials live in the OS Keychain with appropriate access controls.

**Secrets in chat/code** — Never. If Scarf reads a secret from Hermes (API keys, tokens), it's read-only for display; never echoed to the user or logged. Scarf's own SSH key is stored only in Keychain, never in environment or argv.

[[store-cancellable-handles-for-off-main-remote-work]] — Onboarding ViewModels store connection-test Task handles and cancel them if the user navigates away.

## iOS Onboarding UI

`OnboardingRootView` (`scarf/Scarf iOS/Onboarding/OnboardingRootView.swift:19`) walks the user through each step:
- Server details sheet.
- Key-source picker (generate vs. import).
- Key generation progress indicator.
- Public key display with copy button.
- Connection test with retry.
- Success feedback.

Each step is a separate `View` in the file; the root coordinates navigation via `@State var step: OnboardingStep`.

## Testing Onboarding

`OnboardingViewModel` accepts an injected `SSHConnectionTester` (default: live, test: mock). Mock testers return synthetic success/failure for deterministic testing.

## Error Messaging

Connection failures surface `SSHConnectionTestError` variants to the user:
- `.timeout` — "Connection timed out; check the hostname and network."
- `.authenticationFailed` — "SSH key not authorized on the server; paste the public key into ~/.ssh/authorized_keys."
- `.networkUnreachable` — "Network is unreachable; check your internet connection."
- `.unknownHostKey` — "Unknown host key; the server's SSH key is not in ~/.ssh/known_hosts."

User-facing copy is localized; technical details are logged.