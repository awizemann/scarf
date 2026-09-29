# DRAFT — NousResearch/hermes-agent issue (not posted; needs Alan's approval)

**Title:** ACP: expose /retry, /undo and /title to ACP clients

**Body:**

ACP clients (Scarf, editors using the ACP adapter) can't offer `/retry`, `/undo` or `/title`. They exist for the CLI and gateway (`hermes_cli/commands.py:66`, `:69`, `:71`) but aren't in the ACP adapter's command table (`acp_adapter/commands.py:44`, `_COMMANDS`), so they aren't advertised in `available_commands_update`. When a user types one anyway, `_handle_slash_command` (`acp_adapter/commands.py:88-95`) doesn't recognise it and the text goes to the model as a normal message (`:119`), which costs a turn and does nothing useful.

A client can't do these safely on its own side:
- **retry / undo** need Hermes to drop the last exchange(s) from the session history before re-prompting. A client that simply resends the message leaves the original turn in the history, so the model sees the question twice.
- **title** a client can do through `hermes sessions rename`, but having it in ACP keeps it consistent across frontends.

Request: add `retry`, `undo` (with the optional N) and `title` to the ACP command table, implemented against the ACP session's history the same way the CLI does, and advertise them in `available_commands_update`.

Context: reported by a Scarf user in awizemann/scarf#147. Checked against v2026.9.14 (0.21.x).
