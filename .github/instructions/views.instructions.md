---
description: "Use when editing ERB views, layout partials, or UI-facing Rails templates. Covers FlatPack-first UI decisions for this repository, with an emphasis on standardized and testable ViewComponents over custom HTML or JavaScript."
applyTo: ["app/views/**/*.erb", "test/dummy/app/views/**/*.erb"]
---

# View Guidelines

- Use the live FlatPack demo app at `https://flatpack-c6p8f.ondigitalocean.app/` as the approved UI reference when you need to inspect current shared components and patterns.
- Start with the demo app's table of components before introducing new custom UI.
- Prefer `render FlatPack::...` components over custom HTML whenever an equivalent component exists.
- Prefer standardized, testable FlatPack ViewComponents over one-off ERB structures or custom JavaScript behaviors.
- Treat user-provided FlatPack demo URLs as task context and let them guide the implementation or explanation.
- Keep raw HTML limited to simple semantic wrappers, prose, or content that FlatPack does not cover.
- Preserve the existing FlatPack visual language in the dummy app and engine views.
- When introducing custom markup, keep it minimal and avoid building ad hoc reusable controls in ERB.
- Do not add custom JavaScript for UI behavior until you have confirmed FlatPack or the existing Rails/Hotwire stack does not already provide the needed interaction.
- In Codespaces or other restricted environments, ask the user to enable access or provide sanitized screenshots, copied markup, or component details if the FlatPack demo app is not reachable.
