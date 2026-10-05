# ScarfGo & Scarf — Privacy Policy

_Last updated: 2026-10-05._

## Plain summary

Scarf and ScarfGo are companion clients for the open-source [Hermes AI agent](https://github.com/NousResearch/hermes-agent). Both apps connect from your device to a Hermes host you (or your team) operate. **Your content — chats, sessions, files — stays on your device and your Hermes hosts, and the developer never receives it.** The macOS app sends **usage statistics** to the developer to guide development. They carry a random ID for your install but never your name, account or content, and you can switch them off in Settings. **ScarfGo on iOS sends nothing to the developer itself** (Apple may share crash and usage data with the developer if you allow it; see "App Store and TestFlight"). A few features contact other services, each listed under "Network connections the apps make": for example, the Mac app sends your Nous Portal key to Nous to list its models, and project dashboards can load web pages. One optional feature, **Live Voice**, streams your voice directly from your device to OpenAI and shares recent chat messages and Hermes's replies with OpenAI, and only after you start a session and agree once; see "Voice features" below.

## Apps covered

- **Scarf** — macOS desktop client. Distributed as a direct download from GitHub Releases, with built-in Sparkle auto-update.
- **ScarfGo** — iOS companion. Distributed on the App Store, with beta builds through TestFlight.

## What data the apps access

### On your device

- **SSH credentials.** ScarfGo generates an SSH key, or imports one you paste in, and stores it in the iOS Keychain. By default the key stays on that device: it can't be read until the device has been unlocked once after a restart, and it is not synced. If you turn on **Sync SSH key with iCloud Keychain** (System → Security in ScarfGo), the key is saved as a synced item instead, and iCloud Keychain carries it, end-to-end encrypted, to your other Apple devices signed in to the same Apple Account; turning the toggle off makes it device-only again. The key is used solely to authenticate with Hermes hosts you configure. Scarf uses the system `ssh` with your keys in `~/.ssh/` (or a key file you choose) and your ssh-agent, like any other SSH client.
- **Server configuration.** Host, user, port, nickname, and an optional remote `~/.hermes` path. Stored in `UserDefaults` (ScarfGo) or `~/Library/Application Support/scarf/servers.json` (Scarf). Never transmitted off-device except as the destination address of your own SSH connections.
- **Project secrets (Scarf).** Values you enter in a project template's secret fields are stored in your macOS login Keychain (items named `com.scarf.template.…`). So that Hermes jobs can use them, Scarf can also copy them into a marked block of `~/.hermes/.env` on that project's Hermes host.
- **Reading Hermes data.** The apps read your Hermes state (`~/.hermes/state.db`, config, memory and log files) where it lives: on a remote host, with read-only `sqlite3` queries and file reads over SSH; on the same Mac, directly. Results are held in memory for display. The apps do not keep a copy of the database on your device unless you make a server backup in Scarf: a backup copies your Hermes home, including its databases, its `.env` file of secrets and, if you choose, `auth.json`, into an archive in `~/Documents/Scarf Backups/` on your Mac.
- **Project registry + session attribution sidecar.** Scarf and ScarfGo read (and write, when you opt in) two JSON sidecar files on the Hermes host: `~/.hermes/scarf/projects.json` and `~/.hermes/scarf/session_project_map.json`. These describe the projects you've registered and which Hermes sessions belong to which project. Owned by you on your Hermes host.

### Voice features

Voice is off until you use it. Hermes Voice and Live Voice also appear only when your Hermes host's version supports them. Each feature keeps to a different boundary:

- **Dictation (ScarfGo).** Holding the composer's microphone button transcribes speech to text **on your iPhone only**, with Apple's on-device speech recognizer. Audio never leaves the phone and is never sent to a server. The transcript is inserted into the composer like typed text; nothing is sent until you tap send.
- **Hermes Voice playback (Scarf for macOS).** When you choose the Hermes playback engine (Settings → Voice), the app asks **your Hermes host** to turn an assistant reply into speech using the text-to-speech provider configured in that host's own `tts` settings, then downloads the audio and plays it. The reply text goes to whichever provider your host is configured to use: Hermes's default, Edge TTS, is an online Microsoft service, and a local engine or a service such as OpenAI or ElevenLabs are other options. Scarf does not choose the provider and never contacts it directly. Audio is cached on your Mac under `~/Library/Caches/scarf/tts` (capped, oldest first) and can be deleted at any time. Off by default; the alternative engine is the built-in macOS system voice, which stays on-device.
- **Voice conversation, chained mode (Scarf and ScarfGo).** With Hermes's default voice mode, a spoken conversation runs entirely between your device and your own Hermes host: your speech is turned into text **on your Mac or iPhone** by Apple's on-device recognizer (on-device only; the apps refuse to run if that isn't available rather than use Apple's servers), the words go to Hermes exactly like a typed message, and the reply is read aloud either by the host's text-to-speech provider (the same path as Hermes Voice playback above) or by the system voice on your device. No audio leaves the device, no third party is contacted by the apps, and nothing is billed. Available with Hermes 0.20.1 or later; the apps ask for Speech Recognition and Microphone permission the first time.
- **Terminal-mode voice (Scarf for macOS).** In a chat's terminal mode, the voice controls (push-to-talk and spoken replies) turn on the Hermes command line's own `/voice` mode. When Hermes runs on your Mac, Hermes records from your Mac's microphone, using Scarf's microphone permission, and turns the recording into text with the speech-to-text provider set in your Hermes configuration, which may be a local model or an online service; replies are read aloud by Hermes's text-to-speech provider. Scarf does not process that audio itself. When Hermes runs on a remote host, Scarf does not pass your Mac's microphone to it.
- **Live Voice (Scarf and ScarfGo).** A two-way spoken conversation built on Hermes's GPT-Live voice mode, which uses an OpenAI voice model. It runs only when your Hermes host is version 0.21.3 or later **and** you have set `voice.voice_chat_mode: gpt-live` on that host. When you start a session:
  - Your Hermes host creates the session with **your own OpenAI API key** (the one configured on the host). The host sends the key to OpenAI to create the session; it is never sent to your device, and the apps never see or store it.
  - **Your microphone audio streams directly from your device to OpenAI** over an encrypted WebRTC connection, and OpenAI's spoken replies stream back the same way. Because the connection is direct, OpenAI also sees your device's network address. The audio does not pass through your Hermes host or any server operated by the developer.
  - Each session shares **recent messages from the current chat** with OpenAI as context: up to 24 messages, about 6,000 characters. The app sends them to your Hermes host (over SSH for a remote host), and the host passes them to OpenAI when it creates the session.
  - While a session is open, the app also sends **Hermes's reply text** and short status lines (such as "Hermes is working" and the name of the tool it is using) to OpenAI over the voice connection, so the voice model can speak them. Every request you make by voice is still answered by Hermes, with your usual model and tools; the voice model only relays it. The spoken request is saved in the Hermes session transcript like a typed message; the live audio and captions are not stored by the apps.
  - OpenAI bills the host's key while a session is open (roughly $0.05 per minute at the time of writing). Sessions end when you stop them, close the chat, switch servers or profiles, leave the app (ScarfGo), lose the Hermes connection, or after a period of silence.
  - **Consent.** Before the first session on a device, the app shows what is shared and with whom; nothing starts until you agree, and Cancel sends nothing. Your choice is stored in the app's settings on that device (never on the host, and not synced through iCloud, though like other app settings it is included in your device's backups) and can be reviewed or reset in Settings → Voice (Scarf) or System → Settings → Live Voice Privacy (ScarfGo). If what is shared ever changes, the app asks again.
  - OpenAI's handling of the audio, messages and replies is governed by [OpenAI's privacy policy](https://openai.com/policies/privacy-policy) and the terms of the API account whose key the host uses.

Both apps request microphone permission the first time a voice feature needs it, and the permission text states which features use it. Microphone access is never used outside a dictation hold, a voice conversation, terminal-mode voice, or a Live Voice session you started.

### On Hermes hosts you configure

Same as the [Hermes agent privacy policy](https://hermes-agent.nousresearch.com/) (or whoever operates your Hermes deployment). The apps do not introduce any new server-side data collection.

## Usage analytics (Scarf for macOS only)

Starting with v2.20, Scarf for macOS records product-usage events — for example "a chat session was started", "a settings field was changed", "the app reconnected after wake" — and sends them to the developer's analytics service (ScarfMon, at `api.swiftstats.co`, built on the open-source [swift-stats](https://github.com/awizemann/swift-stats) package). Events wait in a small queue on your Mac (`~/Library/Application Support/com.scarf.app/swift-stats/`) and are sent in batches.

**What an event contains.** An event name plus a small set of properties drawn from closed lists in the app's source (e.g. `mode: resume`, `source: menu_bar`), with counts and durations rounded into coarse buckets. Between them, the events cover things like: which sections you open; which Hermes setting you changed (its name, such as `display.streaming`, never its value); whether connections, reconnects, agent turns, session resumes, model checks and Hermes version checks worked, and if not, the broad kind of failure; roughly how many tool calls an agent turn made; whether a message had an attachment or was spoken; whether you approved or denied a permission prompt; which bot, project, template and skill actions you took; and roughly how many skills were installed. A few values are exact numbers: the Hermes version your host runs (e.g. `0.21.3`), how many connection failures in a row made Scarf pause reconnecting to a host, and the length of each usage session in seconds. Properties never contain chat content, prompts, file paths, hostnames, server names, profile names, SSH keys, or any other free-form text from your environment. The app also records when it opens and goes to the background, and when a usage session starts and ends. Every event carries its time (to the millisecond), a random ID for the current usage session, a running event counter, the app's ID, and the hashed install ID described below.

**Slow-operation reports.** While Performance Diagnostics (Settings → Advanced) is set to Signpost only (the default) or Full, Scarf also reports operations that took unusually long — for example a chat render over 100 ms or an SSH round trip over 5 seconds — as a `perf_measure` event carrying only the kind of operation and a rough duration, at most 30 per kind each time the app runs (the count starts again when you change the Performance Diagnostics mode). Setting Performance Diagnostics to Off stops these reports, and so does turning analytics off.

**Device and app details.** Each batch of events includes the app's version, build and bundle ID; the analytics library's version; your macOS version; your Mac's model identifier (e.g. `Mac15,3`) and processor type (`arm64` or `x86_64`); your language and region settings (e.g. `en_US`, `US`); and whether the build is a debug or pre-release build. Screen size and light/dark appearance are not collected.

**What identifies an event.** The analytics library creates a random install ID (a UUID) on your Mac and keeps it in its own preferences file, `~/Library/Preferences/com.wizemann.stats.com.scarf.app.plist`. Every event carries a salted SHA-256 hash of that ID, never the ID itself. The same hash is sent for as long as the ID exists, across launches and updates, so the developer can count active installs and see how one install's use develops over time, such as how many sessions it has and whether it comes back. The ID belongs to one installation, not to you: there is no user ID, no account, no hardware serial or advertising identifier, and nothing that ties it to your name, your Hermes hosts, or your content. The analytics service receives your network address with each batch, as any web server does. Its code does not store it, but Cloudflare, which hosts the service, may record it in request logs that are kept for a short time.

**How long it's kept.** The analytics service deletes raw events after a set period, 90 days by default and never more than 400, and keeps aggregated daily counts after that. Its code also keeps one record per hashed install ID of the first day that install was seen, used to tell new installs from returning ones.

**Opting out.** Settings → Advanced → Usage Analytics. Turning it off stops collection immediately, deletes any events still queued on your Mac, and persists across launches and updates. It does not delete the install ID: the ID stays in that preferences file, unused, and if you turn analytics back on your install continues under the same ID. To forget the ID as well, quit Scarf and run `defaults delete com.wizemann.stats.com.scarf.app installUUID` and then `defaults delete com.wizemann.stats.com.scarf.app seq` in Terminal. Scarf then creates a new random ID and restarts the event counter the next time it sends statistics. The new ID isn't linked to the old one by any identifier, although the device details sent with each batch stay the same. (Deleting the whole preferences file also deletes your opt-out choice, so analytics would be on again at the next launch.) Analytics is enabled by default; the toggle is one click.

**Builds from source.** A copy of Scarf you build yourself from the public repository sends nothing: the key that lets the app send statistics is not in the repository.

**What it is not.** No third-party ad or analytics SDKs (swift-stats is the developer's own open-source package), no ad identifiers, and no reading of your Hermes content for analytics. Beyond the Hermes version, the outcomes summarized above, a rough count of how many servers you have set up (reported at launch), and whether a server is local or reached over SSH (reported when you add or remove one and when Scarf connects), nothing about your Hermes setup is reported.

**ScarfGo (iOS) sends nothing to the developer itself.** The iOS app contains no analytics recorder and makes no analytics network calls. Live Voice (above) is the one iOS feature that sends your data to a third party, and only to OpenAI, only while a session you started is open.

## What data the apps DO NOT collect

- **No content collection.** Nothing you type, say, read, or store in Hermes — chats, files, prompts, configs, credentials — is ever transmitted to the developer. The macOS usage analytics described above carry event names, fixed-vocabulary properties and the device details listed there, nothing more. Live Voice audio, context and replies go to OpenAI, never to the developer.
- **No analytics on iOS.** ScarfGo itself sends no events of any kind. On macOS, analytics is content-free, tied only to a hashed per-install ID, and can be disabled in Settings → Advanced.
- **No voice data at rest beyond your device.** Dictation audio is processed on-device and discarded. Live Voice audio is streamed, not recorded, by the apps. Hermes Voice audio is cached only on your Mac.
- **No crash-content upload.** Crash logs stay on-device unless you choose to share them with Apple via the standard iOS / macOS reporting flows; if you also allow sharing with app developers, Apple may pass them on to the developer.
- **No ads or ad identifiers.** The advertising identifier (`IDFA`) and the vendor identifier (`IDFV`) are not read or transmitted.
- **No cloud accounts.** There's no "Sign in with Scarf" — the apps only know about Hermes hosts you give them SSH access to.
- **No iCloud sync unless you turn it on.** ScarfGo's SSH key stays on the device unless you enable iCloud Keychain sync for it (see "SSH credentials" above). Nothing else is synced through iCloud.

## Network connections the apps make

- **SSH connections** to Hermes hosts you configured (port 22 by default; user-configurable). All Hermes data flows over these. When Hermes runs on the same Mac, Scarf talks to it locally, including a status check of Hermes's local web dashboard at `127.0.0.1`.
- **Local model servers (Scarf only).** When you set up a local model provider such as Ollama or LM Studio, Scarf asks the server at the address you entered (or the provider's usual default) for its list of models, using `curl`. It does the same to check whether an Ollama model can read images. For Hermes on your Mac the request comes from your Mac; for a remote Hermes host it runs on that host over SSH.
- **Update checks (Scarf only).** Sparkle fetches the update feed from GitHub Pages (`https://awizemann.github.io/scarf/appcast.xml`) about once a day — automatic checks can be turned off in Settings — and downloads updates from GitHub Releases (`github.com/awizemann/scarf/releases`). Sparkle's optional system-profile reporting is not enabled; the requests identify only the app and its version.
- **Project templates (Scarf only).** Browsing the template catalog fetches `https://awizemann.github.io/scarf/templates/catalog.json` from GitHub Pages (cached for a day). Installing a template downloads its `.scarftemplate` file from where it is published — the catalog's own templates come from `raw.githubusercontent.com` — or from an https link you paste. A `scarf://install` link on a web page also makes Scarf download the template it points to (https only) as soon as you open the link, so it can show it to you; nothing is installed until you confirm. No personal headers are added.
- **Project dashboards (both apps).** A project's dashboard file (`.scarf/dashboard.json`, usually written by the agent) can include web widgets and, in Scarf, image widgets that point to internet addresses. A web widget loads its https page when you open the dashboard, in a web view that keeps no cookies or site data and can't navigate away from that site; the page can load its own resources like any web page. Scarf asks before loading images from a host it hasn't loaded images from before for that project. These sites see your network address. Project mini-apps can't reach the network.
- **Nous Portal model list (Scarf only).** When you open the model picker and your Hermes host is signed in to Nous Portal, Scarf reads the Nous key from that host's `auth.json` and sends it over HTTPS, from your Mac, to Nous Research's inference API (`inference-api.nousresearch.com`, or the inference address recorded for Nous in that host's `auth.json`) to fetch the list of available models. It does this only when its cached list is missing or out of date; the list is cached on your Hermes host, and Scarf does not store the key.
- **Sign-in pages (Scarf only).** When you sign in to Nous Portal, another model provider or Spotify through Hermes, Scarf opens the sign-in page Hermes gives it in your default browser on its own. For an MCP server sign-in, Scarf shows the page's address and opens it when you click Open. The sign-in itself happens in your browser.
- **Hermes's own connections.** Hermes makes its own network connections, for example to models.dev to refresh its model catalog, and to Nous Research if you turn on Hermes's shared-metrics setting. Those are Hermes's, not the apps'; see the [Hermes documentation](https://hermes-agent.nousresearch.com/).
- **HTTPS to `api.swiftstats.co`** (Scarf for macOS only, when usage analytics is enabled) carrying the usage events described above.
- **WebRTC to OpenAI** (both apps, only while a Live Voice session you started is open): microphone audio out and spoken replies in, plus Hermes's reply text and status lines. The session itself, including the recent-chat context, is created by your Hermes host over its own HTTPS connection to OpenAI, with the host's key.

That's the complete list. Apart from links you choose to open in your browser, neither app makes any other network request.

## Push notifications

ScarfGo contains a push-notification skeleton for pending permissions on a remote agent run, but it is switched off in the code (`apnsEnabled = false`): the app never registers for remote notifications, so no device token is created or sent anywhere. If that changes, this policy will say so first.

## App Store and TestFlight

If you use ScarfGo from the App Store, Apple shares app usage and crash data with developers only from people who have chosen to share with app developers (on iPhone: Settings → Privacy & Security → Analytics & Improvements → Share With App Developers).

If you join the ScarfGo beta via TestFlight, Apple shares information with the developer under its [TestFlight terms](https://www.apple.com/legal/internet-services/itunes/testflight/): for example the email address you were invited with (testers who join through a public link aren't invited by email), install and session counts, your device model and iOS version, crash reports, and any feedback or screenshots you send through TestFlight. Apple's terms govern that data.

## Security

- Scarf runs the system `ssh`. It authenticates with keys only (it never prompts for or sends a password) and trusts a host's key on first connect: the key is saved to `~/.ssh/known_hosts`, and a changed key is refused. ScarfGo uses Citadel's pure-Swift SSH with an Ed25519 key, also key-only, but **does not yet check the host's key**, so it cannot tell your Hermes host from a server pretending to be it. Use ScarfGo over networks you trust, or a private network such as Tailscale.
- The macOS app is notarized via Apple's standard Developer ID flow (signed + stapled by `xcrun notarytool` on every release). It is not App-Sandboxed — Scarf needs direct read access to `~/.hermes/` and the ability to spawn the `hermes` CLI, both of which the App Sandbox forbids. That's why Scarf is distributed via GitHub Releases + Sparkle rather than the Mac App Store.
- ScarfGo on iOS runs inside the standard iOS app sandbox with no special entitlements. It asks for microphone and speech recognition permission only when a voice feature needs them.
- Live Voice runs its media connection inside an isolated, non-persistent web view that only ever loads the app's own bundled page and only grants the microphone to that page; no cookies or site data persist between sessions.

## Children's privacy

Neither app is directed at children under 13 and we do not knowingly collect any data from them.

## Your rights

The only data that reaches a server the developer operates is the macOS usage statistics described above. You can stop them at any time (Settings → Advanced → Usage Analytics). They are tied to a hashed install ID, not to your name or account, so the developer cannot find "your" events from who you are. To have them deleted, send your install ID (shown by `defaults read com.wizemann.stats.com.scarf.app installUUID` in Terminal) to the contact address below. The developer can then delete the raw events recorded under it; aggregated counts that no longer carry the ID remain. To remove all app-stored data from your device:

- **ScarfGo**: first forget each server in the app, which deletes its SSH key from the Keychain (and from iCloud Keychain, if you turned sync on); then delete the app, which removes its container and settings. iOS can keep Keychain items after an app is deleted.
- **Scarf**: delete `Scarf.app` from `/Applications`, then optionally remove:
  - `~/Library/Application Support/scarf/` (server list and lock files; on a case-sensitive disk the lock files are in `~/Library/Application Support/Scarf/`)
  - `~/Library/Application Support/com.scarf/` (skill snapshots) and `~/Library/Application Support/com.scarf.app/` (the analytics queue)
  - `~/Library/Caches/scarf/` (cached Hermes Voice audio), and, if present, `~/Library/Caches/com.scarf.app/`, `~/Library/HTTPStorages/com.scarf.app/` and `~/Library/WebKit/com.scarf.app/` (the system's web caches for the app)
  - `~/Library/Preferences/com.scarf.app.plist` (preferences) and `~/Library/Preferences/com.wizemann.stats.com.scarf.app.plist` (the analytics install ID and your opt-out choice)
  - `~/Documents/Scarf Backups/` (server backups you made)
  - any `com.scarf.template.…` items in Keychain Access (project secrets), and the `com.scarf.miniapp-grants` item (the key Scarf uses to sign the permissions you give project mini-apps)
  - SSH connection sockets live in `/tmp/scarf-ssh-<your user ID>` and are cleared when the Mac restarts.

Your Hermes host's data (`~/.hermes/`) stays untouched, including the sidecar files and any secrets block Scarf wrote there — that's yours to manage.

## Contact

Questions, concerns, or notice of a security issue: [alan@wizemann.com](mailto:alan@wizemann.com).

## Changes

Material changes to this policy will be announced on the [Scarf wiki](https://github.com/awizemann/scarf/wiki) and recorded here with a new "Last updated" date. Beta testers will see a TestFlight build note when policy changes affect data handling.
