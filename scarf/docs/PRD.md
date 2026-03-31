# Scarf — Product Requirements Document

## Overview

Scarf is a native macOS application that provides a graphical interface for the Hermes AI agent. Hermes is a CLI-based AI agent with 40+ tools, multi-platform messaging, autonomous skill creation, persistent memory, and scheduled automation. Scarf gives users visibility into what Hermes is doing, when, and what it creates.

## Problem

Hermes operates entirely through CLI with no visual dashboard. Users cannot easily:
- See what the agent is currently doing or has done
- Browse conversation history across sessions
- Monitor tool executions in real-time
- Manage memory, skills, or cron jobs visually
- Chat with the agent through a native interface

## Target User

Developer running Hermes locally on macOS who wants transparency and control over agent activity.

## Core Features

### 1. Dashboard
- System health overview (model, provider, connection status)
- Active session indicator
- Token usage and cost summary (aggregated from session data)
- Gateway platform connection status
- Recent activity feed

### 2. Sessions Browser
- List all conversation sessions with metadata (source, message count, tool calls, cost, duration)
- Full conversation detail view with message rendering
- Full-text search across all sessions (via SQLite FTS5)
- Session lineage tracking (parent_session_id chains)

### 3. Activity Feed
- Real-time tool execution monitoring (the core transparency feature)
- Each entry: tool name, kind, arguments, result preview, timestamp
- Filterable by tool type, session, time range
- Color-coded by tool kind (read/edit/execute/fetch)

### 4. Live Chat
- Send messages to Hermes via ACP (Agent Client Protocol)
- Stream responses with tool calls shown inline
- Session management (new, load, resume)

### 5. Memory Viewer/Editor
- Display MEMORY.md and USER.md with markdown rendering
- Edit and save changes
- Character count vs configured limits

### 6. Skills Browser
- Tree view by category
- Skill metadata display
- Search and filter

### 7. Cron Manager
- View scheduled jobs with status, next/last run times
- View job output
- Enable/disable jobs

### 8. Log Viewer
- Real-time log tailing (errors.log, gateway.log)
- Level-based filtering and text search

### 9. Menu Bar Presence
- Status icon showing Hermes state (running/idle/error)
- Quick access to recent session, new chat

## Technical Constraints

- macOS 26.2+ (SwiftUI, Swift 6 concurrency)
- No external SPM dependencies — uses system SQLite3 C API, Foundation JSON
- Reads Hermes data from `~/.hermes/` (requires sandbox disabled)
- ACP communication via subprocess stdio JSON-RPC
- App sandbox disabled (developer tool needing filesystem access)

## Data Sources

| Source | Path | Format | Access |
|--------|------|--------|--------|
| Sessions DB | `~/.hermes/state.db` | SQLite (WAL) | Read-only |
| Session files | `~/.hermes/sessions/*.json` | JSON | Read-only |
| Config | `~/.hermes/config.yaml` | YAML | Read/Write |
| Memory | `~/.hermes/memories/*.md` | Markdown | Read/Write |
| Cron jobs | `~/.hermes/cron/jobs.json` | JSON | Read/Write |
| Cron output | `~/.hermes/cron/output/` | Text | Read-only |
| Logs | `~/.hermes/logs/*.log` | Text | Read-only |
| Gateway state | `~/.hermes/gateway_state.json` | JSON | Read-only |
| Skills | `~/.hermes/skills/` | Directory tree | Read-only |
| ACP | `hermes acp` subprocess | JSON-RPC stdio | Bidirectional |

## Non-Goals (v1)

- Config editing UI (read-only display for v1, except memory)
- Skill creation or management
- Gateway platform management
- Multi-user support
