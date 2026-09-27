# Adversarial verifier brief

A section auditor reported the finding(s) named in your prompt. Your job is to try to DISPROVE each one.
You are fresh eyes: do not trust the auditor's citations — re-read the code on both sides yourself.

Ground truth: Hermes source at `~/.hermes/hermes-agent-v0215` (detached at tag v2026.9.24, semver 0.21.5).
Never use `~/.hermes/hermes-agent` (it is ahead of the tag). Scarf repo: `/Users/awizemann/Developer/Scarf`.
Safe live probes allowed: `hermes --version`, `hermes --help`, `hermes <verb> [<sub>] --help`, and read-only
listing of `~/.hermes` directories (names only — never print .env/auth.json/credential contents).
READ-ONLY: no repo edits, no builds, no mutating commands, no Memophant writes.

For each finding, look for: a guard elsewhere in Scarf that prevents the scenario; Hermes normalizing or
tolerating the value; the code path being unreachable in practice; the claim relying on a misread of either
side; the issue already tracked (grep TASKS.md, tasks/, documents/reports/, .memory/decisions/) or already
fixed on main (check `git log` for recent commits touching the file).

Severity rubric: P0 = primary feature broken / silent false success / data loss in a common setup.
P1 = primary feature broken in a common-but-non-default setup (remote host, named profile, other provider)
or a destructive/side-effecting action mis-reported. P2 = secondary feature wrong or misleading UI.
P3 = cosmetic with a real user-visible effect.

Return, per finding (no file writes needed):
`<id> · CONFIRMED | DOWNGRADED(to P?) | REFUTED | ALREADY-TRACKED(ref) · final severity · 2–4 lines of
evidence with file:line on both sides`. Keep the whole reply under 30 lines.
