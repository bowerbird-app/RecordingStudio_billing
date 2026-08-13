# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Renamed the engine to `recording_studio_billing` / `RecordingStudioBilling`.
- Added the provider-agnostic billing root and child-recordable foundation with Stripe as the default provider.
- Corrected the V1 commercial catalogue contract, including hierarchy,
  provider/market metadata, billing-option policy fields, price version
  constraints, and non-monetary unit conversion rates.
- Added deterministic, selected commercial publication candidates and verified
  manifest envelopes. Publication preserves stable Recording Studio identities,
  supports atomic price replacement, and leaves unrelated drafts untouched.
- Hardened market/overage resolution, rule/feature validation, and nested
  provider configuration secret detection.
- Added provider-neutral durable financial commands with database-enforced
  idempotency, append-only attempt history, reconciliation states, and a
  commit-before-adapter execution boundary. Atomic leases, stale-worker expiry,
  same-key recovery, strict manifest authority, and deterministic fake-adapter
  outcome mappings make interrupted operations safely recoverable.
- Corrected public billing documentation to describe the verified Webhooks
  boundary, server-authoritative checkout input, provider-neutral portal
  context, and the Stripe adapter's unsupported usage settlement and correction
  operations.

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

[Unreleased]: https://github.com/bowerbird-app/RecordingStudio_billing/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/bowerbird-app/RecordingStudio_billing/releases/tag/v0.1.2
[0.1.1]: https://github.com/bowerbird-app/RecordingStudio_billing/releases/tag/v0.1.1
[0.1.0]: https://github.com/bowerbird-app/RecordingStudio_billing/releases/tag/v0.1.0
