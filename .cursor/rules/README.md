# Cursor rules in this repo

Cloud Agents load `.cursor/rules/*.mdc`. This folder has two sources.

## From the Recording Studio Cursor plugin

Do not edit these in billing. Refresh them from
[RecordingStudio_cursor_plugin](https://github.com/bowerbird-app/RecordingStudio_cursor_plugin)
as described in [SOURCE.md](../SOURCE.md).

| File | Always apply |
|---|---|
| `recording-studio.mdc` | Recording Studio hard constraints |
| `flatpack-is-the-system.mdc` | Code is always Flatpack |
| `flatpack-ui.mdc` | Flatpack for UI (glob: erb/html/css/js) |
| `user-facing-copy.mdc` | Product copy (glob: erb/html/md) |

## Account / team rules (this repo)

These are not in the plugin. A plugin refresh must not delete them.

| File | Covers |
|---|---|
| `verify-web-ui.mdc` | Browser verification of UI work |
| `screenshots-and-css.mdc` | Screenshots; CSS/JS actually loaded |
| `update-docs.mdc` | Holistic docs updates |
| `gem-versioning.mdc` | One bump per branch; release and upgrade notes |
| `pr-ci-reviews.mdc` | Wait for CI and PR reviews |
| `nic.mdc` | Nic is the user |
| `never-commit-secrets.mdc` | No secrets or ENV in git |
| `no-backwards-compat.mdc` | Prefer clean upgrades over compatibility layers |
| `param-conventions.mdc` | Parameter naming |
| `flatpack-conventions.mdc` | Ask before custom UI; legacy migration limits |
