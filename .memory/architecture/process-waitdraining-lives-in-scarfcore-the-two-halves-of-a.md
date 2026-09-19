---
title: Process.waitDraining lives in ScarfCore — the two halves of a piped spawn, and the poll-interval trap
type: note
permalink: scarf/architecture/process-waitdraining-lives-in-scarfcore-the-two-halves-of-a
tags: [c10, process, spawn-discipline, scarfcore]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProcessTimeout.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteRestoreService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteBackupService.swift, scarf/scarf/Core/Services/ProjectTemplateService.swift, scarf/scarfTests/MainActorSpawnDisciplineP22Tests.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-09-11
updated: 2026-09-18
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

## Observations

- [invariant] **An `async` caller uses `waitDrainingAsync`, never `waitDraining`.** The synchronous form is a `Thread.sleep` poll loop; from `async` code it parks a COOPERATIVE-POOL thread for the whole budget (300 s at the tarball push), and that pool is one thread per core and cannot grow. `waitDrainingAsync` runs the reap on a dedicated thread and suspends the caller on a continuation. `Task.detached` is NOT the escape — it is the same pool; `SpotifyAuthFlow.reapDetached` uses it correctly for a different purpose (getting off the MAIN actor). `ProcessAsyncWaitP43cTests.noSynchronousReapInAsyncCode` sweeps ScarfCore for the synchronous spelling inside an `async func`, with a calibrated matcher and a `scanned > 100` premise floor (round-4 P43c) #c10
- [invariant] **`ProcessPipeDrain` gives each reader its own THREAD, not a global-queue block.** `readDataToEndOfFile` blocks until the child closes its end, which is unbounded from this side; GCD's global queues are fixed-width, so several piped spawns in flight can park every thread of `.utility` and leave the NEXT spawn's drain unscheduled — at which point that child fills its 64 KB stderr buffer and wedges, which is this file's own deadlock re-entered from outside. Making the readers threads removed a long-standing `swift test` flake and took the ScarfCore run from 31.7 s to 25 s (round-4 P43c) #c10
- [gotcha] **The pump's `EAGAIN` wait is `poll(2)`, not a sleep.** A flat 20 ms nap moves one pipe-full per tick whatever the link can do — 4138 MB/s blocking against 2.8 MB/s asleep on a 64 MB payload. `RemoteRestoreService.waitWritable` polls for `POLLOUT` with a timeout of `min(remaining stall budget, pumpPollSlice)` (200 ms), so it wakes on the byte AND stays capped, which is where `Task.checkCancellation()` gets its turn. That 200 ms block on a cooperative thread is deliberate and is not the hazard `waitDrainingAsync` removes: bounded tightly, it is cheaper than the hop that would avoid it #c10
- [convention] **A give-up arm quotes the child.** Every abandon path in `streamTarball` returns the drained output and appends `RemoteRestoreService.outputTail` (last four non-blank lines) to its error — a `tar` that stopped cooperating said why on stderr, and "Broken pipe" alone is the consequence with the cause thrown away. `drainCollectGrace` is 5 s rather than the 1 s default for the same reason #conventions
- [gotcha] **`ProcessPipeDrain.collect(grace:)` holds one lock across the WAIT.** The check-then-set version (latch read under one lock, written under another) let two callers both find it empty, both wait, and each return whatever had arrived by its own deadline. It is an `NSLock` and not an `OSAllocatedUnfairLock` precisely because it is held across a blocking wait
- [invariant] `Process.waitDraining`/`waitUntilExit(timeout:)` live ONCE, in `ScarfCore/Models/ProcessTimeout.swift` behind `#if !os(iOS)`; the Mac target reaches them through `import ScarfCore`. They moved DOWN in round-4 P43 because a package cannot import its client and ScarfCore had the last unbounded waits #c10
- [gotcha] A bounded poll is NOT the second half of C10. `run` -> bounded poll -> `readToEnd()` still deadlocks a child past the 64 KB pipe buffer; it just ends in a timeout instead of a hang, so the caller reports failure for a child that was working. Every fix in P43 was this exact shape #c10
- [gotcha] `waitUntilExit(timeout:)` sleeps `pollInterval` (0.05 s) before re-checking, so a budget SMALLER than that is really "50 ms or one poll turn, whichever is later". A test passing `timeout: 0.001` and expecting an overrun must give the child work that outlasts 50 ms, not 1 ms #testing
- [convention] `waitDraining` owns the READ ends (each reader closes the handle it drained) and the caller owns the WRITE ends. A caller-side `close()` of a read end after it returns can raise on the drain-overrun path; a caller that forgets the write ends leaks nothing after a successful spawn (measured — see below), but does leak them when `run()` threw #conventions
- [fact] The P22 main-actor sweep has NO allowances left, so its `isolatedScanned == allowed.count` floor is 0 == 0 and proves nothing. `MainActorSpawnDisciplineP22Tests.theSweepMatcherStillRecognisesEveryShape` plants each shape and each near-miss against the named matcher — that calibration is what keeps the sweep honest. P43b added the other missing half: a `filesScanned` premise floor (`> 20` per root, `> 450` total, against a real 559), a `try #require` on each enumerator instead of a silent `continue` past `nil`, and a `sweepRootsExist` test #testing
- [invariant] The drain must be installed before the parent's LAST WRITE to the child, not merely before its first read. `Process.startDraining(pipes:)` + `waitDraining(timeout:drain:)` is the split for a caller that feeds the child (`RemoteRestoreService.streamTarball`); the combined `waitDraining(timeout:pipes:)` is right only when the parent has nothing left to send. P43b: the tarball push had the drain AFTER the pump, so it blocked in `write()` before ever reaching its own timeout #c10
- [gotcha] A blocked `write()` into a child cannot be rescued from outside: a SIGKILL to the one pid leaves grandchildren holding the read end, and the process group is Scarf's own. The pump writes `O_NONBLOCK` and takes its stall ceiling and its cancellation check at `EAGAIN`; `F_SETNOSIGPIPE` on the write fd makes `EPIPE` a return value rather than a signal #c10
- [fact] Measured over 50 spawns: leaving a `Pipe`'s READ ends open costs 2 fds each (`/dev/fd` 4 → 104); leaving the WRITE ends open costs nothing (4 → 4), because Foundation closes the parent's copy at spawn. The write-end closes at the call sites are kept as the launch-failure path's real release, not as a leak fix

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[A ScarfCore test that blocks the main thread or a pool thread fails unrelated suites in the full run]]


## Round-5 P48 — one drain in the app, and the async escalation

- [invariant] **`ProcessPipeDrain` is the ONLY drain.** `ProcessPipeDrainer` (an `enum` in
  `Transport/ProcessPipeDrainer.swift`, used by both Mac transports' `runProcess`/`runLocal`) is
  DELETED. It was a second implementation of this file's job carrying both defects P43c had
  already fixed here — an unbounded `Capture.wait()` and readers on the fixed-width
  `.utility` global queue — and it never received them because it had a different name. A
  `ProcessAsyncWaitP43cTests` sibling sweeps ScarfCore for the symbol so a third cannot appear
  quietly #c10
- [invariant] **`ServerTransport.runProcess`'s `timeout` is NON-OPTIONAL** (round-5 decision 5),
  across the protocol, `LocalTransport`, `SSHTransport`, `CitadelServerTransport` and every test
  double. The `nil` arm it deletes was a bare `waitUntilExit()` in both Mac conformers. On iOS the
  parameter had been accepted and then never read — `asyncRunProcess` drained the Citadel stream to
  its end with no ceiling — and it races the drain against the budget now #c10
- [invariant] **An escalation is a wait too.** `waitUntilExit(timeout: 0)` is the house spelling
  for "the deadline is gone, stop this child now", and it still sleeps through up to two
  `signalGrace` windows — so from `async` code it needs `Process.waitUntilExitAsync(timeout:)` or
  `waitDrainingAsync(timeout: 0, drain:)`, never the synchronous form. P48 added the first of those
  after the widened sweep found eleven such calls sitting directly in `Task` closures #c10
- [invariant] **`StreamingChild` owns a streaming spawn's child.** The four streaming spawns
  (`streamLines` / `streamRawBytes` on each Mac transport) install
  `continuation.onTermination` and reap through it, and drain stderr with `startDraining` for the
  whole run. The box exists because `onTermination` is installed BEFORE `run()` returns, so cancel
  and adopt race; whichever is second reaps #c10
- [gotcha] **`Task.detached` is the same cooperative pool, and the sweep now READS closures.**
  `ProcessAsyncWaitP43cTests` matches three shapes over two roots (`Sources/ScarfCore` and
  `scarf/scarf`): a blocking spelling directly in an `async` body, one inside a `Task { … }` /
  `Task.detached { … }` closure, and one reached through a synchronous helper declared in the same
  file. It does not follow a call across files. `SpotifyAuthFlow.reapDetached` — cited here as the
  shape to NOT copy — was itself one of the eleven and is on a thread now #testing
- [gotcha] **A dropped `Pipe` closes both of its descriptors.** Measured in P48: 50
  created-and-dropped `Pipe`s leave `/dev/fd` at 4; 50 `/bin/echo` spawns whose ATTACHED stdout
  pipe is never closed take it from 4 to 54, one per spawn. So a launch-failure arm that closes
  nothing does NOT leak — the leak needs a SPAWN — and round 5's three fd findings were all false
  for that reason. The explicit closes are kept as a stated release, not as a leak fix. This is the
  P43b correction ("every relaunch leaked two fds" was wrong) met a second time #verification
- [convention] **Take the property a cure supplies, not the type it came in.** `SSHScriptRunner`'s
  judge-at-exit bug is the `ProcessOutputInbox` family, but the inbox is String-based and drains
  destructively while that accumulator is `Data`; per-chunk decoding would split a UTF-8 sequence
  across a pipe read. `startDraining` + `collect(grace:)` has the property that mattered — wait for
  the last EOF, not for the process to go — and is the one primitive #conventions
- [invariant] **A bounded budget starts before `Process.run()`.** `RemoteBackupService.zipDirectory`
  and `RemoteRestoreService.unzipArchive` subtract the spawn's own cost from the caller's budget: a
  fork+exec is part of the operation the caller bounded, and starting the clock after it quietly
  grants the child however long the machine took to start it. It is also what let the overrun
  fixtures shrink to the bound (round-5 decision 8) #c10


## Round-5 P52 — `OffPool.run` is the house helper for blocking work

- [invariant] **`OffPool.run { }` (`ScarfCore/Models/OffPool.swift`) is how `async` code runs
  BLOCKING work.** It is the `withCheckedContinuation` + `Thread.detachNewThread` shape
  `Process.waitUntilExitAsync` already was, hoisted for the NON-`Process` callers — an SSH
  `readFile` (`NousSubscriptionService.loadState()`), `HermesFileService.enrichedEnvironment()`
  (a `static let` behind a `swift_once` whose initialiser is two `zsh` probes at 5 s + 3 s,
  `HermesFileService.swift:2566-2583`, probes at `:2575` and `:2580`), a `hermes` spawn. One call
  is one thread, so it is for BOUNDED one-shot work, never something long-running or repeating #c10
- [gotcha] **"Off the main actor" and "off the pool" are two different fixes, and `Task.detached`
  is only the first.** P22 asked the main-actor question and `Task.detached` answers it, so it is
  what a phase reaches for — P48 named this and P51 then created three more instances. Seven sites
  were on it at P52: `AuxiliaryTab.loadSubscription`, `NousAuthFlow.start` and
  `.handleTermination`, `EmbeddedSetupTerminal.start`, `ModelPickerSheet`'s `.task` and its
  sign-in completion, `PlatformSetupHelpers.detached` (the helper every setup form's load/save
  goes through), and `HealthViewModel`'s seven-way `async let` batch — whose own comment asserted
  `Task.detached` was what kept it off the pool #c10
- [invariant] **`OffPool.run` drops the RESULT on cancellation, never the work.** A `Thread`
  cannot be cancelled, so `work` always completes; the awaiting task abandons the value. That is
  identical to what `Task.detached { … }.value` did (a detached task inherits no cancellation),
  so every call site keeps its `guard !Task.isCancelled` after the hop — a caller that reads
  "off-main" as "cancellable" would write a cleanup that never runs #c10
- [testing] **The pool test is a RENDEZVOUS, not a stopwatch.** `OffPoolP52Tests` runs 32
  concurrent calls that each announce arrival and block until all 32 have arrived — a fixed-width
  pool cannot get past its own width, so a regression fails on the bounded arrival wait. The first
  draft compared elapsed time against a fraction of the serial total and went red in the full
  parallel `swift test` run purely from machine load (the same load made `ProcessDrainP43Tests`'s
  zip-overrun test fail in that run and pass under `--filter`). `OffPoolDisciplineP52Tests`
  (scarfTests) sweeps the three source roots for a blocking needle inside a `Task.detached` #testing


## Round-6 P58 — the READ half moves to `DispatchSourceRead` (`PipeReader`)

- [decision] **The four streaming spawns no longer block a pool thread, and the cure was one folder
  away with a different name.** `LocalTransport`/`SSHTransport` × `streamLines`/`streamRawBytes`
  read stdout with `Task.detached { while true { handle.availableData } }` — a blocking `read(2)`
  for the LIFE of the stream, and `HermesLogService` streams `tail -F`, which never ends. One open
  Logs pane held one cooperative-pool thread permanently. `ProcessACPChannel`'s private
  `PipeLineReader` had fixed exactly this in July; it is hoisted to
  `ScarfCore/Transport/PipeReader.swift`, generalised over FRAMING (`.rawChunks` / `.lines`) rather
  than copied, and ACP keeps its exact semantics through an `acpLines` factory. P48's lesson
  ("a second copy of a primitive is invisible precisely because it has a different name") applied
  before the copy existed #c10
- [gotcha] **The reader OWNS the read end, so the transports stop closing it.** The fd is closed in
  the `DispatchSourceRead` cancel handler and nowhere else — that is what makes a read unable to
  race a recycled descriptor. The close now happens BEFORE the `.finished` event in that handler, so
  a consumer acting on `.finished` cannot observe a still-open fd
- [decision] **`StreamingChild` adopts the reader too.** A consumer that drops the stream cancels
  the read as well as the child, so the producer task stops waiting instead of parking on EOF that
  a grandchild (ssh's ControlMaster) can withhold forever. `adoptReader` has `adopt`'s race: a
  consumer that let go during the spawn has already settled, so the reader is cancelled rather than
  stored
- [decision] **A child's trailing line with no newline is DELIVERED now** (`deliverPartialAtEOF`),
  and ACP still drops it — half a JSON-RPC frame is not a frame. `M3TransportTests` had recorded the
  drop as "the documented behaviour"; nothing depended on it, and the dropped line was a line of the
  user's log that silently never appeared
- [gotcha] **A test that proves "no thread is parked" cannot `await` its own timeout.** Under the
  regression the pool schedules nothing, so an `await`-based bound needs the very thread it is
  trying to prove is missing — the test HANGS instead of failing. The rendezvous blocks the test's
  own thread on a `DispatchSemaphore` (no scheduling needed), which is why the suite's helpers are
  deliberately `noasync` #testing
- [gotcha] **An `errno == EBADF` probe on a closed fd is a load flake.** The same suite opens dozens
  of pipes at once and the process reuses the lowest free descriptor immediately, so a recycled
  number is a perfectly valid fd. The assertion that survives recycling is `fstat` identity: the
  number must no longer name OUR pipe. Measured going red exactly this way in a starved run — P48's
  `/dev/fd` lesson one layer down #testing


## Round-6 P58b — a hoisted primitive carries its donor's semantics

- [gotcha] **A primitive hoisted from ONE consumer carries that consumer's semantics, and every other adopter silently re-derives each one.** P58 lifted `PipeLineReader` out of `ProcessACPChannel` and did the hard part right — it saw that ACP's trailing-partial DROP was ACP's and made `deliverPartialAtEOF` a parameter. It then shipped ACP's `guard !lineData.isEmpty else { continue }` as the framing's UNCONDITIONAL behaviour, so both `streamLines` transports lost every blank line: `printf 'a\n\nb\n'` yields `["a","","b"]` at `8dc79784` and `["a","b"]` at `b26c0a1f`. The only consumer is the Logs pane, where a blank separator IS a line of the user's log. **Parameterising one inherited semantic is evidence that the others were NOT audited, not that they were.** The rule: enumerate every branch the donor's behaviour depends on and ask the question once per branch — here two, `deliverPartialAtEOF` and `skipEmpty`, neither with a default (`081f4437`) #c10
- [decision] **A rationale written at one call site is an assertion; a needle is the enforcement.** P58 moved `HermesProxyService.start`'s spawn into `OffPool.run` because `run()` blocks on fork/exec, and left `HealthViewModel`, `MCPLoginController` and `OAuthFlowController` on `Task.detached { try proc.run() }`. All four agree now, and `run()` is the P52 sweep's EIGHTH needle — identifier-bounded, since `OffPool.run { … }` takes a closure and never spells the empty parens. It finds seven more (`SSHTransport` ×2, `SSHScriptRunner` ×2, `LocalTransport` ×2, `TestConnectionProbe`), baselined with counts on `t-406d56d6`: their `run()` sits inside pipe wiring and a drain it owns, so a mechanical wrap would move the plumbing too (`1e4c75b4`) #c10
- [gotcha] **`guard proc.isRunning` is a CHECK, not a hold.** `ProcessACPChannel`'s close watchdog then called `terminate()`, which on a process reaped in the gap raises an ObjC exception — uncatchable in Swift. `kill(pid, SIGTERM)` cannot trap: a stale pid returns ESRCH. The residual window is pid recycling, which nothing short of a pidfd closes and which `terminate()` did not close either; it is one STATED sentence now instead of an unexamined one (`720dbdc2`) #c10
- [fact] **`runSync` has EIGHT callers on iOS, not seven** — `ServerContext.UserHomeCache.probe` (`ServerContext.swift:343`) is unguarded ScarfCore compiled for iOS and still reaches the SYNCHRONOUS `runProcess` through `ServerContext.sshTransportFactory`. The Mac half of decision 11 stays on `t-02f830f4` #c10 #ios
- [gotcha] **A test timeout is a CEILING when only the failure path pays it, and a BET when the green path spends it.** The park test's four probes took 6.5 s of a 10 s bound under full-suite load; under the regression they never arrive at all — so the bound measured the grader's machine, not the defect. Raised to 60 s, with `EventInbox`'s waits and `OffPoolP52Tests`' 32-thread `allArrived` rendezvous (2 of 6 full parallel runs red on the reviewer's machine, not P58-induced) #testing



## Test-side runners (P4 Live Voice, 2026-09-18)

- [gotcha] Test helpers that run real shell or Python and read `Pipe`s to EOF hit this file's grandchild problem from the side. On 2026-09-18, under the full parallel `swift test`, a runner reading `/bin/sh` output through pipes stalled for 5 s and returned empty, while `--filter` passed. The likely cause is a sibling suite's concurrently spawned child holding the write end. `ShellTestRunner` in ScarfCoreTests writes the child's stdout and stderr to temp FILES and bounds the run with a timeout. Use it rather than pipes for tests that spawn processes. Since t-f1593849 it is `async`: it suspends on `terminationHandler` and never parks a pool thread. See [[A ScarfCore test that blocks the main thread or a pool thread fails unrelated suites in the full run]] #testing #c10



## SSHScriptRunner feeds scripts on stdin, non-blocking (2026-09-18)

- [invariant] **Both `SSHScriptRunner` paths run `/bin/sh -s` with the script on stdin, never in argv.** The local path used `/bin/sh -c <script>`, which let any user on the Mac read the script in `ps` while it ran. That exposed Live Voice's SDP offer (ICE credentials) and TTS text. `LocalScriptStdinTests` checks this with a real `ps` of the running shell and with a source pin #security
- [invariant] **The stdin feed is `ScriptFeeder`, a non-blocking pump called on each run-loop tick, not one blocking write.** `sh -s` reads its script as it executes. So a script larger than the pipe buffer whose early command stalls would block a plain `write` before the timeout loop even started. That is the P43b tarball bug in a new place. The write end is `O_NONBLOCK` + `F_SETNOSIGPIPE`. The SSH path had the same blocking write and was fixed at the same time #c10
- [gotcha] **A `ps -p $$` probe at the END of a `sh -c` script sees `ps`, not `sh`.** sh runs the last simple command with `exec`, which replaces the shell, so `$$` then names `ps`. Wrap it (`echo "$(ps -o args= -p $$)"`) or the test passes for the wrong reason #testing
