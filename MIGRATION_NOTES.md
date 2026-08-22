# Migration notes

RecordingStudio Billing is a **clean-install** engine. Hosts apply the current engine migrations once. There is no supported upgrade from earlier experimental schemas in this repository.

## 0.8.0 — product and billing option names

Adds required `name` on `recording_studio_billing_products` and
`recording_studio_billing_billing_options`. Fresh installs pick it up from
install SQL. Existing hosts run
`20260822000001_add_name_to_products_and_billing_options`.

There is no production data and no backfill. Create, revise, and seed paths
must send `name` explicitly. Do not copy `key` into `name`. Dummy seeds use
human labels such as Monthly plan and Annual plan.

## 0.6.0 — app-owned gates and freemium bootstrap

Adds `recording_studio_billing_default_entitlement_bootstraps` and extends
entitlement grant `source_type` to include
`RecordingStudioBilling::DefaultEntitlementBootstrap`. Existing hosts run the
new engine migration; fresh installs pick up the updated install SQL snapshot.

Configure a published $0 plan product key and optional gates in
`RecordingStudioBilling.configure`. New accounts receive bootstrap grants when
`default_free_plan_product_key` is set. Re-seed or call
`apply_default_free_entitlements!` for accounts that already existed before this
upgrade if you need bootstrap rows in non-production environments.

Limit gates may pass optional `subject:` into the host `count` proc for
child-scoped quantities (for example comments on a page). Commercial limits
still resolve on the root; there are no per-child entitlement grants. Use
`quantity:` when creating more than one item, `feature_key:` when the gate name
differs from the plan feature, and `-1` on the plan feature for unlimited.
Prefer `register_gate` so addons can contribute without replacing the whole
registry. Inventory limits use gates; metered allowances use usage APIs.

Soft vs hard: `enforce_gate!` / `gate_allowed?` / `gate_status` are soft (no
raise). `require_gate!` or `enforce_gate!(mode: :hard)` raise
`EnforceGate::Denied`. Use `gate_message` (or `gate_status.message`) for
product copy, and `gate_status.upgrade_path` for the plans page link.

## 0.5.0 — host plans route

The install generator now adds a host-level plans route through
`draw_recording_studio_billing_plans` (default `/plans`). The gem owns
`RecordingStudioBilling::PlansController`, the presenter, and the Flatpack plan
cards. The page renders in `recording_studio/default_layout` only.

Existing hosts should add the route helper line to `config/routes.rb` and set
`config.plans_page_route_helper = :plans_path` (or whatever `as:` name you
choose). Customer billing `/billing/plan` redirects to that route when it is
configured.

## 0.4.0 — one-time purchases are recordables

`0.4.0` rewrites `db/schema/install_recording_studio_billing.sql` again. There is
no upgrade path from `0.3.x`: reinstall from a fresh database.

What changed in the schema:

- `recording_studio_billing_purchase_effects` is gone. Every purchase had exactly
  one effect, so `recording_studio_billing_purchases` absorbed it and now hangs
  off the account Recording as a recordable.
- `credit_ledger_entries.purchase_effect_id` is `purchase_id`, and the unique
  credit index is `(purchase_id, credit_key)`.
- `invoices.purchase_id` is `purchase_recording_id` and references
  `recording_studio_recordings`, parallel to `subscription_recording_id`.
  Checkout invoice projection does not populate it yet (invoices are keyed by
  `financial_command` and written before the purchase recordable exists).
- The entitlement grant source-type check and the credit-ledger and
  entitlement-projection triggers read the purchase row directly.

What changed for callers:

- `purchase.effects` is gone. `purchase.mode` says whether it was a one-off
  add-on or a credit pack, and `purchase.completed_at` is the effective time the
  effect used to carry.
- Read customer purchases through `Purchase.with_current_recording` (or
  `Purchase.for_root`) so a superseded snapshot never shows up as current.
- Entitlement grants written against `RecordingStudioBilling::PurchaseEffect` do
  not survive; they are reprojected from the purchase on a fresh install.

## 0.3.0 — subscriptions are recordables

`0.3.0` rewrites `db/schema/install_recording_studio_billing.sql`. There is no
upgrade path from `0.2.x`: a host that already installed billing has to reinstall
from a fresh database.

What changed in the schema:

- `recording_studio_billing_subscription_items` and
  `recording_studio_billing_subscription_item_versions` are gone.
  `recording_studio_billing_subscription_lines` replaces both and hangs off the
  subscription's Recording.
- `recording_studio_billing_subscriptions` and the new lines table are immutable
  snapshot tables. Triggers reject `UPDATE` and `DELETE`; a state or term change
  inserts a new row through `revise`.
- `subscription_change_intents`, `invoices`, and `plan_update_applications` now
  carry `subscription_recording_id` and reference `recording_studio_recordings`.
- The unique indexes on subscription identifier and execution-group fingerprint
  are now plain indexes. A revision would violate them, so uniqueness among
  *current* subscriptions is enforced in application code, which serializes on
  the account Recording before recording a new subscription.

What changed for callers:

- `subscription.items` and `subscription.item_versions` are gone. Use
  `subscription.lines`, `subscription.active_lines`, or
  `subscription.cancelled_lines`.
- Hold the Recording, not the snapshot, if you plan to read state later. A
  snapshot you already loaded keeps its old values after a revision; call
  `subscription.current` to move to the live one.
- Pass `subscription_recording:` where you used to pass `subscription:` on
  `SubscriptionChangeIntent`, `Invoice`, and `PlanUpdateApplication`.

## 0.2.1 — entitlement projection after checkout

From `0.2.1`, `project_completed_checkout_intent` projects entitlement grants
(and credit-pack ledger entries) for each new subscription item version or
purchase effect. Applied subscription changes already did this.

Hosts that called `project_entitlements` after checkout may keep those calls;
they are idempotent. New hosts should rely on automatic projection and gate
features with `entitled?` / `feature_value` on the workspace root.

No database migration is required for this behaviour change. Roots that
completed checkout on an older build without grants should run
`RecordingStudioBilling.project_entitlements(root_recording: root)` once as a
repair, or replay checkout projection for those intents.

## What the install generator copies

`rails generate recording_studio_billing:install` copies:

- engine migrations from `db/migrate/`
- the install guide into `docs/recording_studio_billing/INSTALL.md`

The billing snapshot SQL lives at `db/schema/install_recording_studio_billing.sql` inside the gem. The copied `InstallRecordingStudioBilling` migration reads that file from `RecordingStudioBilling::Engine.root` at migrate time. Hosts do not need a second copy of the SQL file.

Webhook tables come from `recording_studio_webhooks`. Install that gem first, or at least apply its webhook migrations before billing if your host keeps a foreign key. This engine stores webhook event ids without a billing-side foreign key.

Customer billing also needs RecordingStudio Accessible tables. After Recording Studio v3 removed core access tables, hosts install Accessible migrations so `grant_access` can persist workspace roles.

## After copying migrations

1. `bin/rails db:migrate`
2. Commit `db/structure.sql`
3. Restart the app

Do not edit copied engine migrations in the host. Schema changes belong in this gem, then a new engine migration for existing hosts plus an updated install snapshot for new hosts.

## Dummy app

`test/dummy` uses the same install migration. Reset it with `bin/rails db:drop db:create db:migrate` from `test/dummy`, then commit `test/dummy/db/structure.sql`.

The dummy host uses FlatPack and Recording Studio `UsesDefaultLayout`. Signed-in dummy, customer billing, and staff `/admin` pages use a thin dummy `recording_studio/default_layout` with `data-theme="rounded"` on `html` and `body`. Dummy/dev pins Flatpack #159 for rounded button tokens. Devise sign-in stays on `layouts/application`. Dummy seeds rebuild the V1 demonstration catalogue, grant the seeded admin Accessible `edit` on Studio Workspace and owner access on Billing Administration, and populate the three billing Admin hubs. Reset the dummy database if published records were created by an older seed. Customer billing needs the Accessible `recording_studio_accesses` table, which dummy restores after Recording Studio v3 removed core access tables.