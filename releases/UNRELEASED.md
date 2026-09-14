# Unreleased

Bullets for the next release's notes; `scarf-release-prep` folds these into `releases/v<version>/RELEASE_NOTES.md` and the README "What's New", then empties this file.

- Analytics: install id now persists across launches so retention can be measured. No new data is collected.
- Hermes target bumped to v0.21.2 (v2026.9.11); verified compatible at the tag and against a live 0.21.2 host.
- Backup: on Hermes v0.21.2+, "Backup Now" passes `--keep 0` so Hermes's new default no longer deletes your older `~/hermes-backup-*.zip` files.
