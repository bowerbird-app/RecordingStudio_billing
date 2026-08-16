# Dummy App

This Rails app is the host that Recording Studio Billing mounts into. Use it to
exercise products, pricing, checkout, and admin inventory against PostgreSQL
without calling Stripe.

## What it covers

- Devise authentication with a seeded admin user
- One Workspace billing root, one AdminRoot billing-admin root, and their child records
- SQL schema dumps that reproduce the PostgreSQL functions and triggers
- FlatPack UI: sign-in uses the gem-template `application` layout; signed-in dummy pages use the left `flat_pack_sidebar` layout; mounted billing pages use Recording Studio's `recording_studio/default_layout` (the same left sidebar shell in this host)
- Tailwind source scanning for dummy views, billing views/components, and FlatPack
- Mounted customer billing. RecordingStudioAdmin **Products and pricing** is registered for later host wiring
- V1 demonstration catalogue: one Workspace, one Admin root, Fake and Stripe-test providers, US/UK/Italy/Germany/global markets, distinct Italy vs Germany euro plan prices, free / $49 monthly / $490 annual with a trial, quantity add-on, prepaid credit pack, metered API-call service with allowance and overage caps
- Seeded checkout presentations, Italy vs Germany euro checkout quotes, hybrid subscription, usage, refund/adjustment (including an uncertain refund), and a reconciliation issue. Tax calculators are registered and tax stays off

## Quick start

```bash
cd test/dummy
bundle install
bin/rails db:setup
bin/dev
```

Run those commands from `test/dummy`, not the repository root. The dummy app
uses `config.active_record.schema_format = :sql`. After schema changes, migrate
and commit `db/structure.sql`. Do not hand-edit `schema.rb`.

Sign in with:

- Email: `admin@admin.com`
- Password: `Password`

The root switcher moves between the Studio Workspace (customer billing) and
Billing Administration (products and pricing).

If published dummy records were created by an older seed (for example the
metered API-call product stored as a credit pack), reset from `test/dummy`:

```bash
bin/rails db:reset
```

## Useful routes

- `/` — dummy home
- `/billing` — customer billing
- `/users/sign_in` — Devise sign-in
- `/up` — Rails health check

## Seeds

`bin/rails db:seed` is idempotent, including when dummy tests load it more than
once in the same process. It creates the workspace and admin roots,
fake and Stripe-test provider accounts, US/USD, UK/GBP, Italy/EUR, Germany/EUR,
and global/USD markets with distinct Italy vs Germany euro plan prices, and
example products (free, $49 monthly, $490 annual with a trial, quantity add-on,
prepaid credit pack, metered API-call service with allowance and overage). The
fake provider has no credentials. The Stripe-test account fails closed with
`configuration_missing` until a host supplies real Stripe test credentials.

Dummy checkout presentations and collection methods match the production Stripe
contract: `embedded`, `redirect`, `payment_link`, `invoice`, `no_charge` and
`automatic` / `send_invoice`. Price scope is `market`. Checkout pages show
plans, prices, and tax at checkout. If a later Charge Market would change the
price, checkout requotes, restarts, rejects, or holds for review instead of
keeping the cheaper quote. Browser return does not complete a purchase.

## Why this app exists

Use it to verify the billing engine in a real host. If a layout, route, asset
source, or Recording Studio initializer change breaks here, fix that before
changing adapters. Keep user-facing copy on **products, prices, and checkout**;
leave recordings and recordables in code.
