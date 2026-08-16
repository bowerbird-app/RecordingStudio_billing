# Recording Studio Billing

This engine owns commercial configuration, checkout, subscriptions, usage, tax, refunds, and provider adapters for RecordingStudio hosts. Stripe is the default production provider. The dummy app uses a local adapter so hosts can prove the same flows without Stripe.

User-facing screens should talk about **products, prices, and checkout**. Developer terms such as recordings and recordables stay in code and this document.

## V1 vocabulary

| Concept | Allowed values | Notes |
| --- | --- | --- |
| Price / overage price `scope` | `market` | Markets are the only V1 price scope. |
| Checkout presentation | `embedded`, `redirect`, `payment_link`, `invoice`, `no_charge` | How checkout is shown. `invoice` is a presentation, not a collection method. |
| Collection method | `automatic`, `send_invoice` | How money is collected after checkout. |
| Tax policy | `exclusive`, `inclusive`, `provider_default` | Optional tax. Missing tax data is fail-closed. |
| Provider markets | `AU`, `CA`, `DE`, `ES`, `FR`, `GB`, `IE`, `IT`, `NL`, `NZ`, `US` | Advertised by Stripe and the dummy adapter. Checkout evaluates the resolved country against this list. |

Canonical lists live in `RecordingStudioBilling::V1Contract`. Provider adapters must advertise the same checkout presentations and collection methods Stripe supports in production.

## Schema install

Hosts do not replay the engine’s historical migrations. A new install applies one engine migration that loads `db/schema/install_recording_studio_billing.sql`.

1. Run the install generator so the host copies engine migrations, including `InstallRecordingStudioBilling`.
2. Migrate the host database.
3. Commit `db/structure.sql`.

The SQL file is the source of truth for tables, functions, and triggers. It begins with
`SET check_function_bodies = false` so PL/pgSQL functions that use `%ROWTYPE` can be
created before their tables. Later schema changes should be new engine migrations plus
an updated install snapshot for fresh hosts. Existing hosts keep the incremental
migrations; they do not re-run the snapshot.

Webhook tables come from `recording_studio_webhooks`. Billing inbound-event tables store the webhook event id without a foreign key, so billing can install after the webhooks gem.

## Adapters

- **Stripe** (`RecordingStudioBilling::StripeAdapter`) is the production adapter. Invoice presentation uses hosted Stripe Checkout with invoice creation. `send_invoice` maps to Stripe subscription/invoice collection with `days_until_due`.
- **Dummy** (`DummyFinancialAdapter` in the test app) supports the same checkout presentations and collection methods. It does not call Stripe.
- **Fake** (`RecordingStudioBilling::FakeFinancialAdapter`) is for engine tests. Its default checkout and collection contract matches Stripe. Extra usage operations exist only so isolated usage tests can run without a live provider.

Do not introduce a second production checkout vocabulary in the dummy app.

## Products and pricing

Admin inventory lives under **Products and pricing**. The section key remains `billing_commercial` for hosts that already registered that navigation id.

Commercial publication still writes `rs_v3_commercial_configurations`. Capability checks use `commercial_configuration`, not a catalogue capability.

## What V1 does not include

Do not add these in this gem: quotes, trials, coupons, credits, dunning, retries, metered billing keys, proration, multiple providers in one install, or a customer self-serve portal. See `README.md`.
