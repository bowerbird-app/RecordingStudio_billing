# Changelog

## Unreleased

Version `0.2.0`. Clean-install V1 contract reset. There is no upgrade path from
earlier experimental schemas.

### Breaking

- Price and overage-price `scope` is `market` (was `default`).
- Billing option tax policies are `exclusive`, `inclusive`, and `provider_default` (removed `automatic`).
- Collection methods are `automatic` and `send_invoice` (removed `invoice` and `manual` as collection values). Checkout presentation `invoice` is unchanged.
- Fake and dummy financial adapters now advertise the same checkout presentations as Stripe: `embedded`, `redirect`, `payment_link`, `invoice`, `no_charge`.
- Engine schema is a single `InstallRecordingStudioBilling` migration plus `db/schema/install_recording_studio_billing.sql`. Historical billing migrations were removed. Reinstall from a fresh database.
- Admin inventory is labeled **Products and pricing**.
- Provider capability checks use `commercial_configuration` instead of `catalogue`.

### Added

- `RecordingStudioBilling::V1Contract` for canonical V1 vocabulary and Stripe-shaped provider capabilities, including the shared market list used at checkout.
- Stripe checkout support for invoice presentation and `send_invoice` collection.

### Fixed

- Dummy seeds stay idempotent when loaded twice in one process. Plan-update fixtures are found by key, and seed apply runs are skipped when those runs already exist.

## 0.1.2

- Initial engine checkout from the RecordingStudio gem template.
