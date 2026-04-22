# Example Templates

This directory holds reference `.scarftemplate` bundles shipped in the Scarf repo. Each subdirectory is one template, laid out as:

```
<template-name>/
├── staging/                          Source tree — the exact layout of the bundle
│   ├── template.json
│   ├── README.md
│   ├── AGENTS.md
│   ├── dashboard.json
│   ├── cron/jobs.json                (optional)
│   ├── skills/<name>/…               (optional)
│   ├── instructions/…                (optional)
│   └── memory/append.md              (optional)
└── <template-name>.scarftemplate     Built bundle (zipped staging dir)
```

## Available templates

- **[site-status-checker](site-status-checker/)** — daily HTTP uptime check for a user-editable list of URLs. Dashboard + cron + AGENTS.md. The simplest example that exercises the full format.

## Rebuilding a bundle after editing

```bash
cd <template-name>/staging
zip -qq -r ../<template-name>.scarftemplate .
```

The Scarf test suite (`ProjectTemplateExampleTemplateTests`) validates each shipped `.scarftemplate` on every build, so a bundle that fails to round-trip through `inspect → buildPlan` will fail CI.

## Authoring conventions

- **Always ship `AGENTS.md`.** It's the Linux Foundation cross-agent standard ([agents.md](https://agents.md/)) and every supported agent reads it. Agent-specific shims (`CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.github/copilot-instructions.md`) go under `instructions/` and only when there's a real per-agent behavior the author needs.
- **Cron jobs ship paused.** Don't assume the user wants your job running on install. Write the prompt so running it manually from chat (`"run the X job"`) also works — the cron is just a schedule wrapper.
- **Dashboard values that change at runtime should be placeholders.** The agent (not the installer) keeps them fresh. Start with sensible zeros / "never" / "unknown" so an uninstalled, inactive project still renders cleanly.
- **Don't claim in the manifest what you don't ship.** The `contents` block is cross-checked against the unpacked files — a mismatch makes the installer refuse the bundle.
