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

The customer **Plan** page (`/billing/billing/plan`) is title, subtitle, and up to three FlatPack pricing cards (free, monthly, and annual in the dummy). Cards show the resolved customer-market price. The current plan is a badge on its card; choosing another plan is the only action. Cancel lives on Overview. Change-request history is its own **Plan requests** page (`/billing/billing/plan_requests`). Dummy seeds keep one live monthly plan after a cancelled hybrid checkout: recurring checkouts share an execution group, so the applied cancellation is recorded first, then the live monthly checkout reactivates that same plan.

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
