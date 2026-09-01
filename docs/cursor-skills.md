# Cursor agent skills

Cloud Agents and local Cursor chats load project skills from `.cursor/skills/`.
This repository vendors [pstack](https://github.com/cursor/plugins/tree/main/pstack)
there so Cloud Agents can use the same workflows without relying on the
marketplace plugin (which is not always injected into cloud sessions).

The billing gem itself does not ship these files. The gemspec only packages
`app`, `config`, `db`, and `lib`.

## How to use them

In a Cursor Agent chat, start a non-trivial task with a goal and a check:

```text
/poteto-mode the export writes duplicate rows when a retry lands mid-run. repro first, then fix and verify.
```

`/poteto-mode` picks a playbook and calls the other skills as steps need them.
You do not need to name playbooks. Direct commands (`/how`, `/why`,
`/architect`, `/arena`, `/interrogate`, `/tdd`) still work when you want one
skill only.

Origin and refresh steps: [`.cursor/SOURCE.md`](../.cursor/SOURCE.md).
The pstack guide is upstream:
[pstack/docs/guide](https://github.com/cursor/plugins/blob/main/pstack/docs/guide/README.md).

Repo-specific test guidance stays in
[`.github/skills/minitest-workflow`](../.github/skills/minitest-workflow/SKILL.md).
That is a GitHub skill path; Cursor Cloud Agents load `.cursor/skills/` instead.

## What is not vendored

- pstack guide images
- pstack automations
- `cursor-team-kit` skills that pstack mentions (`deslop`, `control-cli`,
  `control-ui`). Install that plugin locally if you want them.
