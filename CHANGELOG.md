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

- Dummy seeds stay idempotent when loaded twice in one process. Plan-update and feature fixtures are found by key (and product, for features that share a key).
- Dummy UI loads FlatPack (`flat_pack/application` plus Tailwind sources that scan FlatPack components). Signed-in dummy pages use the gem-template left sidebar. Billing engine views use Recording Studio's `recording_studio/default_layout` when the host provides it.
- The engine no longer installs a restrictive Content-Security-Policy when the host has none, so import maps and Stimulus can run. Stripe origins are appended only when the host already has a CSP.
- Dummy catalogue seeds the V1 commercial graph: distinct Italy/Germany euro plan prices, a trial on the annual plan, a metered API-call service (not a credit pack), an allowance feature, prepaid credit-pack grants, checkout presentations, an uncertain refund, and a reconciliation issue. Fake tax calculators are registered with tax left off.
- Customer checkout is one lifecycle for embedded, redirect, payment link, invoice, and no-charge presentations. Charge Market finalization can requote, restart, reject, or review; frozen Italy/Germany euro prices stay on the original quote until the customer starts again.
- Billable workspace roots enable RecordingStudio Accessible. Dummy seeds grant the seeded admin `edit` on Studio Workspace so `/billing` works without stubbing authorization. Customer billing copy uses plans, prices, invoices, and usage instead of identifiers, option keys, or Market labels.
- Customer plan changes are select → compare → confirm → result, with cancel/resume confirmation and an effective date. Payments and invoices show refunds and adjustments, including requests waiting for confirmation. The payment portal is restricted to payment methods, address, tax IDs, and invoice history.
- Completing checkout after a cancellation reactivates the same execution-group subscription. Dummy seeds apply the hybrid cancellation before the live monthly checkout so the Plan page has a current plan.
- Customer billing screens are gem-owned pages mounted in Recording Studio's default layout. The host sidebar renders `CustomerSidebarComponent`. Plan is title, subtitle, and pricing cards; plan-request history is its own page; cancel stays on Overview.
- Display market resolution accepts verified host-country evidence, so Plan cards show the customer market price (dummy US $0 / $49 / $490) instead of the global fallback.

## 0.1.2

- Initial engine checkout from the RecordingStudio gem template.
