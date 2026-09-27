# Upstream note for Hermes: the ACP adapter ignores `display.personality` (and `agent.system_prompt`)

Source: Scarf audit finding S03-F2 (Hermes v0.21.5 full-app audit), verified at tag **v2026.9.24** (0.21.5).
Status: draft for Alan — not filed.

## What happens

`hermes config set display.personality <name>` changes the agent's voice in the CLI, the TUI and the
messaging gateway, but not in any ACP client (Scarf, Zed, other editors). The overlay has one resolver and
three callers, none of them in `acp_adapter/`:

- Resolver: `hermes_cli/personality.py:118-124` — `resolve_ephemeral_system_prompt(cfg)` returns the named
  personality's prompt when `display.personality` names a known one, otherwise the user-owned
  `agent.system_prompt`.
- CLI: `hermes_cli/cli_init_mixin.py:249` (`HERMES_EPHEMERAL_SYSTEM_PROMPT` env, else the resolver).
- Gateway: `gateway/run_config_loaders.py:99`.
- TUI gateway: `tui_gateway/server.py:2384-2385`.
- ACP: `acp_adapter/session.py:487-530` builds `AIAgent(**kwargs)` with no `ephemeral_system_prompt`; no
  module under `acp_adapter/`, `run_agent.py` or `agent/` reads `display.personality`.

So an ACP session also ignores `agent.system_prompt`, the resolver's fallback. SOUL.md is unaffected: it is
part of the base system prompt (`agent/prompt_builder.py`) on every surface.

## Suggested change

In `SessionManager._make_agent` (`acp_adapter/session.py`), resolve the overlay the same way the other
surfaces do and pass it through:

```python
from hermes_cli.personality import resolve_ephemeral_system_prompt
kwargs["ephemeral_system_prompt"] = (
    os.getenv("HERMES_EPHEMERAL_SYSTEM_PROMPT", "") or resolve_ephemeral_system_prompt(config)
)
```

Open questions for the maintainers:

- Whether the overlay should be read once per agent build (as the CLI does) or per session, and how it
  interacts with the stored system prompt a resumed session reuses (`agent/conversation_loop.py:681-730`
  reuses the stored prompt unless model/provider/cwd changed — an ephemeral prompt is sent separately, so
  it would apply to resumed sessions too, which is probably the desired behaviour).
- Whether ACP should expose a personality surface of its own (a session config option), so an editor can
  switch it per session the way the TUI's `/personality` does.

## What Scarf does meanwhile

Scarf 3.x labels the setting honestly: the Personalities screen and Settings → General say the active
personality applies to Hermes CLI, TUI and messaging-gateway sessions and that Scarf chats don't use it,
and point at SOUL.md for shaping Scarf chats. If Hermes adopts the change above, Scarf should gate the
label on a capability flag at the release that ships it (charter C1) and drop the caveat on newer hosts.
