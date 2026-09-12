---
id: t-cd9fd829
title: Move HealthViewModel.dashboardListenerPID's lsof wait off the main actor
status: done
added: 2026-09-10
---

## Description

Found by P37's new `MainActorSpawnDisciplineP22Tests.noNewSynchronousWaitRunsOnTheMainActor` sweep once its isolation gate was corrected.

`HealthViewModel.dashboardListenerPID(port:)` at `scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift:1207` is `private static func` on `final class HealthViewModel` (`:44`, `@Observable`, no `nonisolated`). The Mac app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`scarf/scarf.xcodeproj/project.pbxproj:606,649,910,947`), so that function is MAIN-ACTOR ISOLATED. Inside it:

- `lsof.waitUntilExit(timeout: lsofTimeout)` (`:1226`) — a bounded but synchronous process wait.
- `readerFinished.wait(timeout: .now() + Self.drainGrace)` (`:1231`) — a bounded `DispatchSemaphore.wait`.

Charter C10: "never block first paint or the main actor on process spawns". The timeouts satisfy the second half of C10 (every subprocess has a timeout) but not the first: a wedged `lsof` (stuck NFS/FUSE mount, unresponsive socket) freezes the window for the whole `lsofTimeout`.

Fix: run the probe off-main the way `PlatformSetupHelpers.detached` / P22's other sites do, and have the caller await the answer. Note `launchDashboard()` / `stopDashboard()` are the callers.

When it lands, remove `HealthViewModel.swift` from the `allowed` set in `scarf/scarfTests/MainActorSpawnDisciplineP22Tests.swift`'s `noNewSynchronousWaitRunsOnTheMainActor` — the test asserts each allowance is still real, so a stale entry will not fail but should not linger.

Related: `t-b15ba4c3` is the same class of debt for `AppRelauncher.relaunch()`.

Also worth a follow-up in the same pass: that sweep only matches `waitDraining` / `waitUntilExit`. `DispatchGroup.wait` / `DispatchSemaphore.wait` are synchronous waits too and appear at `ProcessTimeout.swift:120`, `HealthViewModel.swift:1231`, `LocalTransport.swift:256/283/291`, `SSHTransport.swift:1109/1117/1129`, `ProcessPipeDrainer.swift:41`. Extending the scan to those needs a triage pass over each site first (most are legitimately off-main), which is why P37 left the primitive set at two.

## Plan



## Artifacts

Closed by P38 item 12 (commit on `fix/whole-surface-audit-r3`).

`HealthViewModel.dashboardListenerPID(port:)` is now `private nonisolated static func` and its body is `lsof.waitDraining(timeout: Self.lsofTimeout, pipes: [output])` — the primitive that was hoisted OUT of this very function in P33 and that this copy never adopted. The hand-rolled `DispatchSemaphore` drain, the private `drainGrace` constant, and the never-closed `output.fileHandleForReading` all went with it (`waitDraining` owns the read ends' lifetime).

`nonisolated` is the right shape rather than "await the answer": the only caller is already inside `Task.detached` in `stopDashboard()`, so the probe never ran on the main actor in practice — it was only ISOLATED to it, which is what the sweep measures.

`HealthViewModel.swift` removed from `allowed` in `MainActorSpawnDisciplineP22Tests.noNewSynchronousWaitRunsOnTheMainActor` (P38 item 23). That sweep also grew the follow-up this ticket asked for: it now matches a synchronous `Process.isRunning` spin (body must be `Thread.sleep`/`usleep`, so an `await Task.sleep` loop is correctly not a finding) and a `.wait(` on a name bound to a `DispatchSemaphore`/`DispatchGroup` in the same file, with `ProcessTimeout.swift` excluded as the primitives' own implementation. Triaging the new shapes also fixed a real blind spot in the walk: a MULTI-LINE declaration signature made the opt-out walk land on the signature's closing line and never see the `nonisolated` on the opening one, which falsely flagged `ProjectTemplateService.runToolCapturingOutput` and would have flagged any other multi-line `nonisolated` signature.

Verified by reverting `nonisolated`: the sweep then reports `HealthViewModel.swift:1209` as an offender and `isolatedScanned == allowed.count` fails.

