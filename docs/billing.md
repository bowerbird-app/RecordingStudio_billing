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
- **Dummy** (`DummyFinancialAdapter` in the test app) supports the same checkout presentations and collection methods. Seeded Plan-page journeys stay on this local adapter. When Stripe *test* keys are present outside the Rails test environment, the dummy also installs `stripe_credential_resolver` from `stripe_test_secret_key` / `stripe_test_publishable_key` (or `STRIPE_TEST_*` / `STRIPE_*` aliases) so `bin/rails stripe:ping` can call the Stripe test account. Live keys are ignored.
- **Fake** (`RecordingStudioBilling::FakeFinancialAdapter`) is for engine tests. Its default checkout and collection contract matches Stripe. Extra usage operations exist only so isolated usage tests can run without a live provider.

Do not introduce a second production checkout vocabulary in the dummy app.

Stripe subscription Checkout uses inline recurring price terms from the frozen
billing option (`interval` and `interval_count`). In dummy development, valid
Stripe test credentials also add a separate Stripe Test Workspace and $1 monthly
plan. Its controller executes only Stripe test checkouts inline so a developer
can complete the embedded browser flow; production hosts keep provider
execution in their own job system.

The dummy seed is the V1 demonstration catalogue: one Workspace, one Admin root, Fake and Stripe-test providers, US/UK/Italy/Germany/global markets with distinct Italy vs Germany euro plan prices, free / monthly / annual (trial) / add-on / credit-pack / metered-service products, published manifests, checkout presentations (`embedded`, `redirect`, `payment_link`, `invoice`, `no_charge`), Italy and Germany euro checkout intents, hybrid subscription journeys, usage with allowance and overage, refunds and adjustments, and at least one reconciliation issue. Fake tax calculators are registered. Tax stays off until a later tax-demo pass.

Checkout is one customer-facing lifecycle for every presentation. The browser may send option IDs, quantities, a country or currency preference, and a presentation preference. The server freezes money, tax treatment, Charge Market, and the commercial manifest. If the final Charge Market would change price or terms, checkout requotes, restarts, rejects, or holds for review. Browser return pages show intent state only; they never fulfil a purchase.

## Subscriptions are recordables

A customer subscription is a Recording Studio recordable under the account
recording, and each commercial line — the plan, an add-on — is a
`RecordingStudioBilling::SubscriptionLine` recordable ("Plan line") under the
subscription. Both tables are immutable snapshots. Lifecycle moves and term
changes go through `revise`, which writes a new row and repoints the Recording;
notes go through `log_event!`. Database triggers reject `UPDATE` and `DELETE` on
both tables, so there is no in-place edit to reach for.

```ruby
subscription = RecordingStudioBilling::Subscription.for_root(workspace).sole
subscription.active_lines            # current terms, one row per line
subscription.lines.find_by(line_key: product_recording_id)
RecordingStudioBilling::SubscriptionLine
  .where(subscription_recording_id: subscription.recording.id)  # full history
```

Two consequences are easy to trip over:

- A snapshot you loaded before a revision keeps its old attributes forever. Call
  `subscription.current` (or `line.current`) to move to the live snapshot, and
  `current_recording` when you need the stable Recording.
- Anything that points at a subscription stores `subscription_recording_id`, not
  the recordable id, because the recordable id changes on every revision. That
  covers `SubscriptionChangeIntent`, `Invoice`, and `PlanUpdateApplication`, and
  it is why customer subscription URLs carry the Recording id.

Uniqueness of the execution group and the subscription identifier is enforced in
application code over `Subscription.with_current_recording`, serialized on the
account Recording. A unique index cannot express "unique among current snapshots".

## One-time purchases are recordables too

Buying a one-off add-on or a prepaid credit pack records a
`RecordingStudioBilling::Purchase` under the same account recording. It sits
beside the subscription rather than under it, because nothing about it recurs.
Customer screens still call these add-ons; "Purchase" is the admin label.

```ruby
purchases = RecordingStudioBilling::Purchase.for_root(workspace).order(created_at: :desc)
purchases.first.mode          # "one_off_addon" or "one_off_credit_pack"
purchases.first.completed_at  # when its entitlements and credits took effect
```

A purchase is bought once and never revised, so there is no separate effect row
to chase: `mode` says what was bought, `completed_at` says when it counted, and
`quantity` multiplies a credit pack's allowance. Entitlement grants and
credit-ledger entries both point at the purchase id.

Invoices may store `purchase_recording_id` (and `subscription_recording_id`) as
stable Recording foreign keys. Checkout invoice projection keys invoices by
`financial_command` and does not fill those columns today: money rows are
written before the purchase or subscription recordable exists, and a single
checkout command can cover more than one commercial item.

## Plan gates and entitlements

Completed checkout and applied subscription changes project entitlement grants automatically from the frozen commercial snapshot. Hosts gate product features with:

```ruby
RecordingStudioBilling.entitled?(root_recording: workspace, feature_key: "projects")
RecordingStudioBilling.feature_value(root_recording: workspace, feature_key: "seats")
```

### App-owned gates

Hosts declare what each plan limit *means* in application code. Billing resolves the allowance; the host counts usage and enforces at create/action sites.

Use gates for **inventory-style** checks (booleans and live quantity counts). Use usage, allowances, credits, and overage APIs for **consumed meters** (API calls this period). Do not wire metered consumption through `config.gates`.

```ruby
RecordingStudioBilling.configure do |config|
  config.feature_definitions = {
    "pages" => { source: "catalogue", merge_rule: "replace", default: 0, type: "limit", ... },
    "priority_support" => { source: "catalogue", merge_rule: "replace", default: false, type: "boolean", ... }
  }

  config.register_gate("pages", kind: :limit, label: "Pages", count: ->(root:) { Page.for_root(root).count })
  config.register_gate(
    "create_page",
    kind: :limit,
    feature_key: "pages", # gate key may differ from the plan feature key
    count: ->(root:) { Page.for_root(root).count }
  )
  config.register_gate(
    "priority_support",
    kind: :boolean,
    feature_key: "priority_support",
    label: "Priority support"
  )
end

RecordingStudioBilling.enforce_gate!(root_recording: workspace, gate_key: "pages") # soft Result
RecordingStudioBilling.enforce_gate!(root_recording: workspace, gate_key: "pages", mode: :hard) # raises
RecordingStudioBilling.require_gate!(root_recording: workspace, gate_key: "pages") # hard convenience
RecordingStudioBilling.gate_allowed?(root_recording: workspace, gate_key: "pages")
RecordingStudioBilling.require_gate!(root_recording: workspace, gate_key: "pages", quantity: 3)

status = RecordingStudioBilling.gate_status(root_recording: workspace, gate_key: "pages")
# => allowed, current, limit, remaining, unlimited, code, reason, message, upgrade_path, …
RecordingStudioBilling.gate_message(status) # product copy from deny code (also accepts EnforceGate::Denied)
```

Limit gates compare `current + quantity` to `feature_value` (default `quantity: 1`). Boolean gates delegate to `entitled?`.

Soft checks (`enforce_gate!`, `gate_allowed?`, `gate_status`) never raise. Hard checks (`require_gate!` or `mode: :hard`) raise `EnforceGate::Denied`. Use soft checks for UI banners and hard checks at write sites.

Result / `Denied` include `current`, `limit`, `remaining` (capacity left before this request), `quantity`, and a stable `code` (`limit_reached`, `not_configured`, `not_entitled`). Override deny copy through `config.billing_copy` keys such as `gate_limit_reached`.

A plan feature value of `-1` (`RecordingStudioBilling::EnforceGate::UNLIMITED`) means unlimited for limit gates.

When both `feature_definitions` and `gates` are present, call
`validate_gate_configuration!` after registration (for example at the end of
`to_prepare`) so Billing can check that each gate’s `feature_key` exists and that
gate `kind` matches the feature `type`.

Commercial limits always resolve on the workspace root. For child-scoped quantities (for example comments on a page), pass an optional `subject:` so the host `count` proc can scope its query. Billing does not walk the recording tree or store per-child grants.

```ruby
RecordingStudioBilling.configure do |config|
  config.register_gate(
    "comments_per_page",
    kind: :limit,
    label: "Comments",
    count: ->(root:, subject:) { subject.comments.count }
  )
end

RecordingStudioBilling.require_gate!(
  root_recording: workspace,
  gate_key: "comments_per_page",
  subject: page
)
```

If a gate `count` proc requires `subject:` and the call omits it, Billing raises `ArgumentError`. Root-only gates keep accepting `count: ->(root:) { ... }` and ignore an unused subject.

### Freemium bootstrap

Define a $0 plan in the admin catalogue and nominate it as the default free plan. When a billing account is created, Billing can project bootstrap grants from that plan's frozen published manifest — without a subscription or checkout:

```ruby
RecordingStudioBilling.configure do |config|
  config.default_free_plan_product_key = "free_plan"
end

RecordingStudioBilling.ensure_account(root_recording: workspace, name: "Billing account")
# or explicitly:
RecordingStudioBilling.apply_default_free_entitlements!(root_recording: workspace)
```

Bootstrap grants are append-only. When the workspace later has a live subscription, paid subscription and purchase grants take precedence; bootstrap rows remain in the database but are ignored for access checks.

Do not call `project_entitlements` after normal checkout or subscription-change projection unless you are repairing historical data. Replays of those projectors remain idempotent and re-ensure grants.

People may act on a workspace through RecordingStudio Accessible. Whether the workspace has paid for a feature is a separate entitlement check on the root.

## Customer billing access

Customer `/billing` pages authorize through RecordingStudio Accessible. `RecordingStudioBilling::Billable` enables `:accessible` on the workspace-like root. Hosts grant a person `view` to read billing and `edit` to checkout or change a plan:

```ruby
RecordingStudioAccessible.grant_access(
  recording: workspace_root,
  actor: current_user,
  role: "edit",
  manager_actor: current_user
)
```

The dummy seed grants `edit` on Studio Workspace to `admin@admin.com`. Do not stub `RecordingStudioAccessible.authorized?` in the host.

Customer screens use plan, price, invoice, and usage language. They do not show recording identifiers, option keys, or Market as primary labels. Display prices use the same trusted location evidence as checkout, so a US host sees US plan prices rather than the global fallback.

Overview composes Plan Summary in a three-column Grid. The primary action is
Change plan (to `/plans`). Status is omitted (`status: nil`) so there is no
badge. Cancel / resume sit in the same actions row as secondary buttons. The
footer slot is not used, so the card has no empty footer strip.

Plan changes are select → compare → confirm → result. Cancel and resume show consequences and an effective date, and they never use GET. Payments and invoices show refunds and adjustments, including requests that are still waiting. Invoice rows use short dates and symbol money (`26 Aug · $49`) and only keep a status when work is not done (`Waiting`). Those screens, plus Add-ons, Usage, Settings, checkout, and invoice detail, use
Flatpack Billing and family parts (Plan Summary, Plan Picker, Usage Meter,
Status Alert, cards, lists, badges, and buttons) rather than custom page chrome.

The customer **Plan** page lives at a host-nominated route (default `/plans`)
added by `draw_recording_studio_billing_plans` during install. The gem provides
`RecordingStudioBilling::PlansController`, `PlansPageComponent`, and
`PlanCardsComponent` (a Plan Picker). It renders in Recording Studio core's
`recording_studio/default_layout` only — not the billing-engine sidebar shell.

The billing mount still exposes `GET /billing/plan`, which redirects to the host
plans route when configured. **Plan requests** stays under billing
(`/billing/plan_requests`). **Usage** is `/billing/usage` on the engine root
(not `/billing/billing/usage`). Usage keeps Flatpack UsageMeter rows for each
period (window caption as `Last hour` / `This month` / `26 Aug`), then Credits
left, Usage charges (no Closed pill when settled; money as `$0.30`), and the
named "On this plan" feature list.

The Plan page shows a title, subtitle, and a three-column Plan Picker (Free
plan, Pro, and Pro yearly in the dummy). Tiles show the resolved
customer-market price. Product titles come from the required `Product#name`
column. Dummy stores Free plan, Pro, Pro yearly, and Starter on those rows.
`config.product_display_names` remains an offer-label fallback only. Choosable
tiles use **Choose plan**. The current tile is a disabled
**Current** button in the Plan Picker card body, not a badge. Cancel
and Resume sit on Overview in the Plan Summary actions row, next to Change plan.
Dummy seeds keep one live Pro plan after a cancelled hybrid
checkout: recurring checkouts share an execution group, so the applied
cancellation is recorded first, then the live monthly checkout reactivates that
same plan.

## Restricted payment portal

Provider portals may update payment methods, billing address, tax IDs, and invoice history. They must not change plans, prices, add-ons, quantities, or promotion codes. Those changes stay on Billing Intents. Dummy settings open a local demonstration portal at `/dummy_portal`. Stripe sessions use a restricted portal configuration unless the host supplies its own configuration id.

Hosts wire the portal with a provider-neutral resolver:

```ruby
RecordingStudioBilling.configure do |config|
  config.billing_portal_context_resolver = lambda do |account_recording:, **|
    { adapter_key: :stripe, customer_reference: account_recording.id.to_s }
  end
end
```

## Products and pricing

Admin inventory lives under **Products and pricing**. The section key remains `billing_commercial` for hosts that already registered that navigation id.

The site Admin root (`BillingAdminSupport`) enables three hubs:

| Hub | Widgets | Hub screen table |
| --- | --- | --- |
| Products and pricing | Products, Prices, Published manifests | Published manifests |
| Financial records | Invoices, Payments, Plan changes | Plan changes |
| Billing operations | Subscriptions, Plan updates, Reconciliation issues | Reconciliation issues |

Widget and inventory labels prefer human product names and formatted money
(`Starter · $1`, `Pro · $49`, `$49 · Paid`) over catalogue keys and raw minor
units. Manifest previews show `Pro · 26 Aug` when a product name is known;
hash-only rows are omitted. Plan change rows read `Plan change · Needs a look`
instead of `subscription_change · requires_reconciliation`.

A widget with a child screen links through to that inventory. Recording Studio
Admin only enables a screen when an enabled section links it, so each hub also
links the rest of its site-scoped inventory for discovery and direct URLs.
Screens that filter on a catalogue `key` read `catalogue_key` from the query
string. Admin routes already use `params[:key]` for the screen id, so reusing
`key` as a filter hid every row.
Account billing operations (feature overrides) is hidden on the site Admin
root. It becomes visible only when admin access is a `:billing` workspace root.
Dummy Admin hubs render `recording_studio_accessible_avatars` in the
default-layout slot. Configure `avatar_resolver` so granted actors become
avatars; + Access is only the empty-grant fallback.

Products inventory has a primary New button. It opens the Admin create screen
on the same Products and pricing section. The form asks for Name, then Key,
Kind, and Provider. Kind options are Plan, Credit pack, Add-on, and Service.
Provider options show the provider name without echoing the catalogue key.
Save posts to `create_draft_product`, which writes a
draft with `RecordingStudio.record!`. That path authorizes the registered
`billing_products` `create` action (`required_role :admin`). It does not use
a generic Admin form that writes published rows. Revise stays `revise`.
Publish stays `CommercialPublisher`.

Product and BillingOption require a human `name` as well as the stable
catalogue `key`. Inventory shows both. Dummy seeds use labels such as Monthly
plan, not copies of the key.

Commercial publication still writes `rs_v3_commercial_configurations`. Capability checks use `commercial_configuration`, not a catalogue capability.

## What V1 does not include

Do not add these in this gem: quotes, coupons, cash credits, dunning, retries, graduated pricing, public usage HTTP ingest, or a customer self-serve portal that changes plans. The restricted provider portal above is the V1 payment-details surface. See `README.md`.

## Host layouts

Customer billing controllers render inside Recording Studio's default layout (`recording_studio/default_layout`) only. Include `RecordingStudio::UsesDefaultLayout` on authenticated host controllers. Sign-in stays on the host `application` layout. Billing screens set PageNav back/close. Do not put Sign out or a Root Switchable control in the default-layout slot. Hosts that want a sidebar can still render `RecordingStudioBilling::CustomerSidebarComponent`; dummy does not. Dummy sets `data-theme="rounded"` on `html` via `_default_layout_head` (core already sets it on `body`) so Flatpack rounded button tokens inherit charcoal primary. Rebuild Tailwind after install so FlatPack component classes are present. Do not copy button CSS into this gem.
