# Scarf v3.1.0

Projects grow up in this release. The whole projects surface — registry, per-project files, mini-apps, dashboards — was put through four rounds of adversarial security, data-integrity, performance, and accessibility auditing, and everything found was fixed: an agent session can no longer destroy Scarf's project state, a flaky connection can no longer truncate your files, and the app does dramatically less work while an agent streams. On top of that foundation: a redesigned sidebar with your projects front and center, per-project edit approval so project chats stop nagging you, and mini-apps that can finally open links in your browser — with your consent, per host.

## A sidebar built around your projects

Your projects now live at the top of the sidebar in their own panel: every project listed with its status, folders and filtering for big collections, the full context menu (Upgrade, Configuration, Chat Settings, Rename, Archive, Uninstall…), and a **New Project** button that opens the wizard directly. The old secondary project list inside the Projects area is gone — one list, one selection, everywhere. The other sidebar sections now collapse and expand: Monitor, Bots, and Interact start open; Configure and Manage start tucked away, and Scarf remembers your arrangement.

## Project chats stop asking permission for every edit

Hermes asks before every file edit by default, which is the right posture — until it's your own project and the tenth prompt of the session. Two fixes:

- **Per-project auto-accept**: flip "Auto-accept edits" in a project's Chat Settings and every chat bound to that project starts in Hermes's accept-edits mode — edits inside the project apply without prompting, while sensitive paths (SSH keys, credentials) still ask, enforced by Hermes itself.
- **"Allow edits for this session"**: the approval dialog now offers a third button on edit prompts that approves the pending edit and stops asking for the rest of the session. One click, where you're already looking.

The auto-accept setting is stored tamper-proof: it's cryptographically bound to your machine, so an agent can't quietly grant itself the bypass.

## Mini-apps can open links — with your consent

Mini-apps run in a hermetic sandbox with no network access, which previously made every external link a dead end. A new `open_url` permission lets a mini-app hand a link to your default browser: https-only, and the first link to any new host asks you by name — **Open once**, **Always allow this host**, or **Cancel**. Nothing opens without your click, homograph domains display in their honest punycode form, and each mini-app is limited to a handful of requests per minute. The sandbox itself is unchanged: mini-apps still can't reach the network themselves.

## Projects that can't be destroyed

The headline of the hardening campaign: **every file Scarf owns now survives bad writes, bad reads, and bad connections.**

- **Atomic writes on every transport** — including iOS over SFTP, where a dropped cellular connection used to be able to leave AGENTS.md or your cron jobs as a truncated fragment. Every write now stages to a temp file and publishes with a rename; the destination is never in a half-written state.
- **Damage is quarantined, never amplified.** If a registry or project file won't parse, Scarf copies the bytes aside, tells you with a banner, and refuses to overwrite what it can't read — a network blip can no longer make Scarf "helpfully" replace your data with an empty rebuild. Rolling `.bak` files back up the registry, project records, and now AGENTS.md.
- **The Project Doctor** reconciles the registry, per-project records, and what's actually on disk — it detects renames that didn't propagate, moved folders, name collisions, and ghost projects, repairs what's safe to repair, and reports honestly on what isn't.
- **One writer at a time.** Scarf's app and its agent-facing tools now coordinate through a cross-process lock, so simultaneous writes can't silently erase each other.
- **Trust is verified at time of use.** Uninstalling a template re-validates every deletion against the project's own boundaries (symlink tricks included); keychain references are cryptographically bound to their owning project so one project's agent can't read or delete another's secrets; and mini-app permission grants are signed, so an agent can't forge its own approvals.

## Agents get real tools instead of file surgery

The bundled `scarf-projects` MCP server now covers the full project surface — including a new `project_set_config` tool that routes secret values straight to the macOS Keychain, never to a plaintext file. The built-in project skills and slash commands now direct agents to these tools instead of hand-editing JSON, which is how most historical project damage happened in the first place.

## Much faster while agents stream

During an active chat, Scarf's file watcher ticks every half-second — and previously, every tick reloaded everything: **~55–70 SSH round-trips per tick** on a remote host with a screenful of projects. Now every surface asks "did anything change?" before reading: one batched stat covers the cockpit, another covers all dashboard widgets, the sidebar re-renders only on real changes, and the health scan runs only when you ask for it. An unchanged tick costs **~4 round-trips**. Registry mutations also moved fully off the main thread, so a slow SSH host can no longer freeze the window.

## Accessibility

VoiceOver now hears what sighted users see across the projects surface: registry damage and repair completion are announced; doctor findings speak their severity; charts expose real data through Audio Graphs; sparklines and stat cards read as single sensible elements; kanban status uses shapes, not just colors; tables have proper headers; and the small fixed fonts in dense widgets now scale with your text size.

## Under the hood

- The remote-restore flow rewrites files through the same guarded, atomic path as everything else and reports failures honestly instead of claiming success.
- Cross-project path normalization unified; project removal is id-keyed (no more removing two same-named rows); archiving a project now actually pauses its cron jobs and stops watching it.
- Release builds are part of CI hygiene again — two strict-concurrency issues that only Release surfaced are fixed, and the lesson is recorded so it stays fixed.
- Test suites grew from 1,838 to **2,176 ScarfCore tests** plus 745 app tests, including adversarial suites that attack the new guarantees directly: forged grants, symlinked uninstall targets, concurrent writers, torn connections mid-write.

## Upgrade notes

- **Mini-apps will re-ask for their permissions once.** Permission grants are now cryptographically signed, and grants from earlier versions can't be verified after upgrading — each mini-app shows its consent sheet one more time. One click per app, per machine; nothing else to migrate.
- Project keychain secrets migrate to stronger bindings automatically the next time they're read — no action needed.
- Updates arrive via Sparkle's built-in updater; or grab the zip from this release.
- macOS 14.6+ (Apple Silicon and Intel). ScarfGo for iOS ships separately via TestFlight — the iOS transport-atomicity fixes ride the next TestFlight build.
- Compatible with Hermes v0.6.0 through v0.21.0, unchanged from 3.0.x.
