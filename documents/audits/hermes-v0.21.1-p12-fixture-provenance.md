# P12 fixture provenance — Hermes v2026.9.7 emitter reproductions

How the verbatim fixtures in the P12 tests were produced, so the next cycle
can regenerate them rather than re-guess them.

## Rule

A Rich-table fixture is NOT hand-drawn. It is rendered by the tag's OWN
column specifications through the SAME Rich the agent ships. Hermes's
module-level `_console` is a bare `Console()`; when Scarf pipes it that is a
non-tty console whose width falls back to **80**, and Rich strips its own
markup and colour. `Console(file=..., width=80, force_terminal=False,
no_color=True)` reproduces it exactly.

Rich lives in the user's Hermes venv, not the system python — resolve it as
`$(dirname $(realpath ~/.local/bin/hermes))/python3`. The Hermes CHECKOUT is
never modified: the helper functions below are copied out of
`git show v2026.9.7:<path>` into a scratch script.

## What 80 columns proves that 100 does not

At width 80 the browse table's Identifier column FOLDS (`_ident_col`'s
`overflow="fold"`, `hermes_cli/skills_hub.py:64-69`): `pdf-tools-a1b2c3`
arrives as `pdf-tools-a1b` + `2c3` on two lines. That is a HARD character
wrap, unlike the Description column's word wrap — so the two columns'
continuation cells must be merged by different rules (concatenate vs.
space-join). A fixture rendered wide enough not to fold would have hidden
half the bug.

## Generator 1 — `skills browse` and `skills check`

Helpers copied verbatim from `hermes_cli/skills_hub.py` at `v2026.9.7`:
`_ident_col` (:64-69), `_table` (:71-78), `_truncate` (:60-62),
`_trust_cell` (:49-53); table specs from `_render_browse_page` (:393-399)
and `do_check` (:806-808).

```python
import io
from rich.console import Console
from rich.table import Table

# skills_hub.py:64-69
def _ident_col(style):
    return "Identifier", {"style": style, "overflow": "fold", "no_wrap": False}

# skills_hub.py:71-78
def _table(*columns, **table_kw):
    table = Table(**table_kw)
    for col in columns:
        header, kw = col if isinstance(col, tuple) else (col, {"style": "dim"})
        table.add_column(header, **kw)
    return table

# skills_hub.py:60-62
def _truncate(text, width):
    return text[:width] + ("..." if len(text) > width else "")

_TRUST_STYLE = {"trusted": "green", "community": "yellow", "unknown": "dim"}

# skills_hub.py:49-53
def _trust_cell(trust_level, source, official_label="official"):
    label = official_label if source == "official" else trust_level
    return f"[{_TRUST_STYLE.get(trust_level, 'dim')}]{label}[/]"

# 80 is the width a bare Console() falls back to when it cannot size a
# terminal, which is what Hermes has when Scarf pipes it.
def render(build, width=80):
    buf = io.StringIO()
    c = Console(file=buf, width=width, force_terminal=False, no_color=True,
                legacy_windows=False)
    build(c)
    return buf.getvalue()

# --- browse page (skills_hub.py:393-399) ---
def browse(c):
    table = _table(("#", {"style": "dim", "width": 4, "justify": "right"}),
                   ("Name", {"style": "bold cyan", "max_width": 22}),
                   ("Description", {"max_width": 44}),
                   ("Source", {"style": "dim", "width": 12}),
                   ("Trust", {"width": 10}),
                   _ident_col("dim"), show_header=True, header_style="bold")
    rows = [
        ("1password", "Set up and use the 1Password CLI to read secrets.",
         "official", "trusted", "1password"),
        ("pdf-tools", "Split, merge and OCR PDF documents from the shell with a very long description that wraps.",
         "skills-sh", "community", "pdf-tools-a1b2c3"),
        ("nv-rag", "NVIDIA retrieval augmented generation helper",
         "github", "unknown", "nvidia/skills/nv-rag"),
    ]
    for i, (name, desc, source, trust, ident) in enumerate(rows, start=1):
        table.add_row(str(i), name, _truncate(desc, 44), source,
                      _trust_cell(trust, source, official_label="★ official"),
                      ident)
    c.print(table)

# --- skills check (skills_hub.py:806-808) ---
def check(c):
    table = _table(("Name", {"style": "bold cyan"}), "Source", "Status",
                   title="Skill Updates")
    for row in [("1password", "official", "update_available"),
                ("pdf-tools", "skills-sh", "up_to_date"),
                ("gone-skill", "github", "orphaned"),
                ("dead-registry", "clawhub", "unavailable"),
                ("bad-path", "official", "invalid_install")]:
        table.add_row(*row)
    c.print(table)

print("=== BROWSE ===")
print(render(browse))
print("=== CHECK ===")
print(render(check))
```

## Generator 2 — `mcp test`

`hermes_cli/mcp_config.py` at `v2026.9.7` is not Rich — it is plain `print`
plus `color()`, and `hermes_cli/colors.py::should_use_color()` is
`sys.stdout.isatty()`, so for a piped Scarf run `color()` is the IDENTITY
function and there is no ANSI at all. (Scarf still strips ANSI defensively;
note that when colour IS on, `f"{color(name):{width}s}"` pads the ESCAPED
string, so column alignment cannot be relied on — split on whitespace.)

Reproduced from `cmd_mcp_test` (:583-620) and `_print_tools` (:49-52), called
with width 36 and desc_max 55 (:619). Note the four-space-indented masked
header line ABOVE the count — the reason the parser anchors on
`Tools discovered: N` rather than on indentation alone.

```python
def color(t, *c): return t
def _info(t): print(color(f"  {t}"))
def _success(t): print(color(f"  ✓ {t}"))
def _print_tools(tools, width, desc_max):
    for tool_name, desc in tools:
        short = desc[:desc_max] + "..." if len(desc) > desc_max else desc
        print(f"    {color(tool_name):{width}s} {short}")

name = "files"
tools = [("read_file", "Read a file from disk; returns Error: ENOENT when the path is missing"),
         ("write_text_file", "Write UTF-8 text to a path"),
         ("list_dir", "List a directory")]
print()
print(color(f"  Testing '{name}'..."))
_info("Transport: stdio → npx")
print(f"    X-Api-Key: abcd***wxyz")
_success("Connected (412ms)")
_success(f"Tools discovered: {len(tools)}")
if tools:
    print()
    _print_tools(tools, 36, 55)
print()
```

## Where the outputs landed

* browse + check → `scarf/Packages/ScarfCore/Tests/ScarfCoreTests/SkillsHubParserTests.swift`
  (`browseFixture`, `checkFixture`)
* mcp test → `scarf/scarfTests/SectionAuditF5ManageAppTests.swift`
  (`mcpTestSuccessFixture`)
