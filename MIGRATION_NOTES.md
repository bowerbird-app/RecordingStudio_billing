# Migration notes

RecordingStudio Billing is a **clean-install** engine. Hosts apply the current engine migrations once. There is no supported upgrade from earlier experimental schemas in this repository.

## What the install generator copies

`rails generate recording_studio_billing:install` copies:

- engine migrations from `db/migrate/`
- the install guide into `docs/recording_studio_billing/INSTALL.md`

The billing snapshot SQL lives at `db/schema/install_recording_studio_billing.sql` inside the gem. The copied `InstallRecordingStudioBilling` migration reads that file from `RecordingStudioBilling::Engine.root` at migrate time. Hosts do not need a second copy of the SQL file.

Webhook tables come from `recording_studio_webhooks`. Install that gem first, or at least apply its webhook migrations before billing if your host keeps a foreign key. This engine stores webhook event ids without a billing-side foreign key.

## After copying migrations

1. `bin/rails db:migrate`
2. Commit `db/structure.sql`
3. Restart the app

Do not edit copied engine migrations in the host. Schema changes belong in this gem, then a new engine migration for existing hosts plus an updated install snapshot for new hosts.

## Dummy app

`test/dummy` uses the same install migration. Reset it with `bin/rails db:drop db:create db:migrate` from `test/dummy`, then commit `test/dummy/db/structure.sql`.

The dummy host uses FlatPack. Signed-in dummy pages use the gem-template left sidebar layout. Billing engine pages use `app/views/layouts/recording_studio/default_layout.html.erb`. Dummy seeds rebuild the V1 demonstration catalogue and grant the seeded admin Accessible `edit` on Studio Workspace; reset the dummy database if published records were created by an older seed.