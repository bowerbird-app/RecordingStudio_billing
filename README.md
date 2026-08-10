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

## Installation

Add the gem and its Recording Studio dependencies, then run:

```bash
bundle install
bin/rails generate recording_studio_billing:install
bin/rails generate recording_studio_billing:migrations
bin/rails db:migrate
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

Run the complete suite from the repository root:

```bash
bundle exec rake test
```
