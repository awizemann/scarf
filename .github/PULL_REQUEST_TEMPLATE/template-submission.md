<!--
Use this template when submitting a new Scarf project template or updating
an existing one. For regular code/docs PRs, delete this template and write
your own summary.

Switch to this template by adding `?template=template-submission.md` to the
compare URL, or let GitHub pick it up automatically when you touch files
under templates/.
-->

## What's in this PR

- [ ] New template: `templates/<your-handle>/<your-template-name>/`
- [ ] Update to existing template: `templates/<author>/<name>/` (which one and why)

## One-line pitch

_What does this template do for its installers? Two sentences max._

## Checklist

- [ ] I wrote this template, or have the author's explicit permission to submit it.
- [ ] `AGENTS.md` is present and tells any cross-agent what the project does and how to run it.
- [ ] `README.md` includes install, customize, and uninstall instructions.
- [ ] The bundle's `template.json` `contents` claim matches what's actually in the zip.
- [ ] Cron jobs (if any) ship paused and use self-contained prompts.
- [ ] No secrets in any file (API keys, tokens, hostnames, IPs, credentials).
- [ ] No writes to `config.yaml`, `auth.json`, or credential paths — v1 installer will refuse.
- [ ] `python3 tools/build-catalog.py --check` passes locally.
- [ ] I installed + uninstalled this template on my machine and verified the `AGENTS.md` contract works end-to-end.
- [ ] I did **not** edit `templates/catalog.json` — the maintainer regenerates it post-merge.

## Testing notes

_What did you run, what did you see? Paste the log output of the cron job
firing once, or the chat transcript of asking the agent to do the main
thing. Reviewers don't have your machine — show, don't tell._

## Screenshots (optional)

_Drop screenshots of the installed dashboard, or the catalog detail page
rendered locally (`./scripts/catalog.sh preview && open /tmp/scarf-catalog-preview/templates/<slug>/index.html`)._
