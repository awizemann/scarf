# WS-2 Plan: Persistent Goals + ACP `/queue`

> **Historical plan — `hasACPSteerOnIdle` was retired in round 4** (decision 14; see
> `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md`). The flag was `hasACPSteer`
> expressed a second time — `/steer`'s idle fallback shipped in its own commit
> (`acp_adapter/server.py:812-820` @ `v2026.5.7`) — so the idle-steer grey-out arm below could
> never fire and both the flag and the arm are gone. The rest of the plan stands as shipped.

Branch suggestion: `ws-2-goals-and-queue-v0.13`. Depends on WS-1 (`ws-1-capabilities-v0.13`, PR #80) for the three v0.13 capability flags consumed below.

## Goals (what this PR ships)

User-visible features (all capability-gated, all degrade silently on pre-v0.13 hosts):

- `/goal <text>` slash command, surfaced in the slash menu, sent as a non-interruptive prompt (no "Agent working…" flip).
- `/goal --clear` slash command (and a quick-clear affordance on the goal pill itself) to drop the active goal.
- A "Goal locked" pill in the chat header (mounted alongside the project / branch chips in [SessionInfoBar](../../scarf/Features/Chat/Views/SessionInfoBar.swift)). Hidden when no active goal.
- `/queue <text>` slash command, surfaced in the slash menu, non-interruptive, with a transient toast (`Queued — runs after current turn`) reusing the existing `transientHint` machinery.
- `/queue` listing affordance: a small chip in the chat header showing queued-prompt count, expanding to a popover with the queued-prompt previews when there are any pending entries (Mac only — iOS gets a read-only listing affordance in WS-9).
- `/steer` on idle: pre-v0.13 hosts grey-out `/steer` and `/queue` and `/goal` in the slash menu when the session is idle (they do nothing useful there); v0.13+ hosts allow `/steer` to fire on idle sessions and treat it as a regular prompt.
- iOS read-only "Goal locked" pill (added in WS-9, plumbed here so the VM is iOS-ready).

Out-of-scope items captured in [Out of scope](#out-of-scope-deferred).

## Files to change

### [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesSlashCommand.swift](../../Packages/ScarfCore/Sources/ScarfCore/Models/HermesSlashCommand.swift)

- Re-use the existing `Source.acpNonInterruptive` enum case — `/goal` and `/queue` slot in there alongside `/steer`. No new source case is needed (a "non-interruptive" command, regardless of whether it sets a goal or queues a turn, has the same wire shape: send through `ACPClient.sendPrompt`, do not flip "Agent working…").
- No struct changes needed.

### [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesActiveGoal.swift](../../Packages/ScarfCore/Sources/ScarfCore/Models/HermesActiveGoal.swift) (NEW)

Plain value type:

```swift
public struct HermesActiveGoal: Sendable, Equatable, Identifiable {
    public let text: String
    public let setAt: Date
    public var id: String { text + "@" + ISO8601DateFormatter().string(from: setAt) }
}
```

Lives next to `HermesSession.swift` and `HermesSlashCommand.swift`. Used by the goal pill and the goal viewmodel state (read-only — no mutation API on the struct).

### [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesQueuedPrompt.swift](../../Packages/ScarfCore/Sources/ScarfCore/Models/HermesQueuedPrompt.swift) (NEW)

Plain value type for one queued prompt:

```swift
public struct HermesQueuedPrompt: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let queuedAt: Date
}
```

Used by `RichChatViewModel.queuedPrompts` and the queue-popover view. The `id` is a Scarf-side UUID minted at queue-time — Hermes' wire protocol doesn't expose a per-queue-entry id (see [Open questions](#open-questions)).

### [scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift](../../Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift)

This is the load-bearing change. All changes are MainActor-isolated; no sync I/O is added.

**1. Extend `nonInterruptiveCommands` (currently around [RichChatViewModel:251-258](../../Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift)):**

Today the list contains only `/steer`. Add `/goal` and `/queue`. Per the existing contract these are appended unconditionally — capability gating is applied in `availableCommands` (next change). Each entry uses `source: .acpNonInterruptive` so the existing `isNonInterruptiveSlash(_:)` helper at [RichChatViewModel:331-342](../../Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift) auto-recognizes them.

```swift
public static let nonInterruptiveCommands: [HermesSlashCommand] = [
    HermesSlashCommand(name: "steer", description: "...", argumentHint: "<guidance>", source: .acpNonInterruptive),
    HermesSlashCommand(name: "goal",  description: "Lock the agent on a goal that persists across turns",
                       argumentHint: "<text>", source: .acpNonInterruptive),
    HermesSlashCommand(name: "queue", description: "Queue a prompt to run after the current turn",
                       argumentHint: "<text>", source: .acpNonInterruptive),
]
```

**2. Capability-gated filtering of the static list.**

`availableCommands` (currently [RichChatViewModel:304-325](../../Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift)) merges the static `nonInterruptiveCommands` unconditionally. Replace that with a filter against a new public `capabilitiesGate` value the controller sets at session-start time:

```swift
@ObservationIgnored public var capabilitiesGate: HermesCapabilities = .empty
```

Inside `availableCommands`, after building `acpNames` / `projectNames` / `quicks`:

```swift
let supported: [HermesSlashCommand] = Self.nonInterruptiveCommands.filter { cmd in
    switch cmd.name {
    case "goal":  return capabilitiesGate.hasGoals
    case "queue": return capabilitiesGate.hasACPQueue
    case "steer": return true        // present pre-v0.13 too; idle gating handled separately
    default:      return true
    }
}
let nonInterruptive = supported.filter { !occupied.contains($0.name) }
return acpCommands + projectAsHermes + quicks + nonInterruptive
```

**3. Active goal state.**

Add observable storage:

```swift
public private(set) var activeGoal: HermesActiveGoal?
```

Reset to nil in `reset()` (around [RichChatViewModel:441-478](../../Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift)).

Add a slim mutator `recordActiveGoal(text: String?)`:

```swift
@MainActor public func recordActiveGoal(text: String?) {
    if let text, !text.isEmpty {
        activeGoal = HermesActiveGoal(text: text, setAt: Date())
    } else {
        activeGoal = nil
    }
}
```

Two callers will populate this: (a) the slash-command handler in `ChatViewModel.sendViaACP` / `ChatController._sendImpl` does an optimistic write the moment the user presses send (`/goal foo` → record `foo`; `/goal --clear` → record nil), so the pill appears synchronously without waiting for a server round-trip; (b) a future ACP-side signal could correct it (see [Open questions](#open-questions)).

**4. Queued-prompt state.**

Add observable storage:

```swift
public private(set) var queuedPrompts: [HermesQueuedPrompt] = []
```

Reset to empty in `reset()`.

Add mutators:

```swift
@MainActor public func recordQueuedPrompt(text: String) {
    queuedPrompts.append(HermesQueuedPrompt(id: UUID(), text: text, queuedAt: Date()))
}

@MainActor public func clearAllQueuedPrompts() { queuedPrompts.removeAll() }

@MainActor public func popQueuedPrompt() -> HermesQueuedPrompt? {
    queuedPrompts.isEmpty ? nil : queuedPrompts.removeFirst()
}
```

`recordQueuedPrompt` is called optimistically when the user sends `/queue ...`. `popQueuedPrompt` runs inside `handlePromptComplete` (currently [RichChatViewModel:763-820](../../Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift)) when the agent finishes a turn — Hermes is responsible for actually running the queued prompt (it lives server-side); the Scarf-side list is purely a UI mirror. Popping is best-effort: if Hermes' server-side queue gets out of sync (deferred prompt aborted, dropped on disconnect), the user sees a stale chip until their next interaction. We accept that v1 trade-off; see [Open questions](#open-questions).

**5. `/goal` argument parsing helper (test-friendly).**

```swift
public enum GoalCommandArgument: Equatable {
    case set(String)
    case clear
    case empty // user typed `/goal` with no argument
}

public static func parseGoalArgument(_ raw: String) -> GoalCommandArgument {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .empty }
    if trimmed == "--clear" || trimmed == "clear" { return .clear }
    return .set(trimmed)
}
```

Pure function, no MainActor. Lets `M9SlashCommandTests` exercise the parser directly.

### [scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift](../../scarf/Features/Chat/ViewModels/ChatViewModel.swift) (Mac)

**1. Plumb capabilities into the VM.**

Today the VM doesn't carry a reference to `HermesCapabilitiesStore`. Add a stored property + initializer overload:

```swift
@ObservationIgnored var capabilitiesStore: HermesCapabilitiesStore?
```

`ChatView` passes the env-resolved store in via `.task` (or `.onAppear`) and the VM forwards `capabilitiesStore.capabilities` into `richChatViewModel.capabilitiesGate` whenever the store's `capabilities` changes (use a one-shot `.task(id: capabilities)` modifier on the chat view to re-publish on refresh).

Rationale: the slash menu's `availableCommands` filter (above) needs the live capabilities. `ChatViewModel` is `@Observable`; storing the snapshot directly here would force the entire VM to re-render on capability refreshes — using `@ObservationIgnored` + an explicit "publish" call into RichChatViewModel keeps re-render scope tight.

**2. Detect non-interruptive commands by name in `sendViaACP` (currently [ChatViewModel:556-635](../../scarf/Features/Chat/ViewModels/ChatViewModel.swift)).**

The current `isSteer` branch only special-cases the toast. Extend it to dispatch:

```swift
let trimmedSlash = parseSlashName(text)        // small helper, returns (name: String?, args: String)
let isNonInterruptive = richChatViewModel.isNonInterruptiveSlash(text)

switch trimmedSlash.name {
case "goal":
    let arg = RichChatViewModel.parseGoalArgument(trimmedSlash.args)
    switch arg {
    case .set(let goalText):
        richChatViewModel.recordActiveGoal(text: goalText)
        richChatViewModel.transientHint = "Goal locked: \(goalText)"
    case .clear:
        richChatViewModel.recordActiveGoal(text: nil)
        richChatViewModel.transientHint = "Goal cleared."
    case .empty:
        // Agent will respond with usage; show neutral hint.
        richChatViewModel.transientHint = "Sent /goal — see the agent reply for current goal."
    }
    scheduleHintClear()
case "queue":
    let queuedText = trimmedSlash.args.trimmingCharacters(in: .whitespacesAndNewlines)
    if !queuedText.isEmpty {
        richChatViewModel.recordQueuedPrompt(text: queuedText)
    }
    richChatViewModel.transientHint = "Queued — runs after current turn."
    scheduleHintClear()
case "steer" where isNonInterruptive:
    richChatViewModel.transientHint = "Guidance queued — applies after the next tool call."
    scheduleHintClear()
default:
    if !isNonInterruptive { acpStatus = ACPPhase.agentWorking }
}
```

`scheduleHintClear()` extracts the existing 4-second auto-clear pattern (currently inlined for `/steer` at [ChatViewModel:585-591](../../scarf/Features/Chat/ViewModels/ChatViewModel.swift)) into a private helper, so all three commands use the same clear behaviour. The wire send (the existing `client.sendPrompt(...)` call at [ChatViewModel:597](../../scarf/Features/Chat/ViewModels/ChatViewModel.swift)) is unchanged — Hermes parses the slash on the server side.

**3. Clear active goal state on session reset.**

`startNewSession` (and `resumeSession`, `continueLastSession`) call `richChatViewModel.reset()` which already resets `activeGoal` and `queuedPrompts` (from change #3 above in the VM). Confirm `stopACP()` doesn't need an additional clear — it doesn't, because reset() is the explicit teardown.

**4. `/steer` on idle pre-v0.13.**

In the slash menu (rendered by `SlashCommandRow` — see Slash menu changes below), grey-out `/steer` when:

```swift
!richChatViewModel.isAgentWorking && !capabilitiesGate.hasACPSteerOnIdle
```

Tooltip / disabled state: "Use `/steer` while the agent is working — your Hermes version doesn't support steering on idle sessions."

### [scarf/scarf/Features/Chat/Views/SlashCommandMenu.swift](../../scarf/Features/Chat/Views/SlashCommandMenu.swift)

Add a new `disabled: Bool` parameter to `SlashCommandRow`. When disabled, render the row at 0.55 opacity, prevent `onTapGesture` from firing, and append a one-line subtitle "(use during a turn)". Also accept a `disabledReason: String?` for the tooltip.

Plumb the disabled state through from the parent (`RichChatInputBar`). Logic stays in the parent: a row is disabled iff `(name == "steer") && isIdle && !hasACPSteerOnIdle`. Goal/queue rows are never grey when present (they're already filtered out when their cap is off).

### [scarf/scarf/Features/Chat/Views/SessionInfoBar.swift](../../scarf/Features/Chat/Views/SessionInfoBar.swift)

Add the goal pill alongside the existing project / branch chips. Two new optional inputs:

```swift
var activeGoal: HermesActiveGoal? = nil
var onClearGoal: (() -> Void)? = nil
```

Render block (positioned right after the existing `gitBranch` Label, before the working dot at [SessionInfoBar:65](../../scarf/Features/Chat/Views/SessionInfoBar.swift)):

```swift
if let activeGoal {
    HStack(spacing: 4) {
        Image(systemName: "scope")
        Text(truncatedGoal(activeGoal.text))
    }
    .scarfStyle(.caption)
    .padding(.horizontal, ScarfSpace.s2)
    .padding(.vertical, 2)
    .background(Capsule().fill(ScarfColor.info.opacity(0.16)))
    .foregroundStyle(ScarfColor.info)
    .help("Goal locked: \(activeGoal.text)")
    .contextMenu {
        if let onClearGoal {
            Button("Clear goal", role: .destructive, action: onClearGoal)
        }
    }
}

private func truncatedGoal(_ text: String) -> String {
    text.count <= 36 ? text : String(text.prefix(33)) + "…"
}
```

Color choice: `ScarfColor.info` matches the badge intent — informational state, not a warning, not an error. Per CLAUDE.md, accent (rust) is reserved for primary brand surfaces; project / branch already use accent so reusing it would mean three accent chips in a row. `info` differentiates the goal pill visually.

The `onClearGoal` closure flows from `ChatViewModel`: when invoked, it dispatches `sendText("/goal --clear")` so Hermes' authoritative state stays in sync (the optimistic local clear happens via the send-path in `sendViaACP`).

### [scarf/scarf/Features/Chat/Views/ChatTranscriptPane.swift](../../scarf/Features/Chat/Views/ChatTranscriptPane.swift)

Forward the new `SessionInfoBar` parameters at [ChatTranscriptPane:17-25](../../scarf/Features/Chat/Views/ChatTranscriptPane.swift):

```swift
SessionInfoBar(
    session: richChat.currentSession,
    isWorking: richChat.isGenerating,
    acpInputTokens: richChat.acpInputTokens,
    acpOutputTokens: richChat.acpOutputTokens,
    acpThoughtTokens: richChat.acpThoughtTokens,
    projectName: chatViewModel.currentProjectName,
    gitBranch: chatViewModel.currentGitBranch,
    activeGoal: richChat.activeGoal,
    onClearGoal: { chatViewModel.sendText("/goal --clear") }
)
```

### [scarf/scarf/Features/Chat/Views/ChatQueueIndicator.swift](../../scarf/Features/Chat/Views/ChatQueueIndicator.swift) (NEW)

Small chip + popover for the queued-prompt list. Mounted in `SessionInfoBar` next to the goal pill, but extracted to its own file because it owns popover state.

```swift
struct ChatQueueIndicator: View {
    let queuedPrompts: [HermesQueuedPrompt]
    var onClearAll: () -> Void
    @State private var isPopoverShown = false

    var body: some View {
        if queuedPrompts.isEmpty { EmptyView() } else {
            Button {
                isPopoverShown = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full")
                    Text("\(queuedPrompts.count) queued")
                }
                .scarfStyle(.caption)
                .padding(.horizontal, ScarfSpace.s2)
                .padding(.vertical, 2)
                .background(Capsule().fill(ScarfColor.warning.opacity(0.16)))
                .foregroundStyle(ScarfColor.warning)
            }
            .buttonStyle(.plain)
            .help("Prompts waiting to run after the current turn finishes")
            .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
                queuePopover
            }
        }
    }

    @ViewBuilder private var queuePopover: some View { /* list + clear-all action */ }
}
```

Color: `.warning` (amber) — these are pending side-effects the user should notice. Distinct from goal (`.info`) and project (`.accent`) so all three chips are visually decodable.

Caveat: this chip is OPTIMISTIC. The popover header includes a one-line note: "Local view — Hermes manages the actual queue." The popover offers "Clear all" but NOT individual deletion (Hermes has no per-entry remove verb; clearing locally would diverge from server state). "Clear all" sends `/queue --clear` if Hermes accepts that syntax (see [Open questions](#open-questions)) and otherwise just resets the local mirror with a tooltip explaining the discrepancy.

### [scarf/Scarf iOS/Chat/ChatView.swift](../../Scarf%20iOS/Chat/ChatView.swift) — DEFERRED to WS-9

The iOS chat already wires non-interruptive commands at [ChatView:1310-1322](../../Scarf%20iOS/Chat/ChatView.swift) and uses the same `RichChatViewModel`, so the model-side changes are picked up automatically. Surface changes (read-only goal pill, queue chip) belong in WS-9 per the work-stream split. **Do not** add iOS UI changes in this PR — keep the diff scoped.

**Exception:** the iOS controller's `_sendImpl` at [ChatView:1291-1342](../../Scarf%20iOS/Chat/ChatView.swift) needs the same dispatch changes as Mac (record the optimistic goal/queue mutation when the user types `/goal` or `/queue`), otherwise the iOS VM state will diverge from Mac. Mirror change #2 from `ChatViewModel.swift` above into the `_sendImpl` body. iOS just doesn't *render* the goal pill / queue chip yet — that's WS-9.

### [scarf/Packages/ScarfCore/Tests/ScarfCoreTests/M9SlashCommandTests.swift](../../Packages/ScarfCore/Tests/ScarfCoreTests/M9SlashCommandTests.swift)

Extend with v0.13 cases. The current file tests project-scoped commands and the context block; add a new section "v0.13 non-interruptive commands":

- `nonInterruptiveListIncludesGoalAndQueue` — `RichChatViewModel.nonInterruptiveCommands.map(\.name)` contains both names.
- `availableCommandsHidesGoalWhenCapabilityOff` — set `capabilitiesGate = .empty`, assert `goal` not in `availableCommands`.
- `availableCommandsHidesQueueWhenCapabilityOff` — same for `queue`.
- `availableCommandsExposesAllThreeOnV013` — set `capabilitiesGate = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")`, assert all three are present.
- `parseGoalArgumentRecognizesClearVariants` — `--clear`, `clear`, `Clear`, `  --clear  ` all return `.clear`.
- `parseGoalArgumentReturnsSetForArbitraryText` — `"finish v2.8 on time"` → `.set("finish v2.8 on time")`.
- `parseGoalArgumentReturnsEmptyForBlank` — `""` and `"   "` return `.empty`.
- `recordActiveGoalSetsAndClears` — call `recordActiveGoal(text: "x")` then `recordActiveGoal(text: nil)` on a fresh VM, assert observable transitions.
- `recordQueuedPromptAppendsAndPopsFIFO` — append three, pop two, verify order + remaining count.
- `clearAllQueuedPromptsEmpties` — straightforward.
- `isNonInterruptiveSlashRecognizesGoalAndQueue` — verify `/goal foo`, `/queue bar`, `/queue` (no args) all return `true`.
- `resetClearsGoalAndQueue` — set both, call `reset()`, assert both empty.

All MainActor-bound; use `@MainActor @Test` annotations. The current suite uses `@Suite` with default isolation, which is fine.

### [scarf/Packages/ScarfCore/Tests/ScarfCoreTests/HermesCapabilitiesTests.swift](../../Packages/ScarfCore/Tests/ScarfCoreTests/HermesCapabilitiesTests.swift)

WS-1 already added cases for `hasGoals` / `hasACPQueue` / `hasACPSteerOnIdle`. No further changes needed unless the existing tests don't assert all three are true on `v0.13.0` and false on `v0.12.0` — verify this is covered before merging WS-2.

## New types / fields

| Type | Where | Purpose |
| --- | --- | --- |
| `HermesActiveGoal` | new ScarfCore model | observable goal-pill state |
| `HermesQueuedPrompt` | new ScarfCore model | one queued-prompt mirror entry |
| `RichChatViewModel.GoalCommandArgument` | nested enum on the VM | pure parser for `/goal` arg |
| `RichChatViewModel.activeGoal` | observable | drives the pill |
| `RichChatViewModel.queuedPrompts` | observable | drives the chip + popover |
| `RichChatViewModel.capabilitiesGate` | non-observable | filters non-interruptive commands |
| `ChatViewModel.capabilitiesStore` | non-observable | bridge from env → VM |
| `ChatQueueIndicator` (Mac view) | new chat view | header chip |

No new ACP RPC types; we ride the existing `session/prompt` shape. No DB schema changes.

## Capability gating

| Affordance | Gate | Pre-v0.13 behaviour |
| --- | --- | --- |
| `/goal` in slash menu | `hasGoals` | hidden |
| `/goal --clear` (also clear-from-pill) | `hasGoals` | n/a (no pill to clear; menu item also hidden) |
| Goal pill in `SessionInfoBar` | `activeGoal != nil` (which only becomes non-nil when user sends `/goal`, which requires the menu, which requires `hasGoals`) | hidden by transitive impossibility |
| `/queue` in slash menu | `hasACPQueue` | hidden |
| Queue chip in `SessionInfoBar` | `queuedPrompts.isEmpty == false` (transitive on `hasACPQueue`) | hidden |
| `/steer` greyed-out on idle | `hasACPSteerOnIdle == false && !isAgentWorking` | greyed; tooltip explains |
| `/steer` on idle (sent normally) | `hasACPSteerOnIdle == true` | works as regular prompt (server handles) |

Belt-and-suspenders defence: `availableCommands` filters BEFORE menu rendering; the dispatch in `sendViaACP` does NOT pre-validate (Hermes' server-side error message is more accurate than any client guard we'd write). If a user types `/goal` directly via a quick-command alias on a pre-v0.13 host, the slash gets sent to Hermes, which will respond with its own "unknown command" reply — acceptable v1 behaviour.

## How to test

### Unit tests

Run `swift test --package-path scarf/Packages/ScarfCore --filter M9SlashCommandTests`. Should be ~12 new tests; existing 23 stay green.

### Manual: v0.13 host

Prereq: Hermes v0.13.0 installed locally OR the dogfooding box (`192.168.0.82`) with `remote-servers` branch.

1. **Goal happy path:**
   - Open chat (any project / quick chat).
   - Type `/`, verify `/goal` appears in slash menu.
   - Send `/goal finish WS-2 by Friday` — confirm:
     - "Agent working…" does NOT flip on (non-interruptive).
     - Transient toast appears: "Goal locked: finish WS-2 by Friday".
     - "Goal locked" chip appears in `SessionInfoBar` next to project / branch.
     - Toast auto-dismisses after ~4s.
   - Send a normal prompt; verify the chip stays put across turns.
2. **Goal clear path:**
   - With a goal active, right-click the chip → "Clear goal".
   - Verify chip disappears, transient toast says "Goal cleared.", and the underlying `sendText("/goal --clear")` actually fires (check Hermes log).
   - Alternative path: type `/goal --clear` directly — same outcome.
3. **Queue happy path:**
   - Send a long-running prompt to occupy the agent.
   - While it's working, send `/queue summarize what you just did`.
   - Confirm: toast "Queued — runs after current turn.", chip appears showing "1 queued".
   - Click chip → popover lists the queued prompt with timestamp.
   - When the current turn finishes, verify Hermes runs the queued prompt automatically (server-side) AND the chip count decrements (via `popQueuedPrompt`).
4. **Steer-on-idle:**
   - On v0.13, send `/steer` on an idle session — confirm it sends as a regular prompt (no error, no "Agent working" indicator misbehaviour).
5. **Capability refresh:**
   - Connect to a remote running Hermes v0.12. Verify `/goal` and `/queue` are absent from the slash menu.
   - Verify `/steer` is present but greyed-out on idle, with the tooltip.
6. **Session reset:**
   - Set a goal + queue 2 prompts. Click "New chat" — confirm chip and pill clear.
   - Resume an old session — confirm pill stays empty (we don't persist active-goal across sessions in v1; see [Open questions](#open-questions)).

### Manual: pre-v0.13 host

1. Connect to a remote running Hermes v0.11.x or v0.12.x.
2. Slash menu should show `/steer` only (no `/goal`, no `/queue`).
3. With idle session, hover `/steer` — verify greyed + tooltip.
4. Manually type `/goal foo` and send — Hermes returns its own "unknown command" reply; Scarf does not crash, the goal pill does not appear (because `recordActiveGoal` is gated on the slash dispatch being routed via the `case "goal":` branch, and that branch fires unconditionally — but the chip is only rendered when `activeGoal != nil` AND we sent the slash, so the user sees an inconsistent local pill until the agent's "unknown command" response).
   - **Inconsistency caveat:** the optimistic write means a typed-out `/goal` against a pre-v0.13 host paints the pill briefly. Acceptable: pre-v0.13 users have to type the command literally (no menu surface), so this is power-user territory. Document in release notes.

### Visual

- Goal chip should be `info`-tinted and visually distinct from accent (project) and warning (queue).
- Pill text truncates to ~33 chars + ellipsis for long goals; full text in tooltip.
- Three-chip overflow at narrow window widths: SessionInfoBar already wraps via the `HStack(spacing: 16)` parent — the pills should naturally elide. If they don't, we constrain `lineLimit(1)` per chip (already the pattern for project name).

## Open questions

These need coordinator resolution before implementation closes.

1. **Goal persistence across session restarts.** Hermes v0.13's "Persistent Goals" implies the active goal survives restarts on the server side. Does Hermes expose:
   - (a) a session-startup ACP notification with the current goal, or
   - (b) a sidecar JSON file (e.g. `~/.hermes/sessions/session_<id>.json` with a `goal: ...` field), or
   - (c) a `/goal --status` command that returns the current goal?

   The release notes mention "Preserve pending update prompts across restarts" and "Preserve thread routing from cached live session sources" — neither of those is the persistent-goal channel.

   **Recommendation:** ship v2.8 with optimistic-only state (no read-back). Open a follow-up to read goal state from whichever channel Hermes exposes once the v0.13 server is dogfooded. Mark the chip as "user-set this session" in the tooltip until then. This means resuming an old session won't paint the goal pill even if the agent still has the goal — the chip will appear the next time the user runs `/goal`. This is the safest v2.8 behaviour and aligns with the "minimal-surface, maximal-ship" approach for the v2.8 catch-up release.

2. **`/queue --clear` syntax.** Does Hermes accept `/queue --clear` (or `/queue clear`) to drain the server-side queue? If not, the "Clear all" button in the popover can only clear the local mirror — which means a queued prompt would still run server-side after the user thought they'd cancelled it.

   **Recommendation:** if the syntax is unsupported, **remove the "Clear all" button from v2.8** and document the limitation in the popover header. Don't ship a button that lies about what it does.

3. **Auto-resume after gateway restart — ACP signal.** The release notes say "Auto-resume interrupted sessions after gateway restart" but it's unclear whether that signal:
   - lands as a Scarf-visible ACP event (so we can show an "Auto-resumed" toast),
   - or is purely server-side (Hermes resumes the session transparently and Scarf sees nothing different).

   **Recommendation:** defer the "Auto-resumed from checkpoint" indicator to v2.8.1. Add a `// TODO(WS-2 followup)` comment in the ACP event-loop hooks pointing at this question. Ship v2.8 without the indicator. If user-visible auto-resume is in fact happening silently, the lack of UI is a no-op (correct behaviour by accident); if it's announced via an event, we surface it in the next point release.

4. **Optimistic-vs-authoritative goal state.** If the user types `/goal foo` then immediately disconnects before Hermes acks, our optimistic chip will say `foo` while the server has nothing. Reconciliation isn't implemented in v1.

   **Recommendation:** accept the trade-off. Reconciling would require Open Question #1's resolution (a way to read server-side goal state), so it's blocked on the same answer.

5. **`/queue` argument shape.** Release notes call it "queue a prompt" — but is the syntax `/queue <text>` (verbatim text becomes the queued prompt) or does it accept named priorities / IDs? If the latter, our optimistic-mirror logic over-simplifies.

   **Recommendation:** assume verbatim. Verify against `hermes acp` in dogfooding before merging.

6. **Active goal injection into the system prompt.** If Hermes injects the active goal into every turn's system prompt (likely — that's how a "locked" goal would survive across turns server-side), Scarf doesn't need to re-send it on resume. If Hermes uses some other mechanism (e.g. a sidecar tool), that's also Hermes' problem. **No Scarf-side action needed regardless.**

7. **`/goal` non-interruptive on the wire — does Hermes actually accept it during an active turn?** `/steer` is documented as non-interruptive; `/goal` is documented as "lock onto a target." The server may treat `/goal` as a prompt that DOES need a turn to take effect. If so, our `nonInterruptiveCommands` classification for `/goal` is wrong — it should flip "Agent working…" like a regular prompt.

   **Recommendation:** verify against the v0.13 ACP adapter behaviour on a real host. If `/goal` is in fact interruptive, drop it from `nonInterruptiveCommands` and treat it as a normal prompt that just happens to also mutate `activeGoal`. The pill behaviour is unchanged either way.

## Out of scope (deferred)

- iOS surface for goal pill + queue chip — WS-9.
- Persistent-goal cross-session memory (paint the pill from server state on session resume) — blocked on Open Question #1, deferred to v2.8.1.
- "Auto-resumed from checkpoint" indicator — blocked on Open Question #3, deferred to v2.8.1.
- "Resumed from checkpoint" sessions-list badge — same as above.
- A dedicated Goals feature surface (sidebar entry showing all locked goals across sessions) — out of scope; the chip is enough for v2.8.
- Per-queued-prompt deletion in the popover — Hermes has no remove-by-id verb.
- Goal mutation via UI affordance other than the slash command (e.g. a "Set goal…" toolbar button) — defer to v2.8.1; the slash menu is the canonical entry.
- Goal text Markdown rendering in the pill — pill is a one-line plain-text chip.
- Telemetry: ScarfMon counters for `/goal` / `/queue` invocations — nice-to-have, ship without.

## Estimate

**Medium.** ~5 files changed (3 in ScarfCore, 3 Mac chat views — one new), 2 new model files, ~12 new tests. The capability-flag plumbing is non-trivial because `RichChatViewModel.capabilitiesGate` needs a clean injection seam without forcing the whole VM to re-render on every refresh. Two days of focused work end-to-end including manual verification on both a v0.13 and a v0.12 host. The biggest uncertainty is server-side `/goal` and `/queue` behaviour, captured in Open Questions 1, 2, and 7 — coordinator should answer these before the implementation PR opens.
