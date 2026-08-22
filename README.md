# RecordingStudioBilling

`recording_studio_billing` is a Rails mountable, provider-neutral billing engine
for Recording Studio. It owns products and pricing, durable financial commands,
checkout intents, subscription and entitlement projections, usage rating, tax
calculations, and a mounted customer billing surface. Stripe is the built-in
provider key; hosts keep provider credentials in their own credentials or secret
manager.

Checkout completion and applied subscription changes project entitlement grants
automatically. Hosts gate paid features with `entitled?` / `feature_value` on
the workspace root (see [docs/billing.md](docs/billing.md)). People access is
still RecordingStudio Accessible on that root.

Customer subscriptions and their plan lines are Recording Studio recordables:
immutable snapshots written with `record!` and `revise`. Read current terms with
`subscription.active_lines` and follow a stale snapshot forward with
`subscription.current`. One-time purchases are recordables on the same account
recording; read them with `Purchase.for_root`. See
[docs/billing.md](docs/billing.md).

User-facing screens should say **products and pricing**, not developer catalogue
terms. Canonical V1 values are price scope `market`, checkout presentations
`embedded` / `redirect` / `payment_link` / `invoice` / `no_charge`, collection
methods `automatic` / `send_invoice`, and tax policies `exclusive` / `inclusive`
/ `provider_default`. See [docs/billing.md](docs/billing.md).

## Customer billing surface

Mount the engine in the host application and include Root Switchable controller
support in the host application controller:

```ruby
mount RecordingStudioBilling::Engine, at: "/billing"
```

Customer billing views use Recording Studio's default layout
(`recording_studio/default_layout`) only. Include
`RecordingStudio::UsesDefaultLayout` on authenticated host controllers. Devise
sign-in stays on the host `application` layout. Do not add a second sidebar
shell, and do not put Sign out or a Root Switchable control in the
default-layout slot.

The customer area is a set of gem-owned screens the host mounts. Each screen
is one job: Overview, Plan, Plan requests, Add-ons, Usage, Invoices, Payments,
and Billing settings. The **Plan** picker also mounts at a host-nominated route
(default `/plans`) via `draw_recording_studio_billing_plans`; the gem owns the
controller and ViewComponents. Billing pages render inside Recording Studio's
`recording_studio/default_layout` and set PageNav back/close. The Plan page is a
title, subtitle, and a Flatpack Plan Picker (up to three tiles). Hosts that still want a sidebar
can render `RecordingStudioBilling::CustomerSidebarComponent` themselves; dummy
does not. Every request uses the selected root;
an explicit mismatched root ID and an inaccessible root both return `404`.
Customer billing authorizes through RecordingStudio Accessible role grants on
the workspace root (`view` to read, `edit` to checkout or change a plan).
Including `RecordingStudioBilling::Billable` enables `:accessible` on that
root so hosts can grant access with `RecordingStudioAccessible.grant_access`.
Checkout return pages show the durable intent state only. They never fulfil an
intent: completion remains provider-webhook and reconciliation work.

### Customer checkout authority

The browser may submit commercial billing-option identifiers, quantities, a
country preference, a currency preference, and a checkout presentation
preference. The engine resolves the catalogue, Market, money, tax treatment,
provider operation, and final terms on the server. A client must never set or
be trusted for prices or other money values, tax, provider references or URLs,
Markets, discounts, or totals.

The mounted checkout-selection endpoint is `POST /billing/checkout`.
Plan Picker tiles start at `GET /billing/checkout/new`, which posts to that
endpoint.
It accepts an opaque `checkout_request_key`, optional `country_code`,
`currency_code`, and `presentation`, plus one or more items containing only
`billing_option_recording_id` and optional `quantity`. Invalid or
client-authoritative fields are rejected. Checkout completion is never inferred
from a browser return; it is projected only after provider-authoritative
reconciliation.

The same customer checkout page covers every V1 presentation: embedded,
redirect, payment link, invoice, and no-charge. Copy talks about plans, prices,
and tax at checkout. If the final Charge Market would change the frozen price
or terms, checkout stops at requote, restart, reject, or review. It never keeps
a cheaper ineligible price. Italy and Germany euro prices are resolved at
checkout, not only in seed data.

Invoice downloads are root scoped and set `Cache-Control: private, no-store`.
Applications must supply a trusted invoice document stream or a short-lived
provider redirect through their adapter integration; never expose provider
credentials or long-lived invoice URLs to the browser.

Plan changes use select → compare → confirm → result. Cancel and resume require
an explicit confirmation that names the effective date and consequences. Those
requests are never GET. The provider portal is restricted to payment methods,
billing address, tax IDs, and invoice history. It cannot change a plan, price,
add-on, quantity, or promotion code.

### Billing UI extension contracts

The customer UI uses namespaced ViewComponents and presenters for overview,
plans, plan requests, add-ons, usage, invoices, payments, checkout, and the
customer sidebar. Hosts can replace a page presenter, add sidebar items or page
content, customize copy, set a support link, and replace a provider-specific
component without copying engine templates. Render the gem sidebar in the host
Recording Studio layout:

```erb
<%= render RecordingStudioBilling::CustomerSidebarComponent.new(
      root_recording_id: current_root_recording&.id
    ) %>
```

```ruby
RecordingStudioBilling.configure do |config|
  config.billing_presenter_override(:usage, HostBilling::UsagePresenter)
  config.billing_provider_component(:primary, :checkout, HostBilling::CheckoutComponent)
  config.billing_copy = { usage_title: "Metering", support_label: "Contact support" }
  config.support_url = "https://support.example.test/billing"

  config.hooks.billing_navigation(priority: 150) do |presenter|
    { label: "Receipts", href: presenter.root_recording.receipts_path, icon: :document }
  end
  config.hooks.billing_page_content(:usage) do |presenter|
    HostBilling::UsageNoticeComponent.new(presenter:)
  end
end
```

Navigation hooks return `{ label:, href:, icon: }` hashes and page-content
hooks return a renderable ViewComponent or safe view content. Lower priorities
run first. Provider components are selected by the financial command's provider
key and receive `presenter:`. Stripe Embedded Checkout is registered only for
the built-in `:stripe` key; register a component for each custom provider that
needs browser presentation. Its JavaScript is packaged as an engine asset, so
hosts do not need an import-map pin. Presenter overrides may be classes or
callables that receive the default presenter class and return a replacement
class. Hooks run only during rendering; they must not make billing state changes.

## Recording Studio integration

- `Workspace` is a Recording Studio root that includes
  `RecordingStudioBilling::Billable`, enabling `:billing` and `:accessible`.
- `AdminRoot` is a Recording Studio root that includes
  `RecordingStudioBilling::BillingAdminSupport`, enabling `:billing_admin`.
- `RecordingStudioBilling::Account` is the `:billing` child recordable.
- `RecordingStudioBilling::BillingAdmin` is the `:billing_admin` child
  recordable.
- The admin support concern uses the public
  `RecordingStudioAdmin::AllowsAdminSections` API to register the site-scoped
  `:billing_commercial`, `:billing_financial`, and `:billing_operations`
  sections. Hosts enable `:accessible` on the Admin root themselves and grant
  Accessible access on that root. Admin 2.0 `authorize_resource!` and
  `site_admin_recording_resolver` use that grant; do not stub `authorized?`.

The capability metadata uses Recording Studio's public
`register_capability`, `enable_capability`, and `recording_studio_recordable`
APIs. Capability ownership derives the correct parent types, so `Account`
belongs below a billing-enabled workspace and `BillingAdmin` below a
billing-admin-enabled root.

### Administrative workflows

The registered RecordingStudioAdmin resources provide the V1 site-scoped
inventory screens, filters, capability and tax diagnostics, and audit-backed
POST actions for price publication, plan-update preview/confirmation/apply, and
provider-command reconciliation. Each action authorizes the actor through the
resolved `AdminRoot` RecordingStudioAdmin context before dispatching to the
corresponding domain service; it does not update billing rows directly.

RecordingStudioAdmin cannot generate safe CRUD forms for these recording-backed
models. Hosts that expose create or edit controls for provider accounts,
products and prices, tax/usage configuration, feature overrides, or plan updates
must create drafts with `RecordingStudio.record!` and revise existing records
with the relevant Recording Studio revision API. They must not mutate published
or historical recordables in place. Publication remains exclusively with
`CommercialPublisher`, and account-scoped feature overrides remain with
`FeatureOverrideReviser`. The admin inventory label is **Products and pricing**;
the section key remains `billing_commercial`.

## V1 products and pricing contract

This engine publishes validated, versioned commercial manifests and uses them to
create durable provider commands. `ProviderAccount`, `Market`,
`Product`, `ProductRule`, `PlanUpdate`, `UsageUnit`, `Meter`, `RateCard`, and
`CostCard` are direct `BillingAdmin` recording children. Their semantic links
(for example, a product's provider account) remain stable
`*_recording_id` references rather than recording-tree parents.

- Product kinds are `plan`, `addon`, `credit_pack`, and `service`.
- Feature types are `boolean`, `limit`, `allowance`, and `variant`.
- Meter aggregations are `sum`, `count`, `maximum`, and `latest`.
- Markets hold country and allowed-currency sets plus selection and policy
  metadata; they do not represent a single country/currency pair.
- Provider accounts contain neutral adapter metadata and safe capability
  configuration only. Store credentials in the host application's credentials
  or secret manager, never in this table.
- Billing options support only `flat`, `per_unit`, and `package` pricing.
  Graduated, volume, and stairstep pricing are intentionally out of scope.
- A price version is unique for its billing option, scope, market, and
  currency (and an overage price also includes its usage unit). At most one
  `published` version exists for that identity. Zero-valued prices are valid.
- Rates are unit conversions represented as either a positive rational
  numerator/denominator or a positive decimal. They are not customer money;
  `CostRate` retains monetary fields.

### Publication trust boundary

`RecordingStudioBilling::CommercialPublisher` is the only supported application
path from `draft` to `published`, or from `published` to `retired`, for the
central BillingAdmin product graph. Every publication requires a persisted actor
and the configured `commercial_authorizer`. PostgreSQL triggers reject ordinary
direct non-draft inserts, in-place state transitions, incomplete revisions, and
mutations of published, retired, or historical snapshots.

The host application's database role, database owners, and migrations are part
of the trusted computing base. This engine does not provision a separate runtime
PostgreSQL principal, so its transaction settings and proof tables are not an
authorization boundary against arbitrary SQL executed by that trusted role.
Hosts that include arbitrary runtime-role SQL in their threat model must add
role separation and narrowly granted database operations at deployment time.

`FeatureOverride` is account-scoped rather than part of the central product graph.
It therefore does not use `CommercialPublisher`; state or value revisions use
`RecordingStudioBilling::FeatureOverrideReviser`, which requires the configured
authorizer and a persisted actor and records that actor on the Recording Studio
revision event.

### Durable financial commands

All future external financial mutations must enter through
`RecordingStudioBilling.execute_financial_command`. The command creator
normalizes the Recording Studio root, verifies that the billing Account is its
direct child, canonicalizes all supplied authority and operation terms, and
uses a database unique index to arbitrate concurrent local idempotency claims.
Reusing a key returns `existing` for the same fingerprint or `conflict` for
materially different input.

The executor validates first, commits the command and its initial attempt in one
transaction, calls the adapter with no database transaction open, and persists
the normalized response in a new transaction. Adapters receive `command:`,
`request:`, and the durable `idempotency_key:` and return an object containing a
provider-neutral `state`, `normalized_result`, optional `provider_reference`,
`safe_error_details`, and `safe_metadata`. Unknown states become `unknown` in
the normalized result and require reconciliation. Exceptions after the call
boundary are recorded as uncertain without persisting exception messages.

Execution requires an atomic, expiring claim. A live lease prevents another
worker from calling the adapter. `expire_financial_command_claims` closes an
abandoned processing attempt as uncertain and moves its command to
`requires_reconciliation`. `recover_financial_command` then appends the next
attempt while reusing the command's original provider idempotency key; recovery
never generates a replacement mutation key. Supplied commercial manifests must
belong to the command root, be used, use the supported schema/resolver versions,
retain a valid digest, and remain protected by the immutable-history trigger.

Adapters return `AdapterResponse` using one of these normalized statuses:
`success`, `duplicate`, `invalid`, `unauthorized`, `unsupported`, the specific
`unsupported_*` statuses, `conflict`, `provider_unavailable`,
`provider_rejected`, `pending`, `stale`, `rate_missing`, `rate_ambiguous`,
`requires_review`, `failed`, or `unknown`. Unrecognized provider states remain
`unknown`; pending and uncertain results require explicit reconciliation.
`RecordingStudioBilling::FakeFinancialAdapter` deterministically produces every
status, duplicate responses, and timeout-after-possible-success behavior.

### Provider and tax contracts

Stripe ships as the built-in default provider and is registered under `:stripe`
during engine boot. Registration stores only adapter objects in process memory;
provider classes and credentials are never persisted. Before any real Stripe
operation, the host must configure a credential resolver backed by host
credentials or a secret manager. The engine never receives raw card data.

```ruby
RecordingStudioBilling.configure do |config|
  config.stripe_credential_resolver = -> { Rails.application.credentials.dig(:billing, :stripe) }
end
```

Custom adapters use the same registry API and can be selected as the host
default:

```ruby
provider = MyProviderAdapter.new
RecordingStudioBilling.register_provider(:primary, provider)
RecordingStudioBilling.configure { |config| config.provider = :primary }

calculator = MyTaxCalculator.new
RecordingStudioBilling.register_tax_calculator(:external_tax, calculator)
```

Provider adapters declare `ProviderCapabilities` for operations, currencies,
Markets, collection methods, checkout modes, tax modes, quantities,
composition, refunds, adjustments, and safe constraints. Calling
`adapter.capabilities.evaluate(operation: :charge, currency: :usd, market: :us)`
returns a supported flag, stable reason, safe explanation, and constraints.
Pass the same requirements as `capability_requirements:` to the financial
executor to reject unsupported work before adapter invocation.

Hosts must select an adapter whose declared capabilities support each requested
operation. In particular, the built-in Stripe adapter supports checkout,
subscription changes, refunds, and adjustments, but does **not** support
`usage_settlement` or `usage_correction`: both capability evaluation and
adapter execution return an unsupported result without sending a Stripe
request. Hosts that need provider usage settlement or corrections must register
an adapter that supports those operations, or safely handle the normalized
unsupported outcome and use a supported billing process.

Tax calculators declare `TaxCalculatorCapabilities`, including
`external_calculation` or `provider_calculation` mode, transactions, currencies,
Markets, inclusive/exclusive/provider-default behavior, data capabilities, and
safe constraints. Registration never enables tax. Tax is off unless an approved
host commercial policy explicitly enables the registered calculator:

```ruby
RecordingStudioBilling.configure do |config|
  config.tax_policy = {
    enabled: true,
    calculator_key: :external_tax,
    presentation: :exclusive,
    semantic_categories: %w[standard digital]
  }
end
```

`calculate_tax` accepts only server-authoritative roots, Accounts, used
Commercial Manifests, approved lines and integer minor-unit amounts, verified
locations, semantic categories, effective time, and an idempotency key. Unknown,
disabled, or unsupported tax returns `unsupported_tax_calculation`, never an
assumed zero. Completed and pending results append immutable `TaxCalculation`
history; identical retries return the existing calculation and materially
different reuse returns `conflict`. `recover_tax_calculation` reuses the durable
provider idempotency key and appends a linked revision rather than changing the
pending record. Provider-calculated tax is marked authoritative, while pending
tax is never final.

Requests, responses, command attempts, and tax history pass through safe payload
validation. Raw provider payloads, credentials, sensitive identifiers, URLs,
payment credentials, client-authored tax authority, and tax PII are rejected.
Tax rates, nexus, registrations, exemptions, thresholds, returns, filing,
remittance, and compliance advice remain outside this engine.

### Clean install only

This gem does not provide an upgrade path from earlier experimental schemas.
Hosts copy the current engine migrations (a single `InstallRecordingStudioBilling`
migration that loads `db/schema/install_recording_studio_billing.sql`), migrate,
and commit `db/structure.sql`. See [MIGRATION_NOTES.md](MIGRATION_NOTES.md).

## Installation

Add the gem and its Recording Studio dependencies, then run:

```bash
bundle install
bin/rails generate recording_studio_billing:install
bin/rails generate recording_studio_billing:migrations
bin/rails db:migrate
```

The install generator configures `config.active_record.schema_format = :sql`.
Keep the generated `db/structure.sql` under version control; PostgreSQL
functions and triggers enforce immutable commercial history and cannot be
represented by `schema.rb`. Regenerate the dump with:

```bash
bin/rails db:schema:dump
```

Stripe is the default provider key and its built-in adapter auto-registers at
boot. Configure host credentials before executing real Stripe work; without
them, execution returns the normalized provider-neutral `provider_unavailable`
result. The built-in adapter supports embedded and redirect Checkout,
provider-priced subscription changes, refunds, invoice credit-note adjustments,
provider-state retrieval for reconciliation, Customer Portal sessions, invoice
retrieval, and the existing Stripe Tax calculator contract. It does not support
meter-event usage settlement or usage correction. Every mutation uses the
durable command idempotency key and stores only opaque provider references.

The adapter intentionally does not infer Stripe product, price, subscription,
payment-intent, or invoice identities from local records. Hosts supply those
opaque provider references in the approved server-side command/change-set.
Unsupported shapes return `invalid` or `unsupported`; unrecognized remote
states remain `unknown` and require reconciliation.

Raw card data never reaches Rails; browser callbacks never fulfil an Intent.
Embedded Checkout requires `https://js.stripe.com`, Stripe API connections, and
Stripe checkout frames, which the engine adds to Rails CSP. Customer Portal
return URLs must have a host-configured trusted origin. Invoice PDFs are fetched
only from Stripe hosts, reject redirects/non-PDF responses, use bounded
timeouts, and stream with a 10 MiB running limit. Portal configuration must be
restricted to payment method, address/tax-ID, and invoice-history workflows;
the portal is not an authority for plans, quantities, promotions, cancellation,
or resumption changes.

### Provider portal integration

The engine's `POST /billing/portal` route uses the host's
`billing_portal_context_resolver`. Configure it to return only provider-
authoritative adapter and customer context. The resolver is called with
`root_recording:`, `account_recording:`, and the account's `subscriptions:`;
it must return `adapter_key:` and `customer_reference:`, with optional
provider-specific `options:`. The controller discards all other values and
requires the selected adapter to implement `portal_session`.

Do not derive portal customer identifiers from browser input or local guesses.
For Stripe, resolve the authoritative Stripe customer reference and configure a
trusted return origin; a Stripe portal configuration ID may be supplied through
the resolver options. Restrict the provider portal to payment methods,
address/tax-ID collection, and invoice history. Keep product, quantity,
discount, cancellation, resumption, and other commercial changes in host-owned
billing workflows.

```ruby
RecordingStudioBilling.configure do |config|
  config.stripe_trusted_origins = ["https://app.example.test"]
  config.billing_portal_context_resolver = lambda do |root_recording:, account_recording:, subscriptions:|
    {
      adapter_key: :stripe,
      customer_reference: HostBilling.customer_reference_for(account_recording),
      options: { configuration_id: Rails.application.credentials.dig(:billing, :stripe_portal_configuration_id) }
    }
  end
end
```

### Webhook integration boundary

`RecordingStudioWebhooks` owns the public HTTP webhook boundary: receiving the
request, verifying the provider signature while the raw body is available,
persisting the receipt, deduplicating it, and dispatching verified context.
Billing registers the `recording_studio_billing.provider_event.v1` action and
consumes that verified dispatch context. Billing then verifies the normalized
provider object identity, reconciles provider-authoritative command state, and
projects a completed checkout only when reconciliation succeeds.

Configure the Webhooks endpoint with the provider name and these non-secret
endpoint identity fields:

```ruby
{
  "billing_provider_adapter_key" => "stripe",
  "billing_provider_account_recording_id" => "<provider-account-recording-uuid>",
  "billing_environment" => "production"
}
```

The endpoint provider name must match `billing_provider_adapter_key`. Keep
signature credentials and other secrets in the host's credential or secret
manager configuration; do not place them in endpoint identity, provider-account
metadata, or engine records. Applications must not call Billing's webhook
reconciliation service from a browser callback or fabricate a receipt.

```ruby
RecordingStudioBilling.configure do |config|
  config.stripe_credential_resolver = -> { Rails.application.credentials.dig(:billing, :stripe) }
  config.support_url = "https://support.example.test/billing"
  config.billing_copy = { settings_notice: "Contact support to change payment methods." }
end
```

Configure strict Recording Studio declarations and include the corresponding
host-root concerns:

```ruby
RecordingStudio.configure do |config|
  config.recordable_types = [
    "Workspace",
    "AdminRoot",
    "RecordingStudioBilling::Account",
    "RecordingStudioBilling::BillingAdmin"
  ]
  config.require_recordable_declarations = true
end

class Workspace < ApplicationRecord
  include RecordingStudioBilling::Billable

  recording_studio_recordable label: "Workspace", root: true
end

class AdminRoot < ApplicationRecord
  include RecordingStudio::Recordable
  include RecordingStudioBilling::BillingAdminSupport

  recording_studio_recordable label: "Admin", root: true, shared: false
  RecordingStudio.enable_capability(:accessible, on: self)
end
```

`BillingAdminSupport` requires the public `recording_studio_admin` engine,
which provides `RecordingStudioAdmin::AllowsAdminSections`.

## Dummy app

The PostgreSQL/UUID dummy app preserves Devise, FlatPack, Root Switchable,
Codespaces, and idempotent seeds. Signed-in dummy and billing pages use
Recording Studio's `recording_studio/default_layout` only (`data-theme` rounded,
PageNav back/close, no Sign out or Root Switchable control in that slot). Devise
sign-in stays on `layouts/application`. Dummy
seeds bootstrap the first owner on the workspace and Admin root with
`bootstrap_owner_access!`, then mount staff admin at `/admin`. Its credential-free
demonstration products include
fake-provider checkout prices across US, UK, Italy, Germany, and a global
fallback. Monthly and annual plans have distinct Italy and Germany euro prices. The dummy also
seeds a metered API-call service with an allowance, rates, costs, and US
overage caps, plus free, $49 monthly, $490 annual (with a trial), quantity
add-on, and prepaid credit-pack examples. It creates one named
Workspace/Billing Account and one named AdminRoot/BillingAdmin for
root-switch demonstrations, as well as product-rule, plan-update, checkout
presentation, hybrid subscription, usage, refund, adjustment, and
reconciliation fixtures. Fake tax calculators are registered with tax left
off. Seeded journeys stay on the local fake provider and do not contact Stripe.
When Stripe *test* keys are present outside the Rails test environment, the dummy
installs a credential resolver from `stripe_test_secret_key` /
`stripe_test_publishable_key` (or `STRIPE_TEST_*` aliases) so `bin/rails
stripe:ping` can call the Stripe test account.

The dummy suite exercises seeded hierarchy and product assertions, root
switching, permitted customer billing, restricted customer/admin access, and
provider-projected hybrid subscription, invoice, payment, refund, adjustment,
plan-change, restricted portal, and FeatureOverride journeys. These fixtures use the same command,
reconciliation, projection, and revision services as production code.

The mounted `/billing` experience includes Overview, Plan, Add-ons, Usage,
Invoices, Payments, Billing settings, and Checkout. Copy on those pages talks
about plans, prices, tax, invoices, and usage. Dummy seeds grant the seeded
admin `edit` access on the Studio Workspace, so `/billing` works in development
without stubbing Accessible. Hosts must grant Accessible roles for customer and
site operations before rendering or executing actions.

```bash
cd test/dummy
bin/rails db:setup
bin/dev
```

Sign in with `admin@admin.com` / `Password`.

## Validation

Run validation from the repository root:

```bash
bundle exec rake test
bundle exec rake test:all
```

`bundle exec rake test` prepares the dummy app's isolated `app_test` database
and runs the root engine suite. `bundle exec rake test:all` also rebuilds the
dummy test database, applies migrations, dumps the schema, loads the idempotent
seed data, and runs the dummy app integration coverage plus the commercial
contract tests. The dummy application requires PostgreSQL and UUID support; its
credential-free fake-provider examples intentionally do not contact Stripe or
another network provider.
