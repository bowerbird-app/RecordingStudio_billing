# Migration Notes

## Current Requirements

- Ruby 3.3 or newer
- Rails 8.1 or newer
- RecordingStudio `v4.0.0` (or compatible `~> 4.0`)
- RecordingStudioAccessible `~> 0.6` (RS 4 support branch until tagged)
- RecordingStudioRootSwitchable `~> 0.4`
- FlatPack `v0.1.132` or newer ViewComponent 4 release
- Public RubyGems and GitHub access for dependency installation

## Upgrading This Template To RecordingStudio 4

1. Pin sibling gems:

```ruby
gem "recording_studio", github: "bowerbird-app/RecordingStudio", tag: "v4.0.0"
gem "recording_studio_accessible",
    github: "bowerbird-app/RecordingStudio_accessible",
    branch: "cursor/support-recording-studio-4-8e1e"
gem "recording_studio_root_switchable",
    github: "bowerbird-app/RecordingStudio_root_switchable",
    tag: "v0.4.0"
gem "flat_pack", github: "bowerbird-app/flatpack", tag: "v0.1.132"
```

2. Install and migrate RecordingStudio harden indexes plus Accessible accesses recreation / root-switchable FK updates.
3. Enable `:accessible` on root recordables and configure `access_actor_types`.
4. Prefer `Recording.recent` or explicit `order:` — RecordingStudio 4 has no default newest-first order.
5. Follow RecordingStudio `docs/UPGRADING.md` for Event append-only and unsafe-query opt-in rules.

## Verification

```bash
bundle install
BUNDLE_GEMFILE=test/dummy/Gemfile bundle install
bundle exec rake test:all
```

```bash
cd test/dummy
bin/dev
```

Use the [FlatPack repository](https://github.com/bowerbird-app/flatpack) and the live FlatPack demo linked from the top-level README for current component documentation.
