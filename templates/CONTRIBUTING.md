# Contributing a template to Scarf

Thanks for packaging something up for other Scarf users. This guide walks you through the full submission flow end-to-end.

## Before you start

- You need Scarf 2.2 or later installed to build + test your template.
- Your template must ship a cross-agent **`AGENTS.md`** — that's the Linux Foundation open standard ([agents.md](https://agents.md/)) every major coding agent reads. Templates without one are rejected; Scarf specifically supports agent-portable projects.
- Templates are free and MIT-licensed implicitly by submission. Don't submit anything you don't have rights to.

## What makes a good template

- **Scoped.** One purpose per template. A "does-everything" template is harder to maintain than three focused ones.
- **Agent-first.** The `AGENTS.md` tells any agent how to interact with your project. Spell out the project layout, what each file is for, and what the agent should do when the user asks common questions ("run the X job", "add a Y").
- **Self-contained prompts.** Cron jobs + skills should not assume state the template doesn't ship. If you need a `sites.txt`, have `AGENTS.md` tell the agent to bootstrap it on first run (see `awizemann/site-status-checker` for the pattern).
- **Paused by default.** Every cron job ships disabled — Scarf pauses new jobs on install. Write prompts that work whether fired by cron or invoked directly in chat.
- **No secrets.** No API keys, no hostnames, no paths specific to your machine. The catalog's CI secret-scan will block obvious cases but this is on you.
- **No config writes.** Templates must not modify `~/.hermes/config.yaml`, `auth.json`, or any credential path. The installer refuses v1 bundles that claim to. If you need integration with, say, a specific MCP server, document the prerequisite in your README instead of trying to install it.

## Step-by-step submission

### 1. Fork + clone

```bash
gh repo fork awizemann/scarf --clone && cd scarf
```

### 2. Create your template directory

```bash
mkdir -p templates/<your-github-handle>/<your-template-name>/staging
cd templates/<your-github-handle>/<your-template-name>/staging
```

Directory names are lowercase, hyphenated, stable: people will type them.

### 3. Author the bundle

Minimum required files under `staging/`:

- **`template.json`** — manifest. Schema:
  ```json
  {
    "schemaVersion": 1,
    "id": "<your-handle>/<your-template-name>",
    "name": "Your Template Name",
    "version": "1.0.0",
    "minScarfVersion": "2.2.0",
    "minHermesVersion": "0.9.0",
    "author": { "name": "Your Name", "url": "https://…" },
    "description": "One-line pitch shown in the catalog.",
    "category": "monitoring",
    "tags": ["short", "list"],
    "contents": {
      "dashboard": true,
      "agentsMd": true,
      "cron": 0,
      "instructions": null,
      "skills": null,
      "memory": null
    }
  }
  ```
  The `contents` claim must exactly match what's in `staging/` — the validator cross-checks and rejects mismatches.

- **`README.md`** — shown on the catalog detail page. Include: what the project does, what the user has to do after install, how to customize, how to uninstall.

- **`AGENTS.md`** — the cross-agent spec. Include: project layout, first-run bootstrap (if any), what each cron job expects to happen, and answers to common user prompts (`"what's the status"`, `"add a X"`, etc.).

- **`dashboard.json`** — the Scarf dashboard that renders on the catalog detail page and after install. See [awizemann/site-status-checker/staging/dashboard.json](awizemann/site-status-checker/staging/dashboard.json) for the schema in action.

Optional:

- `instructions/CLAUDE.md`, `instructions/GEMINI.md`, `instructions/.cursorrules`, `instructions/.github/copilot-instructions.md` — agent-specific shims beyond `AGENTS.md`.
- `skills/<skill-name>/SKILL.md` — shipped skills, installed into `~/.hermes/skills/templates/<slug>/` on the user's side.
- `cron/jobs.json` — an array of cron job specs. Each has `name`, `schedule` (e.g. `0 9 * * *` or `every 2h`), `prompt`, optional `deliver`, `skills[]`, `repeat`. The prompt may use these install-time placeholders — the installer substitutes them before registering the cron job with Hermes:
  - `{{PROJECT_DIR}}` — absolute path of the newly-installed project dir. **Required for any cron prompt that reads or writes project files** — Hermes doesn't set a CWD when firing cron jobs, so relative paths (`.scarf/config.json`) won't resolve. Write `{{PROJECT_DIR}}/.scarf/config.json` instead.
  - `{{TEMPLATE_ID}}` — the `owner/name` id from your manifest.
  - `{{TEMPLATE_SLUG}}` — the sanitised slug used for the project dir name + skills namespace.
- `memory/append.md` — markdown appended to the user's `MEMORY.md` between template-specific markers. Use sparingly — most templates don't need this.

### 4. Build the bundle

From the `staging/` directory:

```bash
cd ..
zip -qq -r <your-template-name>.scarftemplate staging/
mv <your-template-name>.scarftemplate .    # end up alongside staging/
```

Or equivalently:

```bash
cd staging && zip -qq -r ../<your-template-name>.scarftemplate . && cd ..
```

### 5. Test locally in Scarf

1. Open Scarf → Projects → Templates → **Install from File…** → select your `.scarftemplate`.
2. Walk through the preview sheet. Make sure every file, cron job, and memory block shown is something you meant to ship.
3. Install into a scratch parent dir. Verify the dashboard renders. Enable the cron job(s) if any and trigger them manually to confirm your `AGENTS.md` drives the right behavior.
4. Right-click the project → **Uninstall Template…** → verify nothing unexpected remains.

### 6. Validate

Before opening the PR, run the catalog validator locally:

```bash
python3 tools/build-catalog.py --check
```

This checks every template in the repo (including yours), verifies the manifest matches the bundle contents, refuses bundles >5 MB, and flags common secret patterns. If it fails, fix the reported issues before pushing.

### 7. Open the PR

```bash
git checkout -b add-<your-template-name>
git add templates/<your-handle>/<your-template-name>
git commit -m "feat(templates): add <your-template-name>"
git push origin add-<your-template-name>
gh pr create
```

**Do not modify `templates/catalog.json`** — the maintainer regenerates it after merge to keep PR diffs small.

The scarf repo ships a tailored submission checklist at [.github/PULL_REQUEST_TEMPLATE/template-submission.md](../.github/PULL_REQUEST_TEMPLATE/template-submission.md). To apply it to your PR, append `?template=template-submission.md` to the compare URL when opening the PR in the browser, or copy the checkbox list into the body manually.

GitHub Actions runs the validator on your PR (see [.github/workflows/validate-template-pr.yml](../.github/workflows/validate-template-pr.yml)). A green check means the bundle structure is sound; it doesn't mean the content is approved. Expect a maintainer pass for content quality (is the `AGENTS.md` clear, does the prompt do what you describe, is the scope reasonable).

### 8. Iterate + ship

Respond to review feedback. Common requests:

- Sharpen the `README.md` so install/uninstall steps are copy-pasteable.
- Split ambitious cron prompts into smaller, clearly-scoped ones.
- Remove things the template doesn't need (an empty `skills/` dir, an unused `deliver` target, etc.).

Once merged, your template shows up at `https://awizemann.github.io/scarf/templates/<your-handle>-<your-name>/` within a few minutes (the maintainer pushes the site regeneration by hand).

## Updating an existing template

Bump `version` in `template.json`, rebuild the `.scarftemplate`, commit, PR. The Install button on the catalog always points at the latest `main` version — there's no per-version pinning in v1. Users who already installed get no automatic update; they'd have to uninstall + reinstall for v2.

## Questions?

Open a [GitHub Discussion](https://github.com/awizemann/scarf/discussions) — the tag `templates` is watched.
