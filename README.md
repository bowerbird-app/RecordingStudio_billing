# RecordingStudioBilling

`recording_studio_billing` is a Rails mountable engine that establishes the
provider-agnostic billing graph for Recording Studio. Its default provider is
Stripe, but phase 1 deliberately contains no provider client, charges,
invoices, subscriptions, webhooks, or other commercial billing behavior.

## Phase 1 foundation

- `Workspace` is a Recording Studio root that includes
  `RecordingStudioBilling::Billable`, enabling `:billing`.
- `AdminRoot` is a Recording Studio root that includes
  `RecordingStudioBilling::BillingAdminSupport`, enabling `:billing_admin`.
- `RecordingStudioBilling::Account` is the `:billing` child recordable.
- `RecordingStudioBilling::BillingAdmin` is the `:billing_admin` child
  recordable.
- The admin support concern uses the public
  `RecordingStudioAdmin::AllowsAdminSections` API to register `:billing`.

The capability metadata uses Recording Studio's public
`register_capability`, `enable_capability`, and `recording_studio_recordable`
APIs. Capability ownership derives the correct parent types, so `Account`
belongs below a billing-enabled workspace and `BillingAdmin` below a
billing-admin-enabled root.

## V1 commercial catalogue contract

This engine publishes validated, versioned commercial catalogue manifests only;
it does not create provider objects or process payments. `ProviderAccount`, `Market`,
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
central BillingAdmin catalogue. Every publication requires a persisted actor and
the configured `commercial_authorizer`. PostgreSQL triggers reject ordinary
direct non-draft inserts, in-place state transitions, incomplete revisions, and
mutations of published, retired, or historical snapshots.

The host application's database role, database owners, and migrations are part
of the trusted computing base. This engine does not provision a separate runtime
PostgreSQL principal, so its transaction settings and proof tables are not an
authorization boundary against arbitrary SQL executed by that trusted role.
Hosts that include arbitrary runtime-role SQL in their threat model must add
role separation and narrowly granted database operations at deployment time.

`FeatureOverride` is account-scoped rather than part of the central catalogue.
It therefore does not use `CommercialPublisher`; state or value revisions use
`RecordingStudioBilling::FeatureOverrideReviser`, which requires the configured
authorizer and a persisted actor and records that actor on the Recording Studio
revision event.

### Upgrading from the initial commercial hierarchy

Run the engine migrations after upgrading. The V1 correction removes the old
single-country/single-currency market fields, provider name, billing option
kind, and monetary rate fields. Logical price identities and versions are
validated against current Recording Studio revisions while immutable physical
snapshots remain available as commercial history.

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

Set the default provider in an initializer. Stripe is only a default symbol in
this phase; adding a Stripe SDK or any provider adapter is deferred.

```ruby
RecordingStudioBilling.configure do |config|
  config.provider = :stripe
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

  recording_studio_recordable label: "Admin", root: true
end
```

`BillingAdminSupport` requires the public `recording_studio_admin` engine,
which provides `RecordingStudioAdmin::AllowsAdminSections`.

## Dummy app

The PostgreSQL/UUID dummy app preserves Devise, FlatPack, Root Switchable,
Codespaces, and idempotent seeds. It creates exactly one Workspace root, one
AdminRoot, one billing Account, and one BillingAdmin record.

```bash
cd test/dummy
bin/rails db:setup
bin/dev
```

Sign in with `admin@admin.com` / `Password`.

## Validation

Run the complete commercial and dummy-app suite from the repository root:

```bash
bundle exec rake test:all
```
