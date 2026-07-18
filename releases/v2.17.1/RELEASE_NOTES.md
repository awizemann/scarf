# Scarf v2.17.1

A focused fix release with one theme: **"Export…" now always means "save to my Mac."** Exporting a session against a remote (SSH) Hermes used to silently do nothing — no file, no error — and exporting a profile asked you to type a destination path on the far host and know its filesystem by heart. Both now behave the way a Mac app should: pick a spot in the save panel, get a file you can see in Finder, whichever machine Hermes runs on. Every fix in this release came out of community-filed issues — thank you, [@JonLaliberte](https://github.com/JonLaliberte) and [@scriptures4life](https://github.com/scriptures4life).

## Session export lands on your Mac — and never fails silently again

Community-reported and community-fixed: [#129](https://github.com/awizemann/scarf/issues/129), fixed by [@JonLaliberte](https://github.com/JonLaliberte) in [PR #130](https://github.com/awizemann/scarf/pull/130) — their second merged contribution. 🎉

The root cause: Scarf handed the save panel's path (a path on *your Mac*) straight to the `hermes` CLI — which, on a remote server, runs on the *far host over SSH*. The CLI either failed against a directory the host doesn't have or wrote the export onto the remote box where you'd never find it, and the failure was dropped on the floor either way.

The fix is a better design, not a patch: Scarf now asks the CLI to write the export to **stdout** (`hermes sessions export -`) and saves those bytes to the path you chose — one code path for local and remote, and the CLI never sees a path at all. Along the way:

- **Export from the session detail sheet works now** (it previously did nothing at all — a sheet-over-sheet SwiftUI limitation the new design sidesteps).
- **Every failure is reported**, and Hermes's Python tracebacks are reduced to their *last* line — the one with the actual error — instead of showing you "Traceback (most recent call last):".
- **Success names the byte count**, so a broken pipe can't masquerade as a good export.
- The save panel **stops rewriting `.jsonl` to `.json`**, and exports run off the main thread so a large session over SSH doesn't freeze the UI.

## Profile export follows — no more remote-path guessing game

Exporting a profile from a remote server used to open a text field asking for a destination path *on the host* — which meant knowing which directories exist over there and pre-creating them by hand. Its "Verify" button made things worse: it green-lit paths whose parent directory didn't exist, then the export failed with a traceback ([#131](https://github.com/awizemann/scarf/issues/131)).

Per the decision in [#132](https://github.com/awizemann/scarf/issues/132), profile export now matches sessions: **the zip lands on your Mac.** `hermes profile export` has no stdout mode, so Scarf exports to a scratch path on the host, streams the zip down chunk-by-chunk (the same streaming machinery backups use — a ~300 MB profile never passes through memory), moves it atomically into your chosen destination, and cleans up the host scratch. You get progress updates during big pulls, and a mid-transfer failure leaves no half-written file where you chose to save.

The remote-path sheet — and its mis-verifying "Verify" — is gone from export entirely. Profile **import** keeps it (the zip you're importing genuinely lives on the host), where Verify checks a file that already exists and was never affected.

## Under the hood

- New raw-bytes CLI plumbing (`runHermesCLIData` / `runHermesCapturingStdout`) keeps stdout as `Data` with stderr separate, so binary payloads survive intact; `RemoteProfileExport` carries the scratch-and-stream pipeline.
- The stdout export sentinel was verified live against Hermes **v0.17.0** and **v0.18.2**; both new flows are pinned by seam-based test suites (no SSH needed to run them). Test counts this release: **986** ScarfCore, **277** Mac app bundle.
- Shared ScarfCore also gains the gh#112 config-probe diagnosis for ScarfGo (see the iOS note below); the Mac app's behavior is unchanged by it.

## Upgrade notes

- **Sparkle** will offer the update automatically, or use **Scarf → Check for Updates**. macOS 14.6+ deployment target unchanged.
- **No Hermes version floor.** Session export-to-Mac is verified on Hermes v0.17.0 and v0.18.2; profile export uses only `--output`, which is stable across supported versions.
- **iOS / ScarfGo: a TestFlight build follows this release.** It carries the [#112](https://github.com/awizemann/scarf/issues/112) work: when a Docker-hosted Hermes is unreachable over SSH (the config lives inside the container and no host-side wrapper exists), Settings now diagnoses *which* failure you have and shows the exact wrapper-script fix in-app, instead of the misleading "config.yaml not found."
