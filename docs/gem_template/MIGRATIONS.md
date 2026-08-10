> **Architecture Documentation**
> *   **Canonical Source:** [bowerbird-app/gem_template](https://github.com/bowerbird-app/gem_template/tree/main/docs/gem_template)
> *   **Last Updated:** May 5, 2026
>
> *Maintainers: Please update the date above when modifying this file.*

---

# Migrations

This guide explains how to work with database migrations in GemTemplate.

---

## Installing Migrations in a Host App

GemTemplate includes a migrations generator that copies engine migrations to your host application with proper timestamps.

### Run the Generator

```bash
rails generate gem_template:migrations
```

This will:
1. Find all migrations in the engine's `db/migrate/` directory
2. Copy them to your app's `db/migrate/` with new timestamps
3. Skip any migrations that already exist (based on migration name)

### Apply the Migrations

```bash
bin/rails db:migrate
```

---

## Generator Options

| Option | Default | Description |
|--------|---------|-------------|
| `--skip-existing` | `true` | Skip migrations that already exist in the host app |
| `--pretend` | `false` | Show what would be copied without making changes |
| `--force` | `false` | Overwrite existing migrations |

### Preview Mode

To see what migrations would be installed without making changes:

```bash
rails generate gem_template:migrations --pretend
```

### Force Reinstall

To overwrite existing migrations (useful for updates):

```bash
rails generate gem_template:migrations --no-skip-existing --force
```

---

## Adding Migrations to the Engine

When developing the engine, add migrations to `db/migrate/`:

```bash
# From the gem root
touch db/migrate/$(date +%Y%m%d%H%M%S)_create_gem_template_pages.rb
```

### Migration Conventions

1. **Use UUID primary keys** for PostgreSQL compatibility:

   ```ruby
    class CreateGemTemplatePages < ActiveRecord::Migration[8.1]
     def change
          create_table :gem_template_pages, id: :uuid do |t|
             t.uuid :workspace_id, null: false
             t.string :title, null: false
             t.string :slug, null: false
             t.jsonb :content, default: {}, null: false
         t.timestamps
       end

          add_index :gem_template_pages, [:workspace_id, :slug], unique: true
     end
   end
   ```

2. **Prefix table names** with the gem name to avoid conflicts:

   ```ruby
   # Good: gem_template_pages
   # Bad: pages
   ```

3. **Use `jsonb` for flexible data** (PostgreSQL):

   ```ruby
   t.jsonb :metadata, default: {}
   ```

4. **Add indexes** for frequently queried columns:

   ```ruby
   add_index :gem_template_pages, :workspace_id
   add_index :gem_template_pages, :published
   ```

---

## Engine Migration Structure

```
db/
└── migrate/
   └── 20250101000001_create_gem_template_pages.rb
```

Migrations are included in the gem via the gemspec:

```ruby
spec.files = Dir["{app,config,db,lib}/**/*", ...]
```

---

## Updating Migrations

When you release a new version with additional migrations:

1. Host app developers run the generator again:
   ```bash
   rails generate gem_template:migrations
   ```

2. Only new migrations are copied (existing ones are skipped)

3. Apply the new migrations:
   ```bash
   bin/rails db:migrate
   ```

---

## Rollback Considerations

If a host app needs to rollback engine migrations:

```bash
# Rollback specific migration
bin/rails db:migrate:down VERSION=20250101000001

# Or rollback all engine tables manually
bin/rails db:rollback STEP=N
```

---

## Testing Migrations

The dummy app (`test/dummy/`) is used to test migrations during development:

```bash
cd test/dummy
bin/rails db:migrate
bin/rails db:rollback
```

---

## After Renaming the Gem

When you rename the gem using `bin/rename_gem`, the migration files are automatically updated:

- Class names change (e.g., `CreateGemTemplatePages` → `CreateMyEnginePages`)
- Table names change (e.g., `gem_template_pages` → `my_engine_pages`)

---

## Related Guides

- [Installing](INSTALLING.md) — Full installation guide
- [Configuration](CONFIGURATION.md) — Engine configuration options
- [Local Development](LOCAL_DEVELOPMENT.md) — Development setup
