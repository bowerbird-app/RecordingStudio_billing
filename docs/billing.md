# Recording Studio Billing

This engine owns commercial configuration, checkout, subscriptions, usage, tax, refunds, and provider adapters for RecordingStudio hosts. Stripe is the default production provider. The dummy app uses a local adapter so hosts can prove the same flows without Stripe.

User-facing screens should talk about **products, prices, and checkout**. Developer terms such as recordings and recordables stay in code and this document.

## Capability map

Use this when asking whether V1 covers a commercial shape. The dummy catalogue is the working demonstration: plans, add-ons, credit packs, and a metered service, with Stripe as the production adapter and a local fake adapter in dummy.

### Subscriptions

Yes. Recurring checkout projects a `Subscription` under the billing account, with a `SubscriptionLine` per commercial item (plan or recurring add-on). Customer checkout, hybrid carts (plan plus add-on), trials, free $0 plans, cancel, and resume are first-class. Stripe Checkout uses `mode: subscription` and inline recurring `price_data` from the frozen billing option.

Customer plan, interval, add-on, and quantity changes go through `CreateSubscriptionChangeIntent` and the gem's own Plan screens, not the Stripe Customer Portal. The portal is restricted to payment methods, address, tax IDs, and invoice history.

Stripe follow-up mutations are narrower than local lifecycle. Checkout persists `sub_` / `si_` / `pi_` / `in_` on the financial command. It does not copy those onto the subscription recordable, and it does not persist a durable Stripe `price_` id (checkout creates ephemeral `price_data`). Cancel and resume against Stripe need a `sub_` on `Subscription#provider_reference`. Plan, interval, add-on, and quantity changes against Stripe also need `si_` and `price_` in the adapter change-set. Dummy / fake-provider journeys do not need those identities.

### Standalone products

The catalogue has four kinds: `plan`, `addon`, `credit_pack`, and `service`. Staff can create all four from Billing admin (`/billing/admin/products/new`). Products live in this gem, not in a Stripe product catalog. Checkout sends the frozen product name as Stripe `product_data.name`.

One-time purchases that complete checkout become a `Purchase` beside the subscription, not under it:

| Kind | Recurrence | After paid checkout |
| --- | --- | --- |
| `plan` | recurring | Subscription line (`monthly_subscription`, `annual_subscription`, `trial_subscription`, or `free_plan`) |
| `addon` | recurring | Subscription line (`recurring_addon`) |
| `addon` | one-time | Purchase (`one_off_addon`) |
| `credit_pack` | one-time | Purchase (`one_off_credit_pack`) |
| `service` | recurring | Treated as a subscription (monthly or annual) |
| `service` | one-time | Checkout intent can be created. Lifecycle projection raises `unsupported commercial lifecycle mode`. Dummy uses this only for presentation fixtures. |

The customer Add-ons screen offers published `addon` and `credit_pack` options. Product rules can require a live plan (the dummy quantity add-on does). Credit packs do not. There is no separate "one-off SKU" kind; a generic one-time product should be an add-on or a credit pack if it must complete as a purchase.

A prepaid credit pack is the usage-shaped purchase Stripe can charge. Checkout writes a `Purchase` and a credit-ledger credit of `allowance × quantity` (buy 200, or a 100-unit pack with quantity 2). The pack ledger for that SKU is still `credit_balance(root_recording:, product_recording:)`. Burn that SKU ledger with `consume_credits` (`insufficient_credit_balance` when empty).

A plan or metered service can include an allocated amount as an `allowance` on a nominated meter. Put the same allowance feature key on a `credit_pack` to sell more of that meter. Combined remaining is `remaining_credits(root_recording:, meter_key:)`. `record_usage` with that key burns the combined cap and denies with `exhausted_allowance` when it is gone. Separate meters stay separate, so API credits and AI credits do not mix.

`credit_balance` is the pack SKU ledger. Use `remaining_credits` when the host needs plan allocation plus packs on that meter. Dummy seeds `UsageCreditGrant` rows for rating and allocation. Checkout does not write those automatically. Combined remaining uses entitlement grants and usage events, not those seed grants.

### Metered billing

Local metering works. Hosts call `record_usage` from application code. Meters aggregate `sum`, `count`, `maximum`, or `latest`. Rating, allocation, allowance policies, prepaid credits, overage prices, and usage corrections are engine services. The dummy seeds a `service` product with an API-call allowance, records usage, rates the window, and calculates overage. The customer Usage screen shows that meter.

Charging that overage through a provider is adapter-specific. The fake adapter supports `usage_settlement` and `usage_correction`. The Stripe adapter does **not**: capability evaluation and `StripeAdapter#call` return `unsupported_operation` without a Stripe request. There is no Stripe Billing Meters or Metronome integration, and no public HTTP ingest for usage events.

Pricing models are `flat`, `per_unit`, and `package`. Graduated, volume, and stairstep prices are out of scope.

## Nominate a usage meter

A meter is what the host measures. Register it as an allowance feature whose key, `meter_key`, and `record_usage` usage key are the same string. Create a Usage unit (the thing being counted) and a Meter (how it aggregates) in Billing admin. Attach that allowance to a plan or metered service for the included amount, and to a credit pack to sell more of the same pool.

```ruby
RecordingStudioBilling.configure do |config|
  config.feature_definitions = {
    "api_credits" => {
      source: "catalogue", merge_rule: "replace", default: 0, type: "allowance",
      meter_key: "api_credits", usage_unit_key: "api_call", replenishment: "period",
      lifecycle: "subscription", consumption: "metered", ordering: 1, validation: { "minimum" => 0 }
    },
    "ai_credits" => {
      source: "catalogue", merge_rule: "replace", default: 0, type: "allowance",
      meter_key: "ai_credits", usage_unit_key: "ai_token", replenishment: "none",
      lifecycle: "purchase", consumption: "metered", ordering: 2, validation: { "minimum" => 0 }
    }
  }
end

pool = RecordingStudioBilling.meter_credits(root_recording: workspace, meter_key: "api_credits")
# pool.included, pool.purchased, pool.used, pool.remaining
RecordingStudioBilling.remaining_credits(root_recording: workspace, meter_key: "api_credits")
RecordingStudioBilling.record_usage(root_recording: workspace, usage_key: "api_credits",
                                    quantity: 1, idempotency_key: "call-#{id}")
```

`meter_key` must match the feature key. Nominated meters must be allowances. Remaining sums every live plan or purchase allowance on that key, then subtracts `usage_total`. Inventory limits such as projects stay on `feature_value` / gates and do not use this pool.

The dummy catalogue nominates `demo_api_calls` (a 1000-call pack plus a metered service with 5 included). After seed usage of 11 API calls, `remaining_credits` for `demo_api_calls` is 994. The gem suite covers a live plan allocation plus packs, and a second meter that stays isolated.

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
migrations; they do not re-run the snapshot. Payments are unique per financial command.
Invoices are unique per financial command too.

Webhook tables come from `recording_studio_webhooks`. Billing inbound-event tables store the webhook event id without a foreign key, so billing can install after the webhooks gem.

## Production host setup

The engine does not run Stripe, workers, or tax by itself. A host that takes money
must wire these four things before production checkout.

### Workers

Creating a checkout or subscription-change intent only binds a pending
`FinancialCommand`. After that bind the engine fires
`:financial_command_pending`. Register a host job there and call the public
execute helpers from that job. The engine ships no job class.

```ruby
RecordingStudioBilling.configuration.hooks.on(:financial_command_pending) do |command|
  ExecuteFinancialCommandJob.perform_later(command.id)
end
```

The dummy job is the reference: checkout calls `execute_checkout_intent`;
subscription changes call `execute_subscription_change_intent` then
`apply_subscription_change_intent` when execute succeeded. Dummy development
runs that job inline. Production must use a real queue and a worker process.

A `no_charge` checkout completes after execute and does not wait for a webhook.
Paid Stripe checkout still completes through webhook or reconcile. Browser
return is not confirmation.

### Stripe restricted keys

Resolve credentials from host-managed secrets. Production Stripe secret values
must be restricted keys (`rk_live` / `rk_test`), not full-account `sk_live`
keys. Grant the key only the surfaces this adapter calls:

- Checkout Sessions (create, retrieve, list line items)
- Subscriptions (retrieve, update)
- Invoices (retrieve)
- Refunds (create, retrieve)
- Credit notes (create)
- Billing Portal sessions and configurations
- Tax Calculations, if the host enables Stripe Tax

Publishable keys stay `pk_test` / `pk_live`. Dummy development still accepts
`sk_test` or `rk_test` plus `pk_test` and ignores live keys.

### Pin the Stripe API version

`StripeAdapter` sends Stripe-Version `2026-07-29.dahlia`
(`RecordingStudioBilling::StripeAdapter::STRIPE_API_VERSION`). Pin the same
version on the Stripe Dashboard for the account and webhook endpoint so
Checkout retrieve and webhook payloads stay on one contract. Do not let the
SDK default drift independently of this gem. Hosts that pass a custom
`client_factory` must send that same `stripe_version`.

### Tax registration or fail-closed

Tax stays off until a host commercial policy enables a registered calculator.
Stripe Tax also needs a Tax registration in the Stripe Dashboard for every
country you charge. Missing tax data, an unknown calculator, or a missing
registration is fail-closed: `unsupported_tax_calculation`, never an assumed
zero. Do not set `tax_policy.enabled` until those registrations exist and
`stripe_tax_code_resolver` returns a real Stripe tax code for each semantic
category.

### Webhook identity check

`RecordingStudioWebhooks` verifies the Stripe signature on the raw HTTP body.
`StripeAdapter#verify_webhook` does not verify signatures. It checks that the
already-verified envelope's event id and object id match the dispatch. Keep
that name; it is the adapter contract `ApplyProviderWebhook` calls.

## Adapters

- **Stripe** (`RecordingStudioBilling::StripeAdapter`) is the production adapter. Invoice presentation uses hosted Stripe Checkout with invoice creation. `send_invoice` maps to Stripe subscription/invoice collection with `days_until_due`. Checkout Session retrieve expands `line_items.data.price.product` and `subscription`. If that retrieve still omits line items or reports `has_more`, the adapter lists line items once with a limit of 100. Tax and discount come from `total_details`. If the list still has more than 100 items, retrieve withholds the financial payload so projection fail-closes instead of inventing totals. Listing uses Stripe's `sessions.line_items` API. The client must expose that surface. Paid retrieve also copies opaque Stripe identities (`sub_`, `si_`, `pi_`, `in_`) into the financial payload. `PersistCheckoutProviderIdentities` stores those rows so a later `invoice.paid` can resolve the original checkout command through the subscription when the new invoice id is unknown. Already-projected checkout money is not rewritten. Identities persist only after the first successful Checkout retrieve. An `invoice.paid` that arrives first stays unknown until Stripe retries. Checkout line items send the frozen product name as `product_data.name`.
- **Dummy** (`DummyFinancialAdapter` in the test app) supports the same checkout presentations and collection methods. Seeded Plan-page journeys stay on this local adapter. When Stripe *test* keys are present outside the Rails test environment, the dummy also installs `stripe_credential_resolver` from `stripe_test_secret_key` / `stripe_test_publishable_key` (or `STRIPE_TEST_*` / `STRIPE_*` aliases) so `bin/rails stripe:ping` can call the Stripe test account. Live keys are ignored. Dummy development runs `ExecuteFinancialCommandJob` inline after `:financial_command_pending`. That job calls `execute_checkout_intent` or execute-then-apply for subscription changes. The checkout controller does not call the adapter; development runs the job in-process so you do not need a worker.
- **Fake** (`RecordingStudioBilling::FakeFinancialAdapter`) is for engine tests. Its default checkout and collection contract matches Stripe. Extra usage operations exist only so isolated usage tests can run without a live provider.

Do not introduce a second production checkout vocabulary in the dummy app.

Stripe subscription Checkout uses inline recurring price terms from the frozen
billing option (`interval` and `interval_count`). In dummy development, valid
Stripe test credentials also add a separate Stripe Test Workspace and $1 monthly
plan. Dummy development runs `ExecuteFinancialCommandJob` inline after
`:financial_command_pending` so a developer can complete the embedded browser
flow without a separate worker. The checkout controller does not call the
adapter. Production hosts keep provider execution in their own job system.

The dummy seed is the V1 demonstration catalogue: one Workspace, one Admin root, Fake and Stripe-test providers, US/UK/Italy/Germany/global markets with distinct Italy vs Germany euro plan prices, free / monthly / annual (trial) / add-on / credit-pack / metered-service products, published manifests, checkout presentations (`embedded`, `redirect`, `payment_link`, `invoice`, `no_charge`), Italy and Germany euro checkout intents, hybrid subscription journeys, usage with allowance and overage, refunds and adjustments, and at least one reconciliation issue. Fake tax calculators are registered. Tax stays off until a later tax-demo pass.

Checkout is one customer-facing lifecycle for every presentation. The browser may send option IDs, quantities, a country or currency preference, and a presentation preference. The server freezes money, tax treatment, Charge Market, and the commercial manifest. If the final Charge Market would change price or terms, checkout requotes, restarts, rejects, or holds for review. Browser return pages show intent state only; they never fulfil a purchase.

Paid is the only payment state the engine treats as money in the door. Webhook apply, checkout reconcile, dummy retrieve, projected Payment and Invoice rows, and refunds all use `paid`. Dummy seed checkout always reconciles through that gate. It does not skip reconcile just because a `payment_state` key already exists.

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
RecordingStudioBilling.remaining_credits(root_recording: workspace, meter_key: "api_credits")
```

For a nominated meter, `feature_value` is the combined cap (plan plus packs). `remaining_credits` is what is left after `record_usage`. See [Nominate a usage meter](#nominate-a-usage-meter).

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

Plan changes are select → compare → confirm → result. Cancel and resume show consequences and an effective date, and they never use GET. Payments and invoices show refunds and adjustments, including requests that are still waiting for confirmation. Those screens, plus Add-ons, Usage, Settings, checkout, and invoice detail, use
Flatpack Billing and family parts (Plan Summary, Plan Picker, Usage Meter,
Status Alert, cards, lists, badges, and buttons) rather than custom page chrome.

The customer **Plan** page lives at a host-nominated route (default `/plans`)
added by `draw_recording_studio_billing_plans` during install. The gem provides
`RecordingStudioBilling::PlansController`, `PlansPageComponent`, and
`PlanCardsComponent` (a Plan Picker). It renders in Recording Studio core's
`recording_studio/default_layout` only — not the billing-engine sidebar shell.

The customer **Plan** page lives at a host-nominated route (default `/plans`)
added by `draw_recording_studio_billing_plans` during install. The gem provides
`RecordingStudioBilling::PlansController`, `PlansPageComponent`, and
`PlanCardsComponent` (a Plan Picker). It renders in Recording Studio core's
`recording_studio/default_layout` only — not the billing-engine sidebar shell.

The billing mount still exposes `GET /billing/plan`, which redirects to the host
plans route when configured. **Plan requests** stays under billing
(`/billing/plan_requests`). **Usage** is `/billing/usage` on the engine root
(not `/billing/billing/usage`). Nominated meters show combined credits left
first (plan allocation plus packs). Period usage is a Usage Meter; prepaid
credit grant rows and charges follow; other plan features stay in a named
"On this plan" list.

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

Admin inventory starts at **Billing**. Mount the shortcut before Admin:

```ruby
draw_recording_studio_billing_admin
recording_studio_admin_for :admin, at: "/admin", root_section: :billing
```

`/admin/billing` redirects to `/admin/sections/billing`. The first header
buttons link to Products, Plans, and Add-ons. The More menu starts with billing
options, prices, invoices, payments, and subscriptions.

The site Admin root enables these hubs:

| Hub | Widgets | Hub screen table |
| --- | --- | --- |
| Billing | Products, Plans, Add-ons | Products |
| Products and pricing | Products, Prices, Published manifests | Published manifests |
| Financial records | Invoices, Payments, Financial commands | Financial commands |
| Billing operations | Subscriptions, Plan updates, Reconciliation issues | Reconciliation issues |

The Billing widgets use Product names. Plans show only `kind=plan`. Add-ons show
only `kind=addon`. `billing_commercial`, `billing_financial`, and
`billing_operations` remain enabled public section keys.

Products, billing options, and prices have New, Edit, and Retire actions. New
and Edit open billing engine GET pages:

- `/billing/admin/products/new`
- `/billing/admin/products/:id/edit`
- `/billing/admin/options/new`
- `/billing/admin/options/:id/edit`
- `/billing/admin/prices/new`
- `/billing/admin/prices/:id/edit`

Product forms ask for Name, Key, Kind, and Provider. Plan and Add-on links lock
Kind in a hidden input. Billing option forms ask for the commercial terms on
the model. New billing options select a Product parent. Price forms ask for the
market and money fields. New prices select a Billing option parent. Every
option list stays inside the current Billing Admin tree.

Save posts to `create_draft_*` or `revise_*`. Retire posts to `retire_*` and
asks for confirmation. These operations use Recording Studio revisions and
`CommercialPublisher.retire!`. They never delete catalogue rows. The forms are
not Admin screens.

Each GET resolves an Admin root from its selected parent or edited item. It
uses a request-local Admin `Surface` for authorization. Missing or foreign
catalogue items return 404. An actor without the required Admin role gets 403.

Screens that filter on a catalogue `key` read `catalogue_key`. Admin screen
routes already use `params[:key]`. Account billing operations stays hidden on
the site Admin root. It becomes visible when the access root is a `:billing`
workspace. Dummy Admin hubs render `recording_studio_accessible_avatars` in the
default-layout slot.

Product and BillingOption require a human `name` as well as the stable
catalogue `key`. Inventory shows both. Dummy seeds use labels such as Monthly
plan, not copies of the key.

Commercial publication still writes `rs_v3_commercial_configurations`. Capability checks use `commercial_configuration`, not a catalogue capability.

## JSON API

This gem does not depend on `recording_studio_api`. Checkout, plan changes, and
settings are mounted HTML plus the public execute helpers. Accessible roles
come from `AccessActions`.

Adding the API engine here would pull a second mount, its migrations, a dummy
install, and named user vs operations APIs into a commercial-contract wave that
does not yet need a JSON surface. That is a later dedicated PR: register
capability actions 1:1 with `AccessActions::CUSTOMER` on the user API and
`AccessActions::SITE` on an operations API, with handlers that call the same
public helpers the UI uses.

Until then, hosts that need JSON add `recording_studio_api` in the host
application and wrap those helpers. Do not invent `app/controllers/api`
billing endpoints that skip Accessible.

## What V1 does not include

Do not add these in this gem: quotes, coupons, cash credits, dunning, retries, graduated pricing, public usage HTTP ingest, Stripe meter-event settlement, a provider portal that changes plans, or a billing JSON surface until `recording_studio_api` is a real dependency. Plan changes stay on the gem's own Plan screens. The restricted provider portal is the V1 payment-details surface. See the capability map above and `README.md`.

## Host layouts

Customer billing controllers render inside Recording Studio's default layout (`recording_studio/default_layout`) only. Include `RecordingStudio::UsesDefaultLayout` on authenticated host controllers. Sign-in stays on the host `application` layout. Billing screens set PageNav back/close. Do not put Sign out or a Root Switchable control in the default-layout slot. Hosts that want a sidebar can still render `RecordingStudioBilling::CustomerSidebarComponent`; dummy does not. Dummy puts `data-theme="rounded"` on `html` as well as `body` so Flatpack #159 can rebind button radius and charcoal primary. Rebuild Tailwind after install so FlatPack component classes are present. Do not copy button CSS into this gem.
