---
title: Data-Model
type: note
permalink: scarf-wiki/data-model
created: 2026-05-29
updated: 2026-05-29
---

# Data Model

Plain Codable structs under [`scarf/Packages/ScarfCore/Sources/ScarfCore/Models/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models). These are the in-memory representation of Hermes state — sessions, messages, config, cron jobs, MCP servers, project dashboards. None of them own I/O; services read from `~/.hermes/` (via [transport](Transport-Layer)) and decode into these types.

In v2.5 every model moved out of the Mac target into the shared [ScarfCore](ScarfCore-Package) SwiftPM package, so iOS reuses them byte-for-byte. The path references below all point at the package locations.

## Sessions and messages

| Type | Conformances | Notable fields | Notes |
|---|---|---|---|
| `HermesSession` | `Identifiable, Sendable` | `id, source, userId, model, title, parentSessionId, startedAt, endedAt, endReason, messageCount, toolCallCount, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens, estimatedCostUSD, actualCostUSD, costStatus, billingProvider, apiCallCount` _(v0.11+)_ | `isSubagent` = `parentSessionId != nil`; `displayCostUSD` prefers `actualCostUSD`; `sourceIcon` calls `KnownPlatforms.icon(for:source)`. `apiCallCount` (v0.11+) counts per-turn API round-trips, distinct from `toolCallCount`. |
| `HermesMessage` | `Identifiable, Sendable` | `id, sessionId, role, content, toolCallId, timestamp, tokenCount, finishReason, toolCalls, toolName, reasoning, reasoningContent` _(v0.11+)_ | `isUser/isAssistant/isToolResult` helpers; `hasReasoning` for v0.7+ reasoning support. `preferredReasoning` returns `reasoningContent` when both columns are populated (v0.11 path) and falls back to legacy `reasoning`. |
| `HermesToolCall` (nested in `HermesMessage`) | custom Codable | `callId, functionName, arguments` | `toolKind` categorizes to `.read/.edit/.execute/.fetch/.browser/.other`; `argumentsSummary` extracts command/path/query/url or truncates to 120 chars. |

## Server context and paths

| Type | Purpose |
|---|---|
| [`ServerContext`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ServerContext.swift) | The unifying handle. Holds `id, displayName, kind` (`.local` or `.ssh(SSHConfig)`); exposes `paths`, `makeTransport()`, and high-level helpers (`readText`, `writeText`, `runHermes`, `openInLocalEditor`). The `local` static is the well-known UUID `00000000-0000-0000-0000-000000000001`. |
| `SSHConfig` (nested) | `host, user?, port?, identityFile?, remoteHome?, hermesBinaryHint?` |
| `UserHomeCache` (nested) | Process-wide cache of remote `$HOME` per `ServerID`; probed once via `ssh host echo $HOME`, memoized. |
| [`HermesPathSet`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesPathSet.swift) | All `~/.hermes/*` paths as nonisolated computed properties. Parameterized by `home` and `isRemote`. Includes `hermesBinaryCandidates` (`~/.local/bin/hermes`, `/opt/homebrew/bin/hermes`, `/usr/local/bin/hermes`, `~/.hermes/bin/hermes`) and a `binaryHint` override for remote. |

See [Hermes Paths](Hermes-Paths) for the full path table.

## Config

[`HermesConfig`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConfig.swift) parses `config.yaml` into a typed tree. About 100+ properties grouped into nested setting structs:

- `display`, `terminal`, `browser`, `voice`, `auxiliary`, `security`, `humanDelay`, `compression`, `checkpoints`, `logging`, `delegation`
- Per-platform: `discord, telegram, slack, matrix, mattermost, whatsapp, homeAssistant`
- Top-level scalars: `model, provider, maxTurns, personality, terminalBackend, memoryEnabled, …`

`HermesConfig.empty` provides safe defaults for empty/missing files.

## Cron, MCP, plugins

| Type | Purpose |
|---|---|
| [`HermesCronJob`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesCronJob.swift) | Job definition with `schedule, prompt, skills?, model?, enabled, state, deliver, nextRunAt?, lastRunAt?, lastError?, preRunScript?, deliveryFailures?, timeoutType?, timeoutSeconds?, silent?`. Nested `CronSchedule` and `CronJobsFile` container. |
| [`HermesMCPServer`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesMCPServer.swift) | MCP server config: `name, transport (.stdio/.http), command?, args, url?, auth?, env, headers, timeouts, enabled, toolsInclude/Exclude, resourcesEnabled, promptsEnabled, hasOAuthToken`. |
| [`MCPServerPreset`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/MCPServerPreset.swift) | Curated presets gallery (Filesystem, GitHub, Postgres, Slack, Linear, Sentry, Puppeteer, Memory, Fetch). |
| `HermesTool`, `HermesToolset`, `KnownPlatforms` | Tool/toolset definitions and a switch for platform icons (cli, telegram, discord, slack, whatsapp, signal, email, homeassistant, webhook, matrix, feishu, mattermost, imessage). |
| `HermesSkill`, `HermesSkillCategory` | Installed skills with `id, name, category, path, files, requiredConfig`, plus v0.11 frontmatter fields `allowedTools?`, `relatedSkills?`, `dependencies?` (parsed from SKILL.md YAML by `SkillsScanner`). Old skills without these fields stay nil and the chip rows hide themselves in the UI. |

## Project dashboards

The dashboard schema lives in [`ProjectDashboard.swift`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDashboard.swift):

- `ProjectRegistry` → `ProjectEntry` (name, path)
- `ProjectDashboard` → `DashboardSection` → `DashboardWidget` (`.stat / .progress / .text / .table / .chart / .list / .webview`)
- `WidgetValue` enum with `.string` or `.number` for stat boxes; custom Codable.
- `ChartSeries`, `ChartDataPoint`, `ListItem` for non-scalar widgets.

The full schema is also documented in `scarf/docs/DASHBOARD_SCHEMA.md` in the main repo.

## ACP messages

[`ACPMessages.swift`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ACPMessages.swift) defines the JSON-RPC envelopes (`ACPRequest`, `ACPRawMessage`, `ACPError`) and the typed events (`ACPEvent.messageChunk / thoughtChunk / toolCallStart / toolCallUpdate / permissionRequest / promptComplete / availableCommands / connectionLost / unknown`). See [ACP Subprocess](ACP-Subprocess) for the protocol details.

## Constants

[`HermesConstants.swift`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConstants.swift) holds query defaults — `sessionLimit = 100`, `messageSearchLimit = 50`, `toolCallLimit = 50`, `previewContentLength = 100`, `logLineLimit = 200` — plus SQLite C macro replacements and file-size unit constants for display formatting.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (ScarfCore extraction + v0.11 fields + SKILL.md frontmatter)_