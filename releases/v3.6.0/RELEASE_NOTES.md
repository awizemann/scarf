# Scarf v3.6.0

This release is about trust and readability. **ScarfGo now checks the identity of every server it connects to**, closing a gap where it would have accepted a server pretending to be yours. Both apps got a contrast pass so buttons, status text and warnings are readable in light and dark mode. The privacy policy and the in-app privacy text were rewritten to match exactly what the code does, which means Live Voice will ask for your consent once more. And Mac users still on macOS 14 Sonoma are no longer offered updates that can't run on their Mac.

## ScarfGo now verifies your server's identity

Until now, ScarfGo didn't check a server's SSH host key, the fingerprint that proves a server is the one you paired with. On a network someone else controls, a machine pretending to be your Hermes host could have been accepted, and it could then read and change what ScarfGo sent, including your chats. The Mac app was never affected: it uses the system `ssh`, which has always checked host keys.

ScarfGo now behaves like the Mac:

- **The first time it connects to a server, it remembers that server's key.** Servers you paired before this update are remembered on their next connection, with nothing for you to do.
- **If a server later shows a different key, ScarfGo refuses to connect** before signing in, and never retries on its own (chat reconnect included). The server list says "Server identity changed. Review it in System."
- **System › Server shows the key ScarfGo trusts.** When the key has changed, a card shows the trusted key and the new one side by side, with the command to check the new one on the server itself. A changed key is expected after you reinstall a server or regenerate its SSH keys. If you know why it changed, **Trust New Key** (after a confirmation showing the exact key) trusts that key and nothing else.

## Easier to read, on Mac and iPhone

Scarf's rust orange looked good but failed accessibility contrast standards (WCAG AA) in places: white text on orange buttons was hard to read, especially in dark mode, and some status text in light mode was barely legible. Here is what you'll see change:

- **A deeper orange for buttons, links and selections in light mode.** The brand orange stays the same in the logo and artwork.
- **Dark-mode buttons have dark text on the light orange**, instead of white text that was hard to read. Main buttons across both apps now use Scarf's own button style. Their labels grow with Dynamic Type, and on iPhone they keep a 44-point tap area.
- **Status text is darker and readable.** Success, warning, info and error text in light mode now pass the contrast standard everywhere; badges, banners and borders keep their familiar lighter colours.
- **Destructive actions are brick red** (Delete, Stop, End, Uninstall) with white text that's easy to read, and error text in light mode is a darker red.
- Charts in Insights use colours that are easier to tell apart, and neutral chips show up on grey backgrounds.

## Privacy, described accurately

We reviewed the privacy policy against the code and found places where it said less, or something different, than the apps actually do. The policy now matches the code, and so does the text inside the apps:

- **Live Voice will ask for your consent again, once.** Live Voice (Hermes's GPT-Live mode) streams your voice to OpenAI. The old consent screen didn't mention that **Hermes's replies and short status lines, such as which tool Hermes is using, also go to OpenAI** so the voice can speak them, or that your Hermes host passes the recent chat messages on. The screen now says so, and because the facts changed, Scarf and ScarfGo ask everyone again the next time you start Live Voice. Nothing else about Live Voice has changed. The consent screen also says it will ask again if what's shared ever changes.
- **"Anonymous" is now "usage statistics."** The Mac app's opt-out usage statistics include a hashed random ID for your install. That is not your name or anything about you, but calling it "anonymous" overstated it. The setting (Settings › Advanced) is now labelled **Share usage statistics** and explains what the ID is used for. ScarfGo still sends no statistics at all.
- **Usage statistics only while you're at your Mac.** Scarf keeps running in the background, but it no longer records usage statistics while nobody is using it. Background work such as update checks, slow-operation reports and connection monitoring isn't recorded then, and results that arrive while you're away, like an agent turn finishing, are recorded when you come back. The Settings screen now lists exactly what each batch of statistics contains. Builds you run from source, and other local copies, no longer report as the production app.
- The policy now covers device details, slow-operation reports, server backups, local model checks, sign-in pages and template links; states the 90-day retention for usage statistics; and describes ScarfGo's optional iCloud Keychain sync for its SSH key. The Mac app's privacy manifest now declares what the usage statistics include, and the iPhone microphone and speech permission prompts mention voice conversations.
- The Scarf website now describes the Mac app's usage statistics. It used to say there was "no telemetry."

## On macOS 14 Sonoma? Here's what's going on

Scarf has required **macOS 15 Sequoia** since v2.20.0. Our update feed wrongly told Sparkle that every release from v2.20.0 on still ran on macOS 14.6, so Macs on Sonoma were offered updates that couldn't open. The feed now lists macOS 15.0 for those releases, so Sonoma Macs stay on v2.19.2, the last version that supports them, and are no longer offered updates they can't run. To get this and future releases, update your Mac to macOS 15 or later. The website, README and build docs now list the real minimums: macOS 15.0 and iOS 18.6.

## Smaller fixes

- The in-app **Nous Portal** docs link went to a page that no longer exists. It now opens the current page.
- Links to Hermes on the website, README and privacy policy now go to the real project (NousResearch/hermes-agent).
- The website uses Scarf's real brand colours, its social preview images no longer cut off the tagline, and several FAQ answers were corrected (adding a server, ScarfGo key storage, the smaller Apple Silicon download, how ScarfGo updates).

## Under the hood

- The analytics library (swift-stats) is updated to 0.3.0. A few noisy events were dropped (for example, one fired on every Cmd-Tab), and new events record whether setup and configuration steps succeed, using only fixed labels, never your values.
- A new design check (`tools/check-design-tokens.py`) runs with the website and catalog builds. It fails if any colour drifts from the app's design tokens or falls below its contrast target, or if the system's prominent buttons come back.
- A website check (`tools/check-site-faq.py`) fails when a FAQ answer and its search-engine copy disagree.
- `release.sh` now reads the minimum macOS version for the update feed from the built app, rather than from a fixed number in the script that went out of date.
- The host-key check has its own tests, including one against a real local SSH server with a swapped key. Every new string is translated into all six supported languages.

## Upgrade notes

- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 15.0+ (Apple Silicon and Intel). Macs on macOS 14 stay on v2.19.2.
- ScarfGo (iOS 18.6+) gets these changes through the App Store, with beta builds on TestFlight. After updating, ScarfGo remembers each server's key on its next connection; nothing to set up.
- Live Voice will show its consent screen once more on each device, with the corrected text.
- Compatible with Hermes v0.6.0 through v0.21.5; the Hermes target is unchanged from v3.5.0.
