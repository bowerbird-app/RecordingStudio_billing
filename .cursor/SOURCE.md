# Vendored Cursor skills

This directory vendors two skill packs so Cloud Agents can load them from the
checkout. Marketplace plugins are not currently injected into Cloud Agent
sessions reliably.

| Path | What |
|---|---|
| `.cursor/skills/` | pstack + Recording Studio plugin skills (merged by folder name) |
| `.cursor/agents/` | pstack (`poteto-agent`, `comment-sicko`) and Recording Studio specialists |
| `.cursor/rules/` | Recording Studio plugin standing rules (Flatpack, copy, RS constraints) |
| `.cursor/skills/LICENSE` | pstack MIT license (Lauren Tan, 2026) |
| `.cursor/skills/LICENSE-recording-studio` | Recording Studio plugin MIT (Bowerbird, 2026) |
| `.cursor/taste-skill-attribution.md` | leonxlnx/taste-skill MIT attribution |

Do not edit these files to change billing behavior. Refresh each pack separately
so one copy does not wipe the other.

## pstack

Upstream: https://github.com/cursor/plugins  
Plugin: `pstack` 0.14.5  
Commit: `b9ddc83c32972210b8a94d389130713e8eed346e`

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/cursor/plugins.git /tmp/cursor-plugins
git -C /tmp/cursor-plugins sparse-checkout set pstack
cp -R /tmp/cursor-plugins/pstack/skills/. .cursor/skills/
cp -R /tmp/cursor-plugins/pstack/agents/. .cursor/agents/
cp /tmp/cursor-plugins/pstack/LICENSE .cursor/skills/LICENSE
```

## Recording Studio plugin

Upstream: https://github.com/bowerbird-app/RecordingStudio_cursor_plugin  
Plugin: `recording-studio` 0.1.3  
Commit: `09d85eb1611af8d3060644e81de183fe0620316b`

```bash
git clone --depth 1 https://github.com/bowerbird-app/RecordingStudio_cursor_plugin.git /tmp/rs-cursor-plugin
cp -R /tmp/rs-cursor-plugin/skills/. .cursor/skills/
cp -R /tmp/rs-cursor-plugin/agents/. .cursor/agents/
mkdir -p .cursor/rules
cp /tmp/rs-cursor-plugin/rules/*.mdc .cursor/rules/
cp /tmp/rs-cursor-plugin/LICENSE .cursor/skills/LICENSE-recording-studio
cp /tmp/rs-cursor-plugin/docs/taste-skill-attribution.md .cursor/taste-skill-attribution.md
```

Then record the new commit SHA in this file.
