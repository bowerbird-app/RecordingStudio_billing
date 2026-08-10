> **Architecture Documentation**
> *   **Canonical Source:** [bowerbird-app/gem_template](https://github.com/bowerbird-app/gem_template/tree/main/docs/gem_template)
> *   **Last Updated:** May 5, 2026
>
> *Maintainers: Please update the date above when modifying this file.*

---

# Gem Rename Script

A utility script to rename the gem throughout the codebase.

## Usage

```bash
bin/rename_gem <new_name> [options]
```

### Basic Examples

```bash
# Rename using auto-detected current name
bin/rename_gem my_awesome_gem

# Names with spaces are automatically converted to snake_case
bin/rename_gem "my awesome gem"  # becomes my_awesome_gem

# Preview changes without applying them
bin/rename_gem my_awesome_gem --dry-run

# Override the detected current name
bin/rename_gem my_awesome_gem --from old_gem_name
```

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview all changes without modifying any files |
| `--from NAME` | Specify the current gem name (overrides auto-detection) |

## What Gets Renamed

The script updates all gem-related files and references:

### Files Renamed
- `<gem_name>.gemspec` → `<new_name>.gemspec`
- `lib/<gem_name>.rb` → `lib/<new_name>.rb`
- `test/<gem_name>_test.rb` → `test/<new_name>_test.rb`

### Directories Renamed
- `lib/<gem_name>/` → `lib/<new_name>/`
- `app/controllers/<gem_name>/` → `app/controllers/<new_name>/`
- `app/views/<gem_name>/` → `app/views/<new_name>/`
- `lib/generators/<gem_name>/` → `lib/generators/<new_name>/`

### Content Updated
The script performs two types of replacements in all relevant files:
- **snake_case**: `gem_template` → `new_gem_name`
- **PascalCase**: `GemTemplate` → `NewGemName`

Files updated include:
- `.gemspec`, `.rb`, `.erb`, `.md` files
- `Gemfile`, `Rakefile`, `routes.rb`
- Documentation files (`README.md`, `CHANGELOG.md`, etc.)
- Test files and test helper
- Dummy app configuration (`test/dummy/Gemfile`, `test/dummy/config/routes.rb`)

## What Does NOT Get Renamed

The following directories and files are intentionally **excluded** from renaming:

### Excluded Documentation
- `docs/gem_template/` - **Preserved as architectural reference**
  - These files document the original gem_template structure
  - They serve as reference documentation for understanding the template's architecture
  - Keep them unchanged even after renaming your gem

This ensures you maintain documentation showing:
- How the template was originally structured
- What patterns and conventions come from the gem_template
- Reference material for future gems built from this template

## Verification

After renaming, the script automatically runs verification tests to ensure:
- All files were renamed correctly
- No orphaned references to the old name remain
- Module names and class definitions are consistent

## Resume Capability

The script includes automatic resume capability for handling interruptions:

### How It Works

The script operates in phases:
1. **Content Update**: Replace all text references to the old gem name
2. **Validation**: Verify no old references remain
3. **File Renaming**: Rename individual files
4. **Directory Renaming**: Rename directory structures

If the script is interrupted (e.g., validation fails, power loss, manual cancellation), it saves its progress to `.rename_state.yml` and can resume from where it left off.

### Recovery from Interruptions

If the rename is interrupted and you see errors:

**Scenario 1: Validation fails after content update**
```
❌ Found remaining references to old_name in: some_file.rb

ℹ️  Note: File contents have been updated but files/directories have NOT been renamed yet.
```

To recover:
1. Fix the reported issues (or add files to `EXCLUDED_FILES` in `bin/rename_gem`)
2. Re-run the same command - it will resume automatically
3. The script skips content updates (already done) and continues with renaming

**Scenario 2: Conflicting rename detected**
```
⚠️  Warning: Found incomplete rename from previous run
   Previous: old_gem → new_gem
   Current:  old_gem → different_gem
```

The script detects if you're trying a different rename. Choose:
- `y` to delete the old state and start fresh
- `n` to abort and manually clean up

**Scenario 3: Manual cleanup needed**
```bash
# Delete the state file and start over
rm .rename_state.yml
git restore .
```

### State File

- File: `.rename_state.yml` (automatically created/deleted)
- Ignored by git (in `.gitignore`)
- Removed automatically on successful completion
- Contains: phase, old name, new name, any error messages

## Workflow

1. **Preview the changes** (recommended):
   ```bash
   bin/rename_gem my_new_name --dry-run
   ```

2. **Run the rename**:
   ```bash
   bin/rename_gem my_new_name
   ```

3. **Review changes**:
   ```bash
   git diff
   ```

4. **Run tests**:
   ```bash
   bundle exec rake test
   ```

5. **Commit**:
   ```bash
   git add -A && git commit -m "Rename gem to my_new_name"
   ```

## Notes

- The script will warn you if there are uncommitted git changes
- Auto-detection reads the gem name from the `.gemspec` file
- The verification tests are excluded from content replacement to preserve their reference strings
- Before publishing, verify your new gem name is available on [RubyGems.org](https://rubygems.org)
