---
title: ScarfGo-Onboarding
type: note
permalink: scarf-wiki/scarf-go-onboarding
created: 2026-05-29
updated: 2026-05-29
---

# ScarfGo Onboarding & SSH Keys

ScarfGo connects to a Hermes server you operate over SSH. There's no Scarf-controlled cloud account — your iPhone holds an SSH key, your Hermes host trusts that key, and that's the entire trust relationship. This page walks through the onboarding flow step by step and explains what to do if the connection test fails.

## What you'll need

- An iPhone running iOS 18 or later.
- A Hermes-running host you can reach over SSH from your phone's network. Mac, a Linux box at home, a Tailscale node, a cloud VM — anything that `ssh user@host` works against from a regular machine.
- The host running Hermes v0.10.0 or later (v0.11.0 recommended for full v2.5 feature parity — see [Hermes Version Compatibility](Hermes-Version-Compatibility)).
- A way to paste a single line of text into a file on that host. Usually `ssh user@host` from another machine and editing `~/.ssh/authorized_keys`. If you're already running [Scarf](Home) on Mac, you have this.

ScarfGo never asks for your account password. It also never holds an Apple-side cloud token — there's no "sign in with Scarf" anywhere.

## The flow at a glance

1. Server details (hostname, user, port, optional nickname)
2. Choose: generate a new SSH key, or import one you already have
3. Generate (or paste) the keypair — the private half lives in the iOS Keychain (device-local by default; opt-in iCloud Keychain sync from System → Security as of v2.5.1)
4. Show the public key — copy and paste it into `~/.ssh/authorized_keys` on the host
5. Test connection — ScarfGo SSHes in, looks for the `hermes` binary, saves on success

The whole thing takes about a minute once you have shell access to the host.

## Step-by-step

### 1. Server details

Tap **Add Server**. Fill in:

- **Host** — IP or DNS of the Hermes host. `192.168.1.50`, `myhost.local`, `tailscale-name.tailnet-xyz.ts.net`, anything `ssh` would accept.
- **User** — the SSH user. Often the same login you `ssh user@host` with from your terminal.
- **Port** — defaults to 22. Override if your host uses a non-standard SSH port.
- **Nickname (optional)** — display name in ScarfGo. Defaults to `user@host`.
- **Hermes binary hint (optional)** — leave empty unless you know `hermes` is at an unusual path. ScarfGo prepends `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin` to PATH automatically — those three cover ~95% of pipx + Homebrew installs. If your `hermes` lives elsewhere (custom virtualenv, system-managed install dir like `~/.hermes/bin`), set the hint to its absolute path.

Tap **Next**.

### 2. Choose: generate or import

- **Generate a new key** — recommended for most users. ScarfGo creates a fresh Ed25519 keypair on-device. This is the right choice unless you have a specific reason to reuse an existing key.
- **Import existing key** — paste a private + public key pair. Only useful if you already have an Ed25519 key you want to reuse (e.g. for ssh-agent compat). Note that iOS won't let you reuse `id_ed25519` from your Mac — it has to be specifically allowed on the Hermes host's `authorized_keys`.

### 3. Generate (or paste) the keypair

If generating: ScarfGo runs `CitadelSSHService.generateEd25519Key()` (pure-Swift, no `ssh-keygen`). About a second.

If importing: paste the private-key PEM in the top box and the matching public-key line in the bottom box. ScarfGo validates the pair before accepting.

Either way, the private half is stored in the iOS Keychain with these attributes:

- **Service:** `com.scarf.ssh-key`
- **Account:** `server-key:<UUID>` (one entry per configured server)
- **Accessibility (default):** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + `kSecAttrSynchronizable=false`. Key unreachable while the device is locked, doesn't leave the device, survives passcode changes. Pre-v2.5.1 this was the only mode.
- **Accessibility (opt-in, v2.5.1+):** `kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable=true`. Toggle from System → Security → "Sync SSH key with iCloud Keychain". The Keychain entry now syncs across signed-in Apple devices, end-to-end encrypted by iCloud Keychain (with Advanced Data Protection enabled, the encryption keys never leave your devices). Adding a second device no longer requires generating a fresh key — install ScarfGo, sign in to the same Apple ID with iCloud Keychain enabled, the same key shows up.

If you ever delete the app, iOS purges its Keychain group; for synced items, iCloud Keychain mirrors the deletion across devices.

### 4. Show the public key — paste into authorized_keys

ScarfGo displays the public-key line in a monospaced selectable box, with a Copy button.

Tap **Copy public key**. Now go to your Hermes host (in another shell) and append it:

```bash
cat >> ~/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3...the-line-ScarfGo-showed-you... scarf-ios-<device-name>
EOF
chmod 600 ~/.ssh/authorized_keys
chmod 700 ~/.ssh
```

This is its own line per device — the convention any second SSH client uses. Mac's Scarf keeps using your existing ssh-agent / `~/.ssh/config` and is unaffected.

If `~/.ssh` doesn't exist yet on the host, create it: `mkdir -p ~/.ssh && chmod 700 ~/.ssh` first.

Back in ScarfGo, tap **I've added this key**.

### 5. Test connection

ScarfGo opens an SSH session, runs a single probe (`echo $HOME && which hermes`), and if both succeed, saves the server. Expect a 2–4 second wait.

If the probe succeeds you land on the Dashboard tab. **Done.**

If it fails, see [Troubleshooting](#troubleshooting) below.

## Multiple servers

Same flow per server. The Servers list (under the **System** tab) shows every configured host with a connection-status pill. Tap any row to switch contexts; long-press for **Forget this server**, which deletes the Keychain key + UserDefaults entry for that one server (other servers are untouched).

Each server holds its own keypair — there's no "primary key" anymore as of v2.5. (v1 builds had a `"primary"` Keychain account; v2 multi-server format auto-migrates the moment you `listAll`.)

## Troubleshooting

### "command not found" or "hermes: not found"

Citadel's raw exec channel doesn't source the user's shell rc files (`.bashrc`, `.zshrc`, `.profile`). Non-interactive SSH sessions on most Linux distros land with `PATH=/usr/bin:/bin`. pipx installs `hermes` at `~/.local/bin/hermes` and Homebrew at `/opt/homebrew/bin` — neither of which are on the bare PATH.

**v2.5 inline-prepends** `PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"` on every `runProcess` call, so the four common install locations resolve automatically. If you still see "command not found":

1. SSH to the host yourself and run `which hermes`. Note the absolute path.
2. In ScarfGo: **Servers → tap the server → Edit → Hermes binary hint** → paste the absolute path (e.g. `/opt/scarf-tools/bin/hermes`).
3. Re-test the connection.

The inline PATH covers `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`. Anything else — including `~/.hermes/bin` self-install layouts — needs the binary-hint override.

### "Connection refused" / "Connection timed out"

Network can't reach the host. Check:

- Same Wi-Fi as the host? Verify with another tool (Files app, browsing a web service on the host).
- Tailscale / VPN? Make sure it's connected on the phone.
- Firewall on the host? `sudo ufw status` on Linux; **System Settings → Network → Firewall** on macOS.
- Custom SSH port? Confirm in ScarfGo's server-edit screen.

If `ssh user@host` from another device on the same network also fails, fix that first — ScarfGo can't connect to a host you can't ssh to.

### "Authentication failed" / "Permission denied (publickey)"

The public key you copied into `authorized_keys` doesn't match what ScarfGo is offering. Common causes:

- **You pasted the wrong line.** Tap **Show public key** again in ScarfGo and re-copy. Compare line-for-line against what's in `~/.ssh/authorized_keys`.
- **`authorized_keys` permissions are wrong.** Run `chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh` on the host. SSH refuses to read `authorized_keys` if it's group-writable.
- **You appended after a line without a trailing newline.** `cat >>` should add the newline; if you used a text editor and saved without a final newline, the new line gets glued to the old one. Fix with `echo "" >> ~/.ssh/authorized_keys` then re-paste.
- **The host's `sshd` config disabled key auth.** Run `sshd -T 2>/dev/null | grep pubkeyauth` — should be `yes`.

### "Host key verification failed"

ScarfGo strict-checks SSH host keys. If the host's key changed (new install, MITM unlikely but possible), use **Servers → Forget this server** and re-onboard — Citadel will accept the new host key on first connect.

### Onboarding succeeds but Dashboard shows zero sessions

ScarfGo downloads a snapshot of `~/.hermes/state.db` over SFTP. If your Hermes install hasn't yet written the DB (no sessions ever started), the snapshot is empty. Start a session via the Mac app or `hermes chat` first, then pull-to-refresh the Dashboard.

### "Memory says 'Save failed' silently"

Pull-to-refresh — usually a transient SFTP hiccup. If it persists, check the SSH user has write permission on `~/.hermes/memories/`.

### Biometric / passcode prompt loops

Cancelling Face ID or the device passcode prompt no longer drops you back into onboarding (v2.5 fix). If it happens, the app surfaces a banner on the server list with a Dismiss button — re-tap the server to retry the unlock.

## Privacy and key handling — quick recap

- **iCloud sync is opt-in (v2.5.1+).** Default is device-local — keys are marked `ThisDeviceOnly` and excluded from iCloud Keychain unless you enable the System → Security toggle. With it on, the key syncs end-to-end encrypted via iCloud Keychain (Advanced Data Protection makes the encryption keys client-side only).
- **No cloud accounts.** Scarf has no developer-controlled server. Your iPhone connects directly to your Hermes host over SSH.
- **No analytics.** ScarfGo doesn't transmit any data to any third party.
- **One key per device — unless you opt into sync.** Default behavior: adding a second device means a second `authorized_keys` line. With iCloud Keychain sync enabled, the same key appears on every signed-in Apple device with iCloud Keychain on, so a single `authorized_keys` line covers all of them.

Full policy: [Privacy Policy](Privacy-Policy).

## Related pages

- [ScarfGo](ScarfGo) — feature tour, FAQs, limitations.
- [Platform Differences](Platform-Differences) — Mac vs iOS feature matrix.
- [Hermes Version Compatibility](Hermes-Version-Compatibility) — what's required on the host.
- [Servers & Remote](Servers-and-Remote) — Mac equivalent for adding remote Hermes hosts.
- [Support](Support) — bug reports, feature requests, security disclosures.

---
_Last updated: 2026-04-27 — Scarf v2.5.1 (opt-in iCloud Keychain sync for SSH keys)_