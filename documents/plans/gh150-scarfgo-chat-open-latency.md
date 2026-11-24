# gh#150 — ScarfGo: opening or starting a chat takes ~30 s

## Verdict: valid, root cause not yet proven
- Hermes's own share is ~6 s (reporter log: spawn :23 → initialize :25 → session restored :29).
- The rest is Scarf-side serial work on iOS, all awaited before the composer is usable. Path mapped in full (subagent audit, 2026-11-24); key steps below with file:line.
- No per-step timers exist (only `ios.startResuming` overall, `ChatView.swift:3629`), so we can't yet say which step eats the time on the reporter's host.

## Ranked suspects (paths relative to scarf/)
1. **Model preflight on every start** — `passModelPreflight` (`Scarf iOS/Chat/ChatView.swift:2054`), called before `state = .connecting` (CV:2410-2413, 3635-3697). `HermesConfigReader.readRawConfig` (`Packages/ScarfCore/Sources/ScarfCore/Services/HermesConfigReader.swift:66`) = SFTP read; if that misses (Docker Hermes, reporter shows `/opt/data`), `hermes config path` (15 s timeout) then `hermes config show` (15 s) — two cold Hermes starts (62 plugins on this host). Not cached; no progress UI while it runs. Same cost on new chat and resume — matches the report.
2. **Two SSH connections per chat**: pooled Citadel transport + a separate un-pooled ACP connection (`ACPClient+iOS.swift` ~75). Citadel 10 s login timeout × 3 attempts + 1.5 s sleeps (`SSHConnectPolicy`) = ~33 s worst case on a slow auth.
3. **Background → foreground always respawns `hermes acp`** (`pauseInBackground` CV:~3135, pool evicted at `ScarfGoCoordinator.swift:95`). Explains "ACP process terminated unexpectedly" on reopen. Comment at CV:369-382 ("1-2 s reconnect") is stale for backgrounding.
4. `HermesVersionCache` cold probe (`hermes --version`, 10 s, retries 1.5/4 s) on resume (CV:3743) after its 10-min TTL.
5. Serial post-load DB reads: 3–5 RemoteSQLite preflight + query execs per resume (`SessionResume.fetchSource`, `fetchCwd`, `loadSessionHistory`), each re-running the sqlite preflight.

## Plan (slices)
**S1 — Measure (do first, small).** Add ScarfMon timers around each start/resume step: preflight, project resolve, ACP SSH connect, `hermes acp` initialize, session/load, fetchSource, version probe, loadSessionHistory. Surface them in ScarfGo's existing diagnostics/ScarfMon export so the reporter can send numbers. Reproduce locally against a Docker Hermes (config not visible over SFTP) to confirm suspect 1.

**S2 — Preflight off the critical path (likely the main win).**
- Cache the preflight's "configured" result per server for the app session; re-check only when it last failed or the user changes model. A wrong "configured" verdict costs nothing extra: Hermes itself errors on the first prompt, which Scarf already surfaces.
- Show "Connecting…" before any network work.
- Mirror the Mac, which uses already-loaded capabilities instead of re-reading config per start.

**S3 — Reuse DB preflight within one resume.** One `HermesDataService` per resume instead of three fresh ones (fetchSource, fetchCwd, loadSessionHistory each re-preflight).

**S4 — Decide (with Alan) on background behaviour.** Keeping ACP alive across background isn't possible on iOS long-term, but a short grace (don't kill on brief app switches) or faster resume could be. Bigger design question; out of scope until S1 numbers say it matters.

Not planned: pooling the ACP SSH connection onto the Citadel pool (larger change; only if S1 shows connect cost dominates).

## Blast radius
- S2 touches iOS chat start/resume only (ChatView.swift preflight, a small per-server cache). Risk: a stale "configured" when the user removed their model — Hermes reports it on first prompt.
- S3 touches the shared `SessionResume` used by the Mac too — must keep Mac behaviour identical (tests).
- No Hermes-version-gated surface (C1 n/a); no state.db writes (C3).

## Ask the reporter
Docker or native Hermes on the host? Does the Mac app (same host) open chats fast? Hermes version? After S1 ships in TestFlight, a ScarfMon export of one slow open.
