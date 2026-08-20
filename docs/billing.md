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

Hosts declare what each plan limit *means* in application code. Billing resolves the allowance; the host counts usage and enforces at create/action sites:

```ruby
RecordingStudioBilling.configure do |config|
  config.gates = {
    "projects" => {
      kind: :limit,
      label: "Projects",
      count: ->(root:) { Project.for_root(root).count }
    },
    "priority_support" => {
      kind: :boolean,
      feature_key: "priority_support",
      label: "Priority support"
    }
  }
end

RecordingStudioBilling.enforce_gate!(root_recording: workspace, gate_key: "projects") # => Result
RecordingStudioBilling.require_gate!(root_recording: workspace, gate_key: "projects") # raises when denied
RecordingStudioBilling.gate_allowed?(root_recording: workspace, gate_key: "projects")
```

Limit gates compare the configured `count` proc against `feature_value` for the same key. Boolean gates delegate to `entitled?`.

Commercial limits always resolve on the workspace root. For child-scoped quantities (for example comments on a page), pass an optional `subject:` so the host `count` proc can scope its query. Billing does not walk the recording tree or store per-child grants.

```ruby
RecordingStudioBilling.configure do |config|
  config.gates = {
    "pages" => {
      kind: :limit,
      label: "Pages",
      count: ->(root:) { Page.for_root(root).count }
    },
    "comments_per_page" => {
      kind: :limit,
      label: "Comments",
      count: ->(root:, subject:) { subject.comments.count }
    }
  }
end

RecordingStudioBilling.require_gate!(root_recording: workspace, gate_key: "pages")
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

Plan changes are select → compare → confirm → result. Cancel and resume show consequences and an effective date, and they never use GET. Payments and invoices show refunds and adjustments, including requests that are still waiting for confirmation. Those screens, plus Add-ons, Usage, Settings, checkout, and invoice detail, use FlatPack cards, lists, badges, and buttons rather than custom page chrome.

The customer **Plan** page lives at a host-nominated route (default `/plans`)
added by `draw_recording_studio_billing_plans` during install. The gem provides
`RecordingStudioBilling::PlansController`, `PlansPageComponent`, and reuses
`PlanCardsComponent`. It renders in Recording Studio core's
`recording_studio/default_layout` only — not the billing-engine sidebar shell.

The billing mount still exposes `GET /billing/plan`, which redirects to the host
plans route when configured. **Plan requests** stays under billing
(`/billing/billing/plan_requests`). The page shows a title, subtitle, and up to
three Flatpack pricing cards (free, monthly, and annual in the dummy). Cards show
the resolved customer-market price. The current plan is a badge on its card;
choosing another plan is the only action. Cancel lives on Overview. Dummy seeds
keep one live monthly plan after a cancelled hybrid checkout: recurring checkouts
share an execution group, so the applied cancellation is recorded first, then the
live monthly checkout reactivates that same plan.

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

Commercial publication still writes `rs_v3_commercial_configurations`. Capability checks use `commercial_configuration`, not a catalogue capability.

## What V1 does not include

Do not add these in this gem: quotes, coupons, cash credits, dunning, retries, graduated pricing, public usage HTTP ingest, or a customer self-serve portal that changes plans. The restricted provider portal above is the V1 payment-details surface. See `README.md`.

## Host layouts

Customer billing controllers render inside the host's Recording Studio default layout (`recording_studio/default_layout`) when that template exists. Gem-template hosts that only ship `flat_pack_sidebar` fall back to that left sidebar. Sign-in stays on the host `application` layout. Hosts render `RecordingStudioBilling::CustomerSidebarComponent` in the layout sidebar so Overview, Plan, Plan requests, and the other billing screens stay in Recording Studio chrome and update with the gem. Rebuild Tailwind after install so FlatPack component classes are present.
