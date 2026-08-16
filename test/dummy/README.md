# Dummy App

This Rails app is the host that Recording Studio Billing mounts into. Use it to
exercise products, pricing, checkout, and admin inventory against PostgreSQL
without calling Stripe.

## What it covers

- Devise authentication with a seeded admin user
- One Workspace billing root, one AdminRoot billing-admin root, and their child records
- SQL schema dumps that reproduce the PostgreSQL functions and triggers
- FlatPack layout and Tailwind source scanning
- Mounted customer billing and RecordingStudioAdmin **Products and pricing**

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

## Useful routes

- `/` — dummy home
- `/billing` — customer billing
- `/users/sign_in` — Devise sign-in
- `/up` — Rails health check

## Seeds

`bin/rails db:seed` is idempotent, including when dummy tests load it more than
once in the same process. It creates the workspace and admin roots,
fake and Stripe-test provider accounts, US/USD, UK/GBP, Italy/EUR, Germany/EUR,
and global/USD markets, and example products (free, monthly, annual, quantity
add-on, credit pack, meter, overage). The fake provider has no credentials. The
Stripe-test account fails closed with `configuration_missing` until a host
supplies real Stripe test credentials.

Dummy checkout presentations and collection methods match the production Stripe
contract: `embedded`, `redirect`, `payment_link`, `invoice`, `no_charge` and
`automatic` / `send_invoice`. Price scope is `market`.

## Why this app exists

Use it to verify the billing engine in a real host. If a layout, route, asset
source, or Recording Studio initializer change breaks here, fix that before
changing adapters. Keep user-facing copy on **products, prices, and checkout**;
leave recordings and recordables in code.
