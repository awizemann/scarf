# ScarfGo — App Store Review Access Packet

_Updated 2026-11-01: the server was replaced (the old 1 GB droplet is destroyed), and the same
review keypair is authorized on the new one. Provisioned and checked through the review key
over non-login SSH. The private key is in the Memophant vault `scarfgo-appstore-review-sshkey`;
the `documents/` tier's secret scanner blocks a raw private key, so it is NOT inlined here. The
old companion file `review-kit/asc-review-notes.txt` was session scratch and no longer exists:
build the Notes from the block below, adding the full key from the vault._

---

## The one thing to understand

ScarfGo is a **remote-control client for a self-hosted "Hermes" AI agent**. The iPhone
connects to a Linux host **over SSH** (direct TCP, pure-Swift Citadel). There is **no
standalone / demo / offline mode** — every screen reads live data from the host. So the
reviewer must be given a live server + a pre-authorized SSH key. We provisioned a dedicated
DigitalOcean droplet; it stays online through review, then gets destroyed.

- Test server (throwaway): DigitalOcean droplet, public IP **104.248.216.194**, SSH port **22**
- Review SSH user: **scarfreview** (unprivileged; only the review key is authorized)
- The review key must NOT be in root's `authorized_keys`: these notes hand the private key to the reviewer, and logging in as root shows empty data ("Pick a model", `/root/.hermes/state.db`).
- Size: 1 vCPU, 2 GB memory + 2 GB swap, 48 GB disk. Hermes v0.22.5, from its own installer.
- Model: OpenRouter `openai/gpt-4o-mini` (OpenAI-compatible) — verified answering live

---

## App Store Connect → App Review Information

- **Sign-In required:** No (there is no account/login; access is via the SSH key below).
- **Notes:** paste the block below, with the full private key from the vault in place of the
  abbreviated one.

The Notes content (the private key is abbreviated here: take it from the vault):

```
ScarfGo is a remote-control client for a self-hosted "Hermes" AI agent and requires an SSH
connection to a server to function. There is no account or login, and no standalone/offline
mode. We have provisioned a dedicated test server that will remain online for the entire review.

TO CONNECT:
1. Launch ScarfGo. On the first screen ("Connect to Hermes") enter:
   - Host: 104.248.216.194
   - Port: 22
   - Username: scarfreview
   (nickname optional). Tap Next.
2. On the "SSH key" screen, tap "Import existing key".
3. Paste the PRIVATE KEY (below) into the first box ("Paste your private key").
4. Paste the PUBLIC KEY LINE (below) into the second box ("Paste the matching public-key line").
5. Tap Import. The app tests the connection and lands on the Dashboard.

WHAT TO TEST: after connecting, open every tab — Dashboard, Projects, Chat (send a message;
the agent replies), Skills, and System (Memory, Cron, Plugins, Webhooks, Profiles, Settings).
All contain seeded content.

The app executes nothing on the iOS device; it only sends commands to this server, which we
own and administer. No external hardware is required.

PUBLIC KEY LINE:
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIZuedMOrj5y8wJqyy7x0sUHiBH1JPFtRWH3KBtJp8Ws scarfgo-appstore-review

PRIVATE KEY:
-----BEGIN OPENSSH PRIVATE KEY-----
   … full key in the vault entry scarfgo-appstore-review-sshkey …
-----END OPENSSH PRIVATE KEY-----
```

---

## Seeded surfaces — verified through the reviewer's key (non-login SSH)

| Tab | Verified |
|-----|----------|
| Dashboard | Gateway running (boot-time systemd service) |
| Projects | `Demo Project` (1 folder) |
| Chat | Live OpenRouter reply + a resumable session |
| Skills | `gitnexus-explorer` + builtins (seed attempted; confirm it shows in ScarfGo) |
| System → Cron | `demo-daily-summary` [active] |
| System → Profiles | `review-secondary` profile present |
| System → Settings | Reads config.yaml automatically |

---

## Also required for THIS submission (build fixes — done, compiled clean)

- Added `PrivacyInfo.xcprivacy` (UserDefaults `CA92.1`, tracking=false).
- Removed phantom push: `UIBackgroundModes` (Info.plist) + `aps-environment` (entitlements).
- Set `ITSAppUsesNonExemptEncryption = true`; added `NSLocalNetworkUsageDescription`.
- `** BUILD SUCCEEDED **`; the privacy manifest bundles into `scarf mobile.app`.

---

## Server hygiene / teardown

- 2 GB droplet: the earlier 1 GB box ran out of disk and memory on v0.22.5 (`hermes acp` 166 MB, gateway 276 MB).
- OpenRouter key should be spend-capped before submitting.
- Do NOT IP-allowlist SSH — Apple review originates from variable IPs. Keep port 22 open for
  the review window.
- After approval: destroy the droplet (`doctl compute droplet delete <id>` or the DO console)
  and rotate the OpenRouter key.
