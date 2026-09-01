# Cursor agent skills

Cloud Agents and local Cursor chats load project skills from `.cursor/skills/`.
This repository vendors two packs there so Cloud Agents can use them without
relying on marketplace plugins (which are not always injected into cloud
sessions):

- [pstack](https://github.com/cursor/plugins/tree/main/pstack) — `/poteto-mode`
  and related engineering workflows
- [Recording Studio Cursor plugin](https://github.com/bowerbird-app/RecordingStudio_cursor_plugin)
  — Recording Studio, Flatpack, and gem-building skills

The billing gem itself does not ship these files. The gemspec only packages
`app`, `config`, `db`, and `lib`.

## How to use them

For a non-trivial engineering task, start with a goal and a check:

```text
/poteto-mode the export writes duplicate rows when a retry lands mid-run. repro first, then fix and verify.
```

`/poteto-mode` picks a playbook and calls other pstack skills as steps need
them. Direct commands (`/how`, `/why`, `/architect`, `/arena`, `/interrogate`,
`/tdd`) still work when you want one pstack skill only.

For Recording Studio work, name the skill or describe the job. Examples:

```text
Use recording-studio-flatpack for this screen.
```

```text
Follow recording-studio-tests while adding coverage for this service.
```

Useful Recording Studio skills here: `recording-studio-getting-started`,
`recording-studio-gems`, `recording-studio-saving`, `recording-studio-ui`,
`recording-studio-flatpack`, `recording-studio-admin`, `recording-studio-access`,
`recording-studio-tests`. Specialists live in `.cursor/agents/`
(`rails-expert`, `ui-style-expert`, `minitest-coverage`, and others).

Standing rules live in `.cursor/rules/`. Plugin rules cover Recording Studio
constraints, Flatpack-only UI, and user-facing copy. Account and team rules
(browser verification, screenshots, gem versioning, CI, secrets, and similar)
are listed in [`.cursor/rules/README.md`](../.cursor/rules/README.md).

Origin and refresh steps: [`.cursor/SOURCE.md`](../.cursor/SOURCE.md).
The pstack guide is upstream:
[pstack/docs/guide](https://github.com/cursor/plugins/blob/main/pstack/docs/guide/README.md).

Repo-specific test guidance also lives in
[`.github/skills/minitest-workflow`](../.github/skills/minitest-workflow/SKILL.md).
That is a GitHub skill path; Cursor Cloud Agents load `.cursor/skills/` instead.

## What is not vendored

- pstack guide images and automations
- Recording Studio plugin slash commands (`/add-skill`, `/add-agent`) — those
  author the plugin repo, not this gem
- `cursor-team-kit` skills that pstack mentions (`deslop`, `control-cli`,
  `control-ui`). Install that plugin locally if you want them.
