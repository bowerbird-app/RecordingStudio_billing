# Vendored Cursor skills

This directory vendors [pstack](https://github.com/cursor/plugins/tree/main/pstack)
so Cloud Agents can load the skills from the checkout. Marketplace plugins are
not currently injected into Cloud Agent sessions reliably.

| Path | What |
|---|---|
| `.cursor/skills/` | pstack skills (`/poteto-mode` and the rest) |
| `.cursor/agents/` | `poteto-agent` and `comment-sicko` |
| `.cursor/skills/LICENSE` | pstack MIT license (Lauren Tan, 2026) |

Upstream: https://github.com/cursor/plugins  
Plugin: `pstack` 0.14.5  
Commit: `b9ddc83c32972210b8a94d389130713e8eed346e`

Do not edit these files to change billing behavior. Refresh from upstream:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/cursor/plugins.git /tmp/cursor-plugins
git -C /tmp/cursor-plugins sparse-checkout set pstack
rm -rf .cursor/skills .cursor/agents
mkdir -p .cursor/skills .cursor/agents
cp -R /tmp/cursor-plugins/pstack/skills/. .cursor/skills/
cp -R /tmp/cursor-plugins/pstack/agents/. .cursor/agents/
cp /tmp/cursor-plugins/pstack/LICENSE .cursor/skills/LICENSE
```

Then record the new commit SHA in this file.
