# Migration Notes - Private Gems to Public Gems

## Completed Changes

1. Removed repository access entries from `.devcontainer/devcontainer.json`.
2. Updated `docs/gem_template/CODESPACES.md` and `docs/gem_template/PRIVATE_GEMS.md` for public dependencies.
3. Replaced MakeupArtist with FlatPack in the dummy app dependency, views, layouts, and Tailwind sources.
4. Pinned the dummy app to FlatPack `v0.1.129` in `test/dummy/Gemfile` and its lockfile.
5. Regenerated the dummy app bundle and completed the FlatPack installation work.

## Current Requirements

- Ruby 3.3 or newer
- Rails 8.1 or newer
- Public RubyGems and GitHub access for dependency installation
- No private gem credentials for the template dependencies

## Pre-release Migration Policy

This pre-release gem uses a clean-install-only migration policy. Webhook effect
and reconciliation receipt scoping is defined in their owning create
migrations, including the final PostgreSQL uniqueness constraints. The dated
receipt-scoping migrations remain inert for migration ordering, but are not an
upgrade path for databases created from intermediate development snapshots.
There is deliberately no nullable-column backfill, synthetic receipt identity,
or destructive reconciliation cleanup.

## Verification

Install both bundles and run the complete gem and dummy app test path:

```bash
bundle install
BUNDLE_GEMFILE=test/dummy/Gemfile bundle install
bundle exec rake test:all
```

The root `bundle exec rake test` command prepares the isolated dummy-app test
database before running the engine suite. `bundle exec rake test:all` also
rebuilds the dummy app test database, runs its migrations and idempotent seeds,
and executes dummy integration coverage. The dummy application uses PostgreSQL
with UUID primary keys and a credential-free fake provider; these examples do
not require Stripe credentials or a provider network connection.

Run the dummy app from its directory for browser verification:

```bash
cd test/dummy
bin/dev
```

Use the [FlatPack repository](https://github.com/bowerbird-app/flatpack) and the live FlatPack demo linked from the top-level README for current component documentation.
