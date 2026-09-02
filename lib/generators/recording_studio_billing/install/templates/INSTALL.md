RecordingStudioBilling install complete.

Next steps:

1. Stripe is registered as the default provider. Configure its host-managed credential resolver before real Stripe operations; the engine never accepts raw card data.
2. If you use environment-specific settings, create config/recording_studio_billing.yml.
3. Install the engine migrations with `bin/rails generate recording_studio_billing:migrations`.
4. Apply the migrations with `bin/rails db:migrate`.
5. Commit `db/structure.sql`. The installer selects SQL schema format because `schema.rb` cannot preserve the PostgreSQL functions and triggers that protect billing history.
6. Run `bin/rails tailwindcss:build` if you use Tailwind CSS. Customer billing uses Recording Studio's `recording_studio/default_layout` only. Include `RecordingStudio::UsesDefaultLayout` on authenticated host controllers. Do not add a second sidebar shell.
7. Mount routes are added at the configured mount path, plus a host plans route via `draw_recording_studio_billing_plans` (default `/plans`). Include `RecordingStudioBilling::Billable` in each workspace-like root. That enables `:billing` and `:accessible`. Configure `access_actor_types`, install RecordingStudio Accessible migrations, then grant customer billing with `bootstrap_owner_access!` for the first owner and `grant_access` after that (`view` to read, `edit` to checkout or change a plan). Set `billing_portal_context_resolver` when customers should open a payment portal. That portal is limited to payment methods, address, tax IDs, and invoice history.
8. For an admin root, include `RecordingStudioBilling::BillingAdminSupport` and enable `:accessible` on that root. Add the billing shortcut before the Admin mount:

   ```ruby
   draw_recording_studio_billing_admin
   recording_studio_admin_for :admin, at: "/admin", root_section: :billing
   ```

   Staff land on the Billing hub. `/admin/billing` redirects to `/admin/sections/billing`. The Products, Plans, and Add-ons buttons open their inventory screens.
9. Keep strict RecordingStudio declarations enabled and add `recording_studio_recordable(...)` to every configured recordable before running `RecordingStudio.validate_recordable_declarations!`.