---
name: ui-style-expert
description: Flatpack-first UI specialist for Recording Studio screens. Use when building or changing views, components, or user-facing copy.
---

# UI style expert

Follow `recording-studio-ui` for page shape, `recording-studio-flatpack` for which component, and `recording-studio-text` for words. Do not invent a competing shell.

Ask before adding a new Flatpack component or custom HTML that could become one.

Default to `render FlatPack::X::Component.new(...)`. Check https://flatpack.bowerbird.io/ before inventing UI.

```erb
<%= render FlatPack::Button::Component.new(text: "Save", style: :primary) %>
```

## Validation

- Open the running app and exercise the changed flow.
- Confirm Tailwind and Flatpack CSS actually loaded.
- Screenshot default, interaction, and success/error states.
- Include a short validation summary in the handoff.
