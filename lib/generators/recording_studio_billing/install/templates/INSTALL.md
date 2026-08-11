RecordingStudioBilling install complete.

Next steps:

1. Stripe is registered as the default provider. Configure its host-managed credential resolver before real Stripe operations; the engine never accepts raw card data.
2. If you use environment-specific settings, create config/recording_studio_billing.yml.
3. Install the engine migrations with `bin/rails generate recording_studio_billing:migrations`.
4. Apply the migrations with `bin/rails db:migrate`.
5. Commit `db/structure.sql`. The installer selects SQL schema format because `schema.rb` cannot preserve the PostgreSQL functions and triggers that protect billing history.
6. Run `bin/rails tailwindcss:build` if you use Tailwind CSS.
7. Mount routes are added at the configured mount path. Include `RecordingStudioBilling::Billable` in each workspace-like root.
8. For an admin root, include `RecordingStudioBilling::BillingAdminSupport`; it uses `RecordingStudioAdmin::AllowsAdminSections` to register `:billing`.
9. Keep strict RecordingStudio declarations enabled and add `recording_studio_recordable(...)` to every configured recordable before running `RecordingStudio.validate_recordable_declarations!`.