# ScarfGo — App Store Review Access Packet

_Updated 2026-08-14. Server provisioned and verified end-to-end through the reviewer's own
key (non-login SSH). The **verbatim, copy-paste-ready App Review Notes** — including the
private key — live in the companion file `review-kit/asc-review-notes.txt` (the `documents/`
tier's secret scanner blocks a raw private key, so it is intentionally NOT inlined here). The
private key is also in the Memophant vault `scarfgo-appstore-review-sshkey`._

---

## The one thing to understand

ScarfGo is a **remote-control client for a self-hosted "Hermes" AI agent**. The iPhone
connects to a Linux host **over SSH** (direct TCP, pure-Swift Citadel). There is **no
standalone / demo / offline mode** — every screen reads live data from the host. So the
reviewer must be given a live server + a pre-authorized SSH key. We provisioned a dedicated
DigitalOcean droplet; it stays online through review, then gets destroyed.

- Test server (throwaway): DigitalOcean droplet, public IP **24.199.89.183**, SSH port **22**
- Review SSH user: **scarfreview** (unprivileged; only the review key is authorized)
- Model: OpenRouter `openai/gpt-4o-mini` (OpenAI-compatible) — verified answering live

---

## App Store Connect → App Review Information

- **Sign-In required:** No (there is no account/login; access is via the SSH key below).
- **Notes:** paste the **entire contents of `review-kit/asc-review-notes.txt`** verbatim.
  That file is the exact text, with the public-key line and private key already inlined.

The Notes content (key blocks abbreviated here — the paste file has them in full):

```
ScarfGo is a remote-control client for a self-hosted "Hermes" AI agent and requires an SSH
connection to a server to function. There is no account or login, and no standalone/offline
mode. We have provisioned a dedicated test server that will remain online for the entire review.

TO CONNECT:
1. Launch ScarfGo. On the first screen ("Connect to Hermes") enter:
   - Host: 24.199.89.183
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
   … full key in review-kit/asc-review-notes.txt …
-----END OPENSSH PRIVATE KEY-----
```

---

## Seeded surfaces — verified through the reviewer's key (non-login SSH)

| Tab | Verified |
|-----|----------|
| Dashboard | Gateway running (boot-time systemd service) |
| Projects | `Demo Project` (1 folder) |
| Chat | Live OpenRouter reply + a resumable session |
| Skills | `git` (skills.sh) + builtins, enabled |
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

- Droplet resized to 1 GB; gateway idles ~112 MB, model is remote — fine for review load.
- OpenRouter key should be spend-capped before submitting.
- Do NOT IP-allowlist SSH — Apple review originates from variable IPs. Keep port 22 open for
  the review window.
- After approval: destroy the droplet (`doctl compute droplet delete <id>` or the DO console)
  and rotate the OpenRouter key.
