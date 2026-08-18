# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.3] - 2026-08-18

### Changed
- Upgraded the dummy app to RecordingStudio `v4.0.0`, RecordingStudioAccessible `0.6.0` (RS 4 support branch), and RecordingStudioRootSwitchable `v0.4.0`
- Bumped FlatPack from `v0.1.129` to `v0.1.132`
- Refreshed root and dummy lockfiles to current Rails `8.1.3.1` and compatible dependency updates (including Solid Cable 4, Solid Queue 1.6, image_processing 2 / ruby-vips, Puma 8, SimpleCov 1)
- Enabled `:accessible` on `Workspace`, added Accessible initializer allowlisting `User`, and installed the RecordingStudio 4.0 harden indexes migration plus Accessible accesses table recreation
- Updated FlatPack sidebar items to the `text:` API required by `v0.1.132`
- Removed unused root `sprockets-rails` dependency (dummy app uses Propshaft)
- Added `minitest-mock` so Minitest 6 still supports `Object#stub` in engine and dummy tests

### Upgrade Notes
- Host apps copying this template must move to RecordingStudio `~> 4.0` with Accessible `~> 0.6` and Root Switchable `~> 0.4`
- Until Accessible `0.6.0` is tagged on main, pin the published RS 4 support branch/ref
- Run `rails g recording_studio:migrations` (or install `harden_recording_studio_indexes_and_constraints`) and `rails db:migrate`
- Prefer `Recording.recent` / explicit `order:` (no default newest-first order); follow RecordingStudio `docs/UPGRADING.md` for Event append-only and query-safety changes
- Configure `RecordingStudioAccessible` `access_actor_types` and enable `:accessible` with `RecordingStudio.enable_capability(:accessible, on: YourRoot)`

## [0.1.2] - 2026-07-21

### Changed
- Bumped the dummy app FlatPack dependency from `v0.1.33` to `v0.1.129`

## [0.1.1] - 2026-04-28

### Changed
- Bumped the dummy app FlatPack dependency from `0.1.2` to `0.1.33` and pinned it by tag in `test/dummy/Gemfile`

## [0.1.0] - 2025-12-04

### Added
- Initial release
- Rails mountable engine structure
- PostgreSQL with UUID primary keys support
- TailwindCSS v4 integration
- GitHub Codespaces devcontainer configuration
- Docker Compose setup with PostgreSQL and Redis
- Install generator for host applications
- Comprehensive README and documentation
- Basic test suite with Minitest

[Unreleased]: https://github.com/bowerbird-app/gem_template/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/bowerbird-app/gem_template/releases/tag/v0.1.3
[0.1.2]: https://github.com/bowerbird-app/gem_template/releases/tag/v0.1.2
[0.1.1]: https://github.com/bowerbird-app/gem_template/releases/tag/v0.1.1
[0.1.0]: https://github.com/bowerbird-app/gem_template/releases/tag/v0.1.0
