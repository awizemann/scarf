# Hermes Agent — Discovery Notes

## Installation

- Binary: `~/.local/bin/hermes` (symlink to venv wrapper)
- Codebase: `~/.hermes/hermes-agent/` (Python 3.11 venv)
- Version: v0.6.0 (March 30, 2026)
- Runs as daemon process

## What Hermes Does

A self-improving AI agent with tool-calling capabilities:
- Interactive terminal chat with syntax highlighting
- 40+ tools (terminal, file, browser, web, code execution, vision, etc.)
- Autonomous skill creation from complex tasks
- Persistent memory (MEMORY.md + USER.md) with periodic nudges
- Multi-platform messaging gateway (Telegram, Discord, Slack, WhatsApp, Signal, Email)
- Cron scheduler for recurring tasks
- Session persistence in SQLite with FTS5 search
- Subagent delegation for parallel workstreams
- MCP (Model Context Protocol) integration
- ACP (Agent Client Protocol) for IDE integration

## File System Layout

```
~/.hermes/
  hermes-agent/           Python codebase (70 directories)
    run_agent.py          Core agent loop
    cli.py                Terminal UI
    model_tools.py        Tool dispatcher
    toolsets.py            Tool definitions
    agent/                Agent internals
    tools/                40+ tool implementations
    gateway/              Multi-platform messaging
    cron/                 Scheduler implementation
    hermes_cli/           CLI command handlers
    acp_adapter/          Agent Client Protocol server
    venv/                 Python environment
  config.yaml             User configuration (8.8 KB)
  .env                    API keys (encrypted)
  auth.json               OAuth tokens
  state.db                SQLite session database (WAL mode)
  sessions/               JSON conversation snapshots
  memories/               MEMORY.md, USER.md
  skills/                 29 installed skills across 15+ categories
  cron/
    jobs.json             Scheduled job definitions
    output/               Job execution output
  logs/
    errors.log            Application errors
    gateway.log           Gateway platform logs
  gateway_state.json      Gateway process lifecycle
```

## SQLite Schema (state.db, version 6)

### sessions table
```sql
id TEXT PRIMARY KEY,
source TEXT,              -- 'cli', 'telegram', 'discord', etc.
user_id TEXT,
model TEXT,
model_config TEXT,        -- JSON
system_prompt TEXT,
parent_session_id TEXT,   -- Session splitting on compression
started_at REAL,
ended_at REAL,
end_reason TEXT,
message_count INTEGER,
tool_call_count INTEGER,
input_tokens INTEGER,
output_tokens INTEGER,
cache_read_tokens INTEGER,
cache_write_tokens INTEGER,
reasoning_tokens INTEGER,
billing_provider TEXT,
billing_base_url TEXT,
billing_mode TEXT,
estimated_cost_usd REAL,
actual_cost_usd REAL,
cost_status TEXT,
cost_source TEXT,
pricing_version TEXT,
title TEXT UNIQUE
```

### messages table
```sql
id INTEGER PRIMARY KEY,
session_id TEXT,
role TEXT,                 -- 'user' or 'assistant'
content TEXT,
tool_call_id TEXT,
tool_calls TEXT,          -- JSON array of tool invocations
tool_name TEXT,
timestamp REAL,
token_count INTEGER,
finish_reason TEXT,
reasoning TEXT,
reasoning_details TEXT,
codex_reasoning_items TEXT
```

### messages_fts (FTS5 virtual table)
Full-text search on message content.

## Session JSON Format

```json
{
  "session_id": "YYYYmmdd_HHMMSS_6hexchars",
  "model": "claude-haiku-4-5-20251001",
  "platform": "cli",
  "session_start": "ISO8601",
  "last_updated": "ISO8601",
  "system_prompt": "...",
  "tools": [{"type": "function", "function": {"name": "...", "description": "...", "parameters": {...}}}],
  "messages": [
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "...", "tool_calls": [
      {"id": "call_...", "type": "function", "function": {"name": "terminal", "arguments": "{\"command\": \"...\"}"}}
    ]}
  ]
}
```

## Cron Jobs Format

```json
{
  "jobs": [{
    "id": "12hexchars",
    "name": "Job Name",
    "prompt": "What to do",
    "skills": ["skill-name"],
    "schedule": {"kind": "once|cron", "run_at": "ISO8601", "display": "human readable"},
    "repeat": {"times": 1, "completed": 0},
    "enabled": true,
    "state": "scheduled|running|completed",
    "deliver": "origin|telegram|discord",
    "next_run_at": "ISO8601",
    "last_run_at": "ISO8601|null",
    "last_error": "string|null"
  }]
}
```

## Config Structure (config.yaml)

Key sections: model (default, provider), agent (max_turns, tool_use_enforcement, personalities), terminal (backend, cwd, timeout), memory (enabled, char limits, nudge interval), display (personality, streaming, show_reasoning), platform_toolsets (tools per platform).

## ACP (Agent Client Protocol)

- Entry: `hermes acp` or `python -m acp_adapter.entry`
- Transport: stdio JSON-RPC (not HTTP)
- Lifecycle: initialize() -> new_session()/load_session() -> send messages
- Events emitted: ToolCallStart, ToolCallProgress, AgentMessage, AgentThought, SessionUpdate
- Tool kinds: read, edit, execute, fetch, search, think, other
- Tool call IDs: `tc-{uuid.hex[:12]}`

## Log Format

```
YYYY-MM-DD HH:MM:SS,MMM LEVEL logger_name: message
```

## Gateway State

```json
{
  "pid": 12345,
  "kind": "hermes-gateway",
  "gateway_state": "running|startup_failed",
  "exit_reason": "string|null",
  "platforms": {},
  "updated_at": "ISO8601"
}
```

## SQLite Contention Notes

Hermes uses WAL mode with aggressive retry (15 retries, 20-150ms jitter). Scarf must only open state.db in read-only mode to avoid write contention. Checkpoint every 50 writes. WAL file modification is a good signal for refresh.
