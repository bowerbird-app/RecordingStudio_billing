# Dummy App

This Rails app validates the Recording Studio Billing foundation in a real host application.

## What It Covers

- Devise authentication with a seeded admin user
- `Current.actor` wiring for Recording Studio events
- One Workspace billing root, one AdminRoot billing-admin root, and their capability-owned child recordables
- SQL schema dumps that reproduce the PostgreSQL functions and triggers protecting billing history
- FlatPack layout integration and Tailwind source scanning
- Mounted `RecordingStudio::Engine` route behavior inside a host app

## Quick Start

```bash
cd test/dummy
bundle install
bin/rails db:setup
bin/dev
```

Run the commands above from the dummy app directory, not the repository root.
The dummy app intentionally uses `config.active_record.schema_format = :sql`;
commit `db/structure.sql` after migration changes and do not hand-edit
`schema.rb`.

Then open the app and sign in with:

- Email: `admin@admin.com`
- Password: `Password`

## Useful Routes

- `/` - dummy app home page and billing foundation overview
- `/recording_studio` - redirects to `/` while the mounted Recording Studio engine stays available under that prefix for non-root routes
- `/users/sign_in` - Devise sign-in page
- `/up` - Rails health check

## Billing Journeys

`bin/rails db:seed` is idempotent. It creates one named Workspace root with its
Billing Account and one named AdminRoot with its BillingAdmin, so the root
switcher can move between the customer and administration contexts. The seeded
catalogue has fake and Stripe-test provider accounts; US/USD, UK/GBP,
Italy/EUR, Germany/EUR, and global/USD markets; and distinct Italian and German
EUR prices. It also includes free, monthly, annual, quantity-addon, credit-pack,
meter, rate, cost, allowance/overage-price, product-rule, and published
plan-update examples.

The fake provider has no credentials and remains idempotent across seed reloads.
The Stripe-test account is exercised by a credential-free provider configuration
probe: it fails closed with `configuration_missing` before a Stripe client or
network request can be made. Supplying real Stripe test credentials, trusted
return URLs, and any required Stripe Tax configuration is external host-app
setup and is intentionally not part of the dummy seed.

Dummy integration coverage verifies seed idempotency, hierarchy, market prices,
root switching, a permitted customer billing route, denied customer and
unauthenticated admin requests, the credential-free Stripe provider path, and
manifest-authorized overage calculation. The journey reloads `db/seeds.rb` and
asserts that the fake-provider fixtures and Stripe configuration probe remain
idempotent.

The seed drives the hybrid checkout through the fake provider and reconciliation
contract, then projects its subscription, invoice, payment, refund, adjustment,
scheduled change, applied change, and account-scoped FeatureOverride with the
same public services used in production. The dummy adapter also provides a
trusted private invoice-download object for browser acceptance coverage.

## Why This App Exists

Use this app to verify the provider-agnostic foundation before adding commercial billing behavior. If a layout, route, asset source, or Recording Studio initializer change breaks here, fix the integration before adding provider adapters.

The authenticated layout in `app/views/layouts/flat_pack_sidebar.html.erb` and its minimal sidebar preserve the FlatPack host-app validation surface. Keep the home page focused on the billing foundation rather than adding commercial billing screens before their provider-neutral design is ready.
