# Dummy App

This Rails app is the host that Recording Studio Billing mounts into. Use it to
exercise products, pricing, checkout, and admin inventory against PostgreSQL.
The Plan page and seeded journeys stay on the local fake provider. When Stripe
test keys are present, the dummy can also call the Stripe test account.

## What it covers

- Devise authentication with a seeded admin user who is the first Accessible owner of Studio Workspace and Billing Administration
- One Workspace billing root, one AdminRoot billing-admin root, and their child records
- SQL schema dumps that reproduce the PostgreSQL functions and triggers
- FlatPack UI: sign-in uses the gem-template `application` layout with `html data-theme="rounded"`; signed-in dummy and billing pages use Recording Studio's `recording_studio/default_layout` only (PageNav back/close, no left sidebar, no Sign out or Root Switchable control in that slot)
- Tailwind source scanning for dummy views, billing views/components, and bundled FlatPack/Recording Studio gems (`bin/rails tailwindcss:build` writes those gem paths first)
- Mounted customer billing at `/billing` and staff admin at `/admin`. RecordingStudioAdmin **Products and pricing** is registered on the Admin root
- V1 demonstration catalogue: one Workspace, one Admin root, Fake and Stripe-test providers, US/UK/Italy/Germany/global markets, distinct Italy vs Germany euro plan prices, free / $49 monthly / $490 annual with a trial, quantity add-on, prepaid credit pack, metered API-call service with allowance and overage caps
- Seeded checkout presentations, Italy vs Germany euro checkout quotes, a live monthly plan on the Plan page, usage, refund/adjustment (including an uncertain refund), plan-change states, a restricted payment portal, and a reconciliation issue. Tax calculators are registered and tax stays off

## Quick start

```bash
cd test/dummy
bundle install
bin/rails db:setup
bin/rails tailwindcss:build
bin/dev
```

Run those commands from `test/dummy`, not the repository root. The dummy app
uses `config.active_record.schema_format = :sql`. After schema changes, migrate
and commit `db/structure.sql`. Do not hand-edit `schema.rb`.

Sign in with:

- Email: `admin@admin.com`
- Password: `Password`

Switch roots on the dedicated Root Switchable page at
`/recording_studio_root_switchable/v1/root_switch?scope=all_workspaces`. That
moves between Studio Workspace (customer billing) and Billing Administration
(products and pricing). The default-layout slot does not render the switcher
or Sign out.

If published dummy records were created by an older seed (for example the
metered API-call product stored as a credit pack), reset from `test/dummy`:

```bash
bin/rails db:reset
```

## Useful routes

- `/` — dummy home
- `/billing` — customer billing (Plan Summary)
- `/billing/usage` — usage meters and prepaid credits
- `/plans` — plan picker (Free plan, Pro, Pro yearly)
- `/admin` — staff admin (Admin root)
- `/dummy_portal` — demonstration payment portal (payment methods, address, tax IDs, invoice history)
- `/users/sign_in` — Devise sign-in
- `/up` — Rails health check

## Seeds

`bin/rails db:seed` is idempotent, including when dummy tests load it more than
once in the same process. It creates the workspace and admin roots,
fake and Stripe-test provider accounts, US/USD, UK/GBP, Italy/EUR, Germany/EUR,
and global/USD markets with distinct Italy vs Germany euro plan prices, and
example products (free, $49 monthly, $490 annual with a trial, quantity add-on,
prepaid credit pack, metered API-call service with allowance and overage). The
fake provider has no credentials. In the test environment the Stripe-test
account still fails closed with `configuration_missing`. In development, set
Stripe *test* keys and the dummy installs a credential resolver:

```bash
# Cursor Cloud secrets already use these names:
# stripe_test_secret_key
# stripe_test_publishable_key
#
# Local shells can use the same names or:
export STRIPE_TEST_SECRET_KEY=sk_test_...
export STRIPE_TEST_PUBLISHABLE_KEY=pk_test_...
cd test/dummy
bin/rails stripe:ping
```

`stripe:ping` opens a $1 Checkout session on the Stripe test account and expires
it. Live `sk_live` keys are ignored. The dummy test suite skips the live Stripe
probe unless those test keys are in the environment.

### Test a subscription in the browser

With Stripe test keys present, development seeds a **Stripe Test Workspace** and
a **Stripe test monthly plan** at $1/month. Sign in, switch to that workspace,
open **Plan**, and choose the Stripe plan. The dummy executes this test checkout
inline and renders Stripe's embedded Checkout form.

Use Stripe's test card `4242 4242 4242 4242`, any future expiry, and any CVC.
The completed payment, customer, and subscription appear only in Stripe test
mode. The dummy still waits for a verified webhook or reconciliation before it
marks the purchase complete.

Dummy checkout presentations and collection methods match the production Stripe
contract: `embedded`, `redirect`, `payment_link`, `invoice`, `no_charge` and
`automatic` / `send_invoice`. Price scope is `market`. Checkout pages show
plans, prices, and tax at checkout. If a later Charge Market would change the
price, checkout requotes, restarts, rejects, or holds for review instead of
keeping the cheaper quote. Browser return does not complete a purchase.

Customer **Plan** is `/plans` (host route; gem-owned controller and Plan Picker).
After seed, Studio Workspace shows a title, subtitle, and three Flatpack Plan
Picker tiles for the US Free plan ($0), Pro ($49), and Pro yearly ($490). The
live Pro plan is marked current and keeps a "Current plan" footer so tiles stay
one height. Choose this plan is the action on the other tiles. Cancel is on
Overview. Change-request examples live on **Plan requests**
(`/billing/plan_requests`). `/billing/plan` redirects to `/plans` when the host
route is configured. Those screens sit in Recording Studio's default layout
(PageNav back, no sidebar, no Sign out or Root Switchable control in that slot).
Recurring dummy checkouts share one execution group, so the cancelled hybrid
journey is history on that same plan. Overview uses Plan Summary. Usage uses
Usage Meter, List rows, and Status Alert. Add-ons, Invoices, Payments, Billing
settings, checkout, invoice detail, and the demonstration payment portal stay on
cards, lists, badges, and buttons. The seeded Usage page calls
`effective_entitlements`, which raises when the live usage allowance (5) and
prepaid credit pack (1000) both grant `demo_api_calls` with `replace`. That is
catalogue data, not a layout bug. When Stripe test keys are present, a $1 Stripe
test plan named **Starter** is also published on the shared catalogue and can
take one of the Plan page's three tiles.

## Why this app exists

Use it to verify the billing engine in a real host. If a layout, route, asset
source, or Recording Studio initializer change breaks here, fix that before
changing adapters. Keep user-facing copy on **products, prices, and checkout**;
leave recordings and recordables in code. The dummy admin can open `/billing` and `/admin` because seeds bootstrap
Accessible ownership on the workspace and Admin root. A signed-in user
without a workspace grant receives `404` on customer billing.
