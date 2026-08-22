# Changelog

## Unreleased

## 0.8.0

Turn the three billing Admin hubs into dashboards with inventory, instead of
empty section titles and filter-only screens.

### Added

- Products and pricing, Financial records, and Billing operations each show
  three list widgets of seeded rows. Each widget links through to its inventory
  screen (`billing_products`, `billing_prices`, `billing_manifests`,
  `billing_invoices`, `billing_payments`, `billing_financial_commands`,
  `billing_subscriptions`, `billing_plan_updates`,
  `billing_reconciliation_issues`).
- The three hub screens now render a table for the relation they already
  queried (published manifests, financial commands, reconciliation issues).
- Inventory screens that filter on catalogue `key` use the `catalogue_key`
  query param. Recording Studio Admin routes already occupy `params[:key]`
  as the screen id, so a filter named `key` hid every row.
- Financial command attempts and checkout intents tables now use columns that
  exist on those models (`attempt_number` / `provider_idempotency_key`, and
  `advisory_currency_code` / `presentation_preference`).
- Each hub also links every other site-scoped inventory screen in its area so
  Recording Studio Admin `screen_enabled?` returns those screens. They appear
  in `/admin/sections` search and return 200. Hubs still only surface the
  high-signal widget set.
- Account billing operations stays registered for hosts that administer a
  `:billing` workspace root, but it is hidden on the site Admin root. Dummy
  `/admin` no longer lists a section that 404s.

### Upgrade notes

- No host migration. Include `BillingAdminSupport` on the Admin root as before.
  The concern still enables `:billing_commercial`, `:billing_financial`, and
  `:billing_operations`. Inventory screens become reachable because those
  sections now link them; do not add placeholder sections.
- Account-scoped feature overrides remain a root-scoped screen. They appear
  only when the current admin access recording is a `:billing` workspace root
  that can render them. Dummy Admin stays on the site Admin root and does not
  invent a second feature-override UI.
- Create/revise stay `record!` / `revise`. Publish stays `CommercialPublisher`.
  Plan updates and reconciliation stay the existing POST domain actions.
- Bookmark or automation URLs that filtered inventory with `?key=` must switch
  to `?catalogue_key=`. The on-screen filter label is still Key.

## 0.7.0

Lift onto Recording Studio 4.2 and the matching Accessible / Admin / Webhooks /
Root Switchable / Flatpack pins. This is a version, enablement, and dummy-layout
change only.

### Breaking

- Gemspec floor is now `recording_studio ~> 4.2`, `recording_studio_accessible ~> 0.7.0`,
  `recording_studio_admin ~> 2.0.1`, `recording_studio_webhooks ~> 0.2.0`,
  `recording_studio_root_switchable ~> 0.5.0`, and `flat_pack ~> 0.1.133`.
- Customer billing and the plans page use Recording Studio
  `UsesDefaultLayout` / `recording_studio/default_layout` only. The
  `flat_pack_sidebar` fallback is gone.
- `Billable` no longer calls Accessible `Compatibility.register_access_capability!`.
  Accessible 0.7 registers `:accessible`; hosts enable it with
  `RecordingStudio.enable_capability(:accessible, on: Type)` (already done for
  workspace roots by `Billable`).
- Dummy authenticated pages drop the gem-template left sidebar. Sign-in stays on
  `layouts/application`. The default-layout slot has no Sign in, Sign out, or
  Root Switchable control. Staff admin is mounted at `/admin` on the Admin root
  with Accessible grants.
- Flatpack 0.1.133 buttons use `href:` (not `url:`). Host sidebar helpers that
  still render `CustomerSidebarComponent` must pass item `text:` and group
  `title:`.
- Site billing operations authorize through Admin 2.0 `authorize_resource!`
  against a real Accessible grant on the Admin root resolved by
  `site_admin_recording_resolver`. Tests no longer stub `authorized?`.

### Added

- Dummy Accessible / Admin / default-layout initializers match the 4.2 family.
  Seeds bootstrap the first owner on the workspace and Admin root with
  `bootstrap_owner_access!`.

### Upgrade notes

- Bump host Gemfile pins to the 4.2 family listed above. Dummy GitHub tags are
  `v4.2.0`, `v0.7.0`, `2.0.1`, `v0.2.0`, `v0.5.0`, and `v0.1.133`.
- Include `RecordingStudio::UsesDefaultLayout` on authenticated controllers.
  Do not copy a second sidebar shell. Set `html data-theme="rounded"` on Devise
  `application`; authenticated pages use the engine default layout. Do not put
  Sign out or the Root Switchable control in the default-layout slot.
- Configure `RecordingStudioAccessible` `access_actor_types` (for example
  `["User"]`). Enable `:accessible` on the Admin root. First owner: 
  `bootstrap_owner_access!`. Later invites stay `grant_access`.
- Mount admin with `recording_studio_admin_for` against the Admin root. Do not
  use `user.admin?` or `AllowsAccessibleChildren`. Site operations need an
  Accessible grant on that Admin root; `authorize_resource!` and
  `site_admin_recording_resolver` are the Admin 2.0 gate. Do not stub
  `authorized?`.
- Replace Flatpack Button `url:` with `href:` on any host overrides of billing
  screens.
- Recording Studio 4.2.0 default layout still passes Flatpack PageNav
  `back_url:` / `anchor_url:`. Flatpack 0.1.133 close reads `anchor_href:`.
  Do not fork the core layout from Billing.

## 0.6.1

Dummy host can talk to a Stripe test account from Cloud Agent secrets without
changing the fail-closed test suite.

### Added

- Dummy reads Stripe test keys from `stripe_test_secret_key` /
  `stripe_test_publishable_key` (Cursor Cloud secret names) or the uppercase
  `STRIPE_TEST_*` / `STRIPE_*` aliases. Only `sk_test` / `pk_test` values are
  accepted.
- Development and production dummy boots install `stripe_credential_resolver`
  when those test keys are present. The Rails test environment never does.
- `bin/rails stripe:ping` and an opt-in dummy integration test open then expire
  a $1 Stripe Checkout session against the test account.
- Stripe Checkout `redirect` sends `ui_mode=hosted_page` and `embedded` sends
  `ui_mode=embedded_page`, matching Stripe's March 2026 Checkout Session enum.
- Stripe subscription Checkout sends recurring interval terms from the frozen
  billing option.
- Dummy development seeds a separate Stripe Test Workspace and $1 monthly plan,
  then executes only its Stripe test checkouts inline for browser testing.

### Upgrade notes

- Host apps are unchanged. Keep resolving Stripe credentials in the host
  initializer as before.
- To exercise Stripe from the dummy app, set Stripe *test* keys in the process
  environment. Cursor Cloud secret names work as-is. The Plan page still uses
  the local fake provider; `stripe:ping` is the live adapter check.
- Hosts using Stripe Checkout `redirect` or `embedded` now send Stripe's
  `hosted_page` / `embedded_page` ui modes. No host code change is required.
- Subscription Checkout now requires valid recurring `interval` and
  `interval_count` terms. Existing published recurring billing options already
  provide them; invalid frozen terms fail before a Stripe request.

## 0.6.0

App-owned feature gates and silent freemium bootstrap from a published $0 catalogue plan.

### Added

- `config.gates` / `register_gate` for host-defined limit and boolean gates with
  `enforce_gate!` (soft by default, `mode: :hard` optional), `require_gate!`,
  `gate_allowed?`, `gate_status`, and `gate_message`. Optional `subject:`
  scopes child counts; optional `quantity:` reserves multiple units; optional
  `feature_key:` maps a gate to a different plan feature. Limit value `-1` means
  unlimited. Results expose `remaining` and stable deny `code`s. Call
  `validate_gate_configuration!` after registering gates and feature definitions.
- `config.default_free_plan_product_key` and `apply_default_free_entitlements!`
  to project bootstrap grants from a published free plan manifest when an account
  is created (also invoked from `ensure_account` when configured).
- `RecordingStudioBilling::DefaultEntitlementBootstrap` entitlement source.
  Bootstrap grants are ignored while a live subscription is active.
- Dummy hosts a real `Project` recordable under `Workspace`, gates
  `demo_projects` with `Project.for_root`, and seeds a starter project plus a
  `/projects` Flatpack screen that uses soft status and hard create enforcement.

### Upgrade notes

- Run engine migrations (including `AddDefaultEntitlementBootstrap`) or reinstall
  from the updated `install_recording_studio_billing.sql` snapshot on fresh hosts.
- Set `config.default_free_plan_product_key` to a published plan product key and
  declare `config.gates` for features your app enforces locally.
- Ensure the nominated free plan is published with the intended feature values
  before accounts are created in production.

## 0.5.0

Hosts can mount a first-class customer plans page at any URL while the gem owns
the controller, presenter, and ViewComponents.

### Added

- `draw_recording_studio_billing_plans path: "/plans"` routing helper for host
  `config/routes.rb`. Default install adds `/plans`.
- `RecordingStudioBilling::PlansController#show` renders `PlansPageComponent`
  and `PlanCardsComponent` inside the host's `recording_studio/default_layout`
  only.
- `RecordingStudioBilling::PlansPresenter`, `config.plans_page_route_helper`,
  and `config.plans_page_requires_sign_in` (default `true`).
- Billing **Plan** sidebar links and **View plans** buttons resolve through the
  host plans route when configured. `GET /billing/plan` redirects there.
- Dummy Tailwind writes `@source` paths from `bundle show` before
  `tailwindcss:build`, so Flatpack sidebar layout utilities compile under rbenv
  as well as vendor/bundle and CI.

### Upgrade notes

- Re-run `rails generate recording_studio_billing:install` is not required for
  existing hosts. Add `draw_recording_studio_billing_plans path: "/plans"` (or
  your chosen path) to `config/routes.rb` and set
  `config.plans_page_route_helper` to match the route `as:` name.
- Ensure the host provides `app/views/layouts/recording_studio/default_layout.html.erb`
  from Recording Studio getting-started setup.

## 0.4.0

One-time purchases are Recording Studio recordables. Clean-install only.

### Breaking

- `RecordingStudioBilling::Purchase` is a recordable under the account recording,
  written with `record!`. It is an immutable snapshot: triggers reject `UPDATE`
  and `DELETE`.
- Removed `RecordingStudioBilling::PurchaseEffect` and its table. A purchase was
  always paired with exactly one effect, so the purchase now carries the whole
  story. Read the kind from `purchase.mode` (`one_off_addon` or
  `one_off_credit_pack`) and the timing from `purchase.completed_at`.
- `EntitlementGrant#source_type` is `RecordingStudioBilling::Purchase` instead of
  `RecordingStudioBilling::PurchaseEffect`.
- `CreditLedgerEntry` credits reference `purchase_id` instead of
  `purchase_effect_id`.
- `Invoice` references `purchase_recording_id` (the stable Recording id) instead
  of `purchase_id`, matching `subscription_recording_id`. Checkout invoice
  projection still keys invoices by `financial_command` and leaves those
  columns null when money is projected before the purchase exists.

### Added

- `Purchase.for_root`, `Purchase.recording_for`, `Purchase#current`,
  `Purchase#current_recording`, and `Purchase#to_param` (returns the Recording
  id), matching `Subscription`.
- Completing a one-time checkout item logs a `purchase_completed` event on the
  account recording.

## 0.3.0

Customer subscriptions are Recording Studio recordables. Clean-install only.

### Breaking

- `RecordingStudioBilling::Subscription` is a recordable under the account
  recording, and the new `RecordingStudioBilling::SubscriptionLine` ("Plan line")
  is a recordable under the subscription. Both are immutable snapshots written
  with `record!` and `revise`, so lifecycle changes and term changes append a new
  row instead of updating one.
- Removed `RecordingStudioBilling::SubscriptionItem` and
  `RecordingStudioBilling::SubscriptionItemVersion`, along with their tables.
  Read current terms from `subscription.lines` / `subscription.active_lines`, and
  read history from `SubscriptionLine.where(subscription_recording_id: ...)`.
- `SubscriptionChangeIntent`, `Invoice`, and `PlanUpdateApplication` reference
  `subscription_recording_id` (the stable Recording id) instead of
  `subscription_id`. A revision changes the recordable row id; the Recording id
  does not.
- `EntitlementGrant#source_type` is `RecordingStudioBilling::SubscriptionLine`
  instead of `RecordingStudioBilling::SubscriptionItemVersion`.
- Customer subscription routes carry the Recording id. `Subscription#to_param`
  returns it, and the controller still accepts a recordable id.

### Added

- `Subscription#current` and `Subscription#current_recording` (and the same pair
  on `SubscriptionLine`) walk a superseded snapshot forward to the live one.
- `Subscription.recording_for` accepts a Recording, a snapshot, or either id.

## 0.2.1

Entitlement grants project automatically when checkout completes.

### Fixed

- Completing checkout now projects entitlement grants (and credit-pack ledger
  entries) from each new subscription item version or purchase effect. Replaying
  checkout projection re-ensures those grants. Hosts can call `entitled?` /
  `feature_value` after checkout without a separate `project_entitlements` step.
  Applied subscription changes already projected entitlements; that path is
  unchanged.

## 0.2.0

Version `0.2.0`. Clean-install V1 contract reset. There is no upgrade path from
earlier experimental schemas.

### Breaking

- Price and overage-price `scope` is `market` (was `default`).
- Billing option tax policies are `exclusive`, `inclusive`, and `provider_default` (removed `automatic`).
- Collection methods are `automatic` and `send_invoice` (removed `invoice` and `manual` as collection values). Checkout presentation `invoice` is unchanged.
- Fake and dummy financial adapters now advertise the same checkout presentations as Stripe: `embedded`, `redirect`, `payment_link`, `invoice`, `no_charge`.
- Engine schema is a single `InstallRecordingStudioBilling` migration plus `db/schema/install_recording_studio_billing.sql`. Historical billing migrations were removed. Reinstall from a fresh database.
- Admin inventory is labeled **Products and pricing**.
- Provider capability checks use `commercial_configuration` instead of `catalogue`.

### Added

- `RecordingStudioBilling::V1Contract` for canonical V1 vocabulary and Stripe-shaped provider capabilities, including the shared market list used at checkout.
- Stripe checkout support for invoice presentation and `send_invoice` collection.

### Fixed

- Dummy seeds stay idempotent when loaded twice in one process. Plan-update and feature fixtures are found by key (and product, for features that share a key).
- Dummy UI loads FlatPack (`flat_pack/application` plus Tailwind sources that scan FlatPack components). Signed-in dummy pages use the gem-template left sidebar. Billing engine views use Recording Studio's `recording_studio/default_layout` when the host provides it.
- The engine no longer installs a restrictive Content-Security-Policy when the host has none, so import maps and Stimulus can run. Stripe origins are appended only when the host already has a CSP.
- Dummy catalogue seeds the V1 commercial graph: distinct Italy/Germany euro plan prices, a trial on the annual plan, a metered API-call service (not a credit pack), an allowance feature, prepaid credit-pack grants, checkout presentations, an uncertain refund, and a reconciliation issue. Fake tax calculators are registered with tax left off.
- Customer checkout is one lifecycle for embedded, redirect, payment link, invoice, and no-charge presentations. Charge Market finalization can requote, restart, reject, or review; frozen Italy/Germany euro prices stay on the original quote until the customer starts again.
- Billable workspace roots enable RecordingStudio Accessible. Dummy seeds grant the seeded admin `edit` on Studio Workspace so `/billing` works without stubbing authorization. Customer billing copy uses plans, prices, invoices, and usage instead of identifiers, option keys, or Market labels.
- Customer plan changes are select → compare → confirm → result, with cancel/resume confirmation and an effective date. Payments and invoices show refunds and adjustments, including requests waiting for confirmation. The payment portal is restricted to payment methods, address, tax IDs, and invoice history.
- Completing checkout after a cancellation reactivates the same execution-group subscription. Dummy seeds apply the hybrid cancellation before the live monthly checkout so the Plan page has a current plan.
- Customer billing screens are gem-owned pages mounted in Recording Studio's default layout. The host sidebar renders `CustomerSidebarComponent`. Plan is title, subtitle, and pricing cards; plan-request history is its own page; cancel stays on Overview. Overview, Plan, Plan requests, Add-ons, Usage, Invoices, Payments, Settings, checkout, invoice, and cancel/resume confirmation use FlatPack page titles, cards, lists, badges, and buttons.
- Display market resolution accepts verified host-country evidence, so Plan cards show the customer market price (dummy US $0 / $49 / $490) instead of the global fallback.

## 0.1.2

- Initial engine checkout from the RecordingStudio gem template.
