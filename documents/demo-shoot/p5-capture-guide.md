# Phase 5 — Demo Shoot Capture Guide

Ground truth verified 2026-08-13 against the actual repo files (not assumptions):

- **README.md** embeds `site/landing/assets/screenshots/mac-hero.png` (single, no dark variant referenced in README itself) and `assets/screenshots/scarfgo-*.png` (5 files, root-level `assets/screenshots/`, **not** `site/landing/assets/screenshots/`).
- **`site/landing/index.html`** uses `<picture>` with a `(prefers-color-scheme: dark)` `<source>` pointing at `*-dark.png`, falling back to the light `<img src>`, for every `mac-*` shot (hero, chat, projects, sessions, mcp, cron, dashboard). It also carries a `data-dark-src` attribute mirroring the dark file for JS-driven theme toggling. iOS shots (`ios-*.png`) have no dark variant — ScarfGo doesn't ship a separate dark screenshot set on the landing page.
- **Landing page screenshots directory** (`site/landing/assets/screenshots/`) uses `ios-*.png` naming (`ios-servers.png`, `ios-chat.png`, `ios-project-dashboard.png`, `ios-skills.png`, `ios-system.png`) at **1284×2778px**. All `mac-*` shots there are **2099×1332px** — 7 pairs referenced by `index.html` (hero, chat, projects, sessions, mcp, cron, dashboard) plus 2 orphaned pairs on disk (`mac-memory`, `mac-skills`) that no page references (18 files total).
- **Root `assets/screenshots/`** (the one README's ScarfGo strip actually points at) uses `scarfgo-*.png` naming, confirmed present at **1284×2778px** each: `scarfgo-servers.png`, `scarfgo-chat.png`, `scarfgo-project-dashboard.png`, `scarfgo-skills.png`, `scarfgo-system.png`. These are two physically separate directories with two different naming conventions for the same five iPhone shots — do not confuse them when filing new captures.
- Cockpit panel names, confirmed from `scarf/scarf/Features/Projects/Views/ProjectCockpitView.swift` (`enum CockpitPanel`): Dashboard, Sessions, Board, Site, Context, Cron, Memory, Secrets, Templates, Slash, Mini-apps (`.miniapps`), Fleet. `.board` only shows when the project has Kanban; `.site` only shows when a webview widget exists — both are true for harness.
- harness Kanban card `t_d726517a` should be moved to "running" state before shooting via `hermes kanban claim t_d726517a` (per P4 notes) so the Board panel shows live-looking work, not an all-idle backlog.
- harness has 2 cron jobs, both **paused** — their paused badge will be visible in the Cron panel screenshot; this is fine and honest, don't try to fake a running state.
- harness mini-app: `.scarf/miniapps/run-user-test/` (index.html + miniapp.json) — this is the "Run a User Test" mini-app to screenshot open in the Mini-apps panel.

---

## A. Shot List

| # | Target filename(s) | Surface | On screen | Theme | Dimensions | Used in |
|---|---|---|---|---|---|---|
| 1 | `site/landing/assets/screenshots/mac-hero.png` + `mac-hero-dark.png` | Mac | harness project cockpit, **Dashboard** panel (stats+sparklines, bar chart, status grid, runs table, roadmap list, webview) selected in sidebar | Light + Dark | 2099×1332 | README hero image (`site/landing/assets/screenshots/mac-hero.png`, light only per README embed) + landing page hero `<picture>` (both) |
| 2 | `site/landing/assets/screenshots/mac-dashboard.png` + `mac-dashboard-dark.png` | Mac | Same as #1 — Dashboard panel, harness project, refreshed to star harness's new dashboard config | Light + Dark | 2099×1332 | Landing feature block "Dashboard" |
| 3 | `site/landing/assets/screenshots/mac-projects.png` + `mac-projects-dark.png` | Mac | **Projects cockpit** sidebar with **Board** panel visible — harness's 6 Kanban cards, `t_d726517a` shown in "running" column/state | Light + Dark | 2099×1332 | Landing feature block "Projects" |
| 4 | `site/landing/assets/screenshots/mac-chat.png` + `mac-chat-dark.png` | Mac | Rich Chat session (see script in section C) mid-run — a tool call card expanded plus a reasoning block expanded, in the harness project | Light + Dark | 2099×1332 | Landing feature block "Chat" |
| 5 | `site/landing/assets/screenshots/mac-mcp.png` + `mac-mcp-dark.png` | Mac | Existing MCP-related panel refresh (Context or Secrets, whichever the current asset actually depicts — reconfirm against the live shot before overwriting) starring harness's registered MCP context | Light + Dark | 2099×1332 | Landing feature block "MCP" |
| 6 | `site/landing/assets/screenshots/mac-sessions.png` + `mac-sessions-dark.png` | Mac | **Sessions** panel, harness project, one or two visible sessions (see privacy checklist — use only the demo Rich Chat session from section C, nothing else) | Light + Dark | 2099×1332 | Landing feature block "Sessions" |
| 7 | `site/landing/assets/screenshots/mac-cron.png` + `mac-cron-dark.png` | Mac | **Cron** panel, harness project, both jobs visible with paused badges | Light + Dark | 2099×1332 | Landing feature block "Cron" |
| 8 | `site/landing/assets/screenshots/mac-miniapp.png` + `mac-miniapp-dark.png` (net-new) | Mac | **Mini-apps** panel open, "Run a User Test" mini-app rendered | Light + Dark | 2099×1332 | Net-new pair; update `index.html` if a feature block should reference it. Note: `mac-skills.png`/`-dark` already exist on disk (orphaned, unreferenced) — use a fresh name so nothing is silently overwritten |
| 9 | `assets/screenshots/scarfgo-servers.png` | iPhone | ScarfGo Servers list — harness + Scarf both registered | Single (no dark variant shot for ScarfGo) | 1284×2778 | README ScarfGo strip |
| 10 | `assets/screenshots/scarfgo-chat.png` | iPhone | ScarfGo Chat tab, same demo prompt/response as Mac chat shot (or a mobile-friendly excerpt) | Single | 1284×2778 | README ScarfGo strip |
| 11 | `assets/screenshots/scarfgo-project-dashboard.png` | iPhone | ScarfGo Project dashboard tab, **harness** selected | Single | 1284×2778 | README ScarfGo strip |
| 12 | `assets/screenshots/scarfgo-skills.png` | iPhone | ScarfGo Skills browser | Single | 1284×2778 | README ScarfGo strip |
| 13 | `assets/screenshots/scarfgo-system.png` | iPhone | ScarfGo System tab | Single | 1284×2778 | README ScarfGo strip |

Note: `site/landing/assets/screenshots/ios-*.png` (the landing page's own iOS gallery, 1284×2778, no dark set) mirror the same five ScarfGo screens under a different filename convention — capture once on the phone, then save/export to both directories under their respective names (`scarfgo-servers.png` → root `assets/screenshots/`; `ios-servers.png` → `site/landing/assets/screenshots/`), or duplicate the file rather than reshooting five identical scenes twice.

---

## B. Setup Checklist (before shooting)

1. **Retina consistency**: shoot everything on a Retina/Scaled display so macOS captures at 2x. The existing `mac-*` assets are 2099×1332 — that implies a window content area of roughly **1050×666 points**. Resize the Scarf window to approximately that size (points, not pixels) before capturing so new shots crop consistently with the existing set. Do not free-resize between shots — use the same window frame for every Mac capture in the session.
2. **Appearance toggle**: shoot the full light-mode pass first (System Settings → Appearance → Light), then switch to Dark and repeat the identical shot list — same window position/size, same scroll state, same data — so light/dark pairs are pixel-aligned.
3. **Hide personal data**: before shooting Sessions, Servers, or any panel that lists MCP servers/hosts, check the sidebar server list and Sessions list for anything outside the harness/Scarf demo project pair (personal servers, other clients' projects, unrelated chat history). Only the demo Rich Chat session from section C should be visible in the Sessions panel screenshot — archive or scroll past any other sessions rather than deleting them.
4. **Cron paused badges**: leave both harness cron jobs paused — the paused badge showing in the Cron panel screenshot is expected and accurate; don't unpause them just for the photo.
5. **Kanban running state**: before shooting the Board panel, run `hermes kanban claim t_d726517a` (if not already claimed) so that card shows as running rather than idle/backlog. Confirm in the Board panel that at least one card visibly reads "running" before capturing.
6. **Close anything overlapping**: dismiss any toast/notification banners, Spotlight, or other app windows that could appear in a window-shadow capture.

---

## C. Chat Session Script (for the mac-chat.png / scarfgo-chat.png shots)

Run this in a **Rich Chat** session against the **harness** project so the transcript is real, on-repo, and produces visible tool calls plus a reasoning block:

**Prompt to type:**
> Look at the Harness test suite and summarize coverage by target, then add a card to the board for the weakest area.

What this should produce, in order: a reasoning/thinking block (visible if reasoning display is expanded), one or more tool calls (e.g. reading test target directories, running `swift test --list-tests` or similar, grep across test files), a written summary of coverage per target, and finally a Kanban tool call adding a new card for the weakest-covered target.

**Which moment to screenshot**: capture **mid-run**, not after completion — specifically the moment where a tool-call card is expanded (showing the tool name + arguments, e.g. a `Read` or `Bash` call scanning test files) **and** the reasoning block above it is also expanded. This shows both features in one static frame. Avoid the fully-finished state (all cards collapsed, just a final text answer) — it under-sells the "agent working" story. If tool cards auto-collapse after completion, either screenshot before the run finishes, or click to re-expand a completed tool call's disclosure triangle and a reasoning block's disclosure triangle simultaneously post-run.

For the ScarfGo phone shot, either mirror this same prompt/response on-device, or scroll to a comparable mid-run mobile view (tool call visible, reasoning visible if ScarfGo surfaces it).

---

## D. Capture Commands

**Mac — window capture with shadow (interactive, click the window):**
```bash
screencapture -w -o path/to/output.png
```
Drop `-o` if you want the drop shadow included (matches existing hero-style assets, which appear to include a subtle window chrome/shadow). Test one and compare to `mac-hero.png` before running the full batch.

**Mac — fixed-region capture for pixel-identical framing across light/dark pairs:**
```bash
# First, find your window's origin/size with:
osascript -e 'tell application "System Events" to tell (first process whose frontmost is true) to get position of front window & size of front window'
# Then capture that exact region (x,y,w,h in points; screencapture -R takes points, not pixels):
screencapture -R<x>,<y>,<w>,<h> path/to/output.png
```
Using `-R` with the same coordinates for both the light and dark pass guarantees identical framing — this is the more reliable method for the paired `mac-*`/`mac-*-dark` shots than freehand `-w` capture, since a re-drag of the window between passes would shift the crop.

**Full-screen fallback (if window capture crops UI chrome you want):**
```bash
screencapture -x path/to/output.png
```
then crop in Preview/an image tool to the target 2099×1332.

**iPhone (ScarfGo) — via Simulator or physical device:**
- Physical device: Side Button + Volume Up (screenshot saves to Photos at native resolution, e.g. 1284×2778 for iPhone 13 Pro Max/14 Plus-class devices — matches existing assets, so use the same physical device model if possible, or a Simulator of that model).
- Simulator: `xcrun simctl io booted screenshot path/to/output.png`.
- **Framing**: existing `scarfgo-*.png` / `ios-*.png` are **bare device screenshots — no device frame/bezel chrome added**. Do not wrap new captures in a device frame; export directly at native resolution to match.

---

## E. Post-Shoot Filing

1. **Two directories, two naming conventions** — file each capture twice if it needs to serve both surfaces:
   - `site/landing/assets/screenshots/` — landing page assets: `mac-*.png` / `mac-*-dark.png` pairs (2099×1332) and `ios-*.png` singles (1284×2778).
   - `assets/screenshots/` (repo root) — README assets: `scarfgo-*.png` singles (1284×2778) — same five ScarfGo scenes as the `ios-*.png` set, just renamed.
2. **README hero dark-mode pattern**: the README today embeds only the light `mac-hero.png` via a plain `<img>` tag (line 29) — it does **not** currently use a `<picture>`/dark-mode switch. If both themes are captured and you want the README hero to respond to GitHub's dark mode, wrap it in a `<picture>` element:
   ```html
   <picture>
     <source media="(prefers-color-scheme: dark)" srcset="site/landing/assets/screenshots/mac-hero-dark.png">
     <img src="site/landing/assets/screenshots/mac-hero.png" alt="Scarf on macOS — Dashboard" width="720">
   </picture>
   ```
   This is an optional enhancement, not required — confirm with the maintainer before changing README markup, since it's a scope addition beyond a straight asset refresh.
3. **Landing page `<picture>` pattern already exists** for every `mac-*` block in `site/landing/index.html` (see lines ~93-257) — new/replacement `mac-*`/`mac-*-dark` pairs just need to overwrite the existing files at the same paths; no HTML changes required unless adding a wholly new feature block (e.g. a new Mini-apps block for shot #8), in which case add a matching `<picture>`/`<source>`/`<img>` block following the existing pattern and reference the new filenames.
4. **Rebuild/verify**: after filing, open `site/landing/index.html` **locally in a browser** (the Scarf landing page is not deployed at a stable preview URL — `awizemann.github.io/harness/` is Harness's own site, unrelated) and toggle OS appearance to confirm both `<source>`/`<img>` pairs swap correctly, then diff `git status` to confirm only the intended screenshot files changed before committing.
