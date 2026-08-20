> **Architecture Documentation**
> *   **Canonical Source:** [bowerbird-app/gem_template](https://github.com/bowerbird-app/gem_template/tree/main/docs/gem_template)
> *   **Last Updated:** May 5, 2026
>
> *Maintainers: Please update the date above when modifying this file.*

---

# GemTemplate Configuration

This document explains how to configure **GemTemplate** in your host Rails application.

---

## Quick Start

After installing the gem, run the install generator:

```bash
rails generate gem_template:install
```

This will:

1. Mount the engine in your routes (`/gem_template` by default).
2. Create `config/initializers/gem_template.rb` with example settings.
3. Optionally create `config/gem_template.yml` for environment-specific configuration.

---

## Configuration Options

| Option              | Type    | Default                          | Description                                 |
|---------------------|---------|----------------------------------|---------------------------------------------|
| `api_key`           | String  | `ENV["GEM_TEMPLATE_API_KEY"]`    | API key for external service integration.  |
| `enable_feature_x`  | Boolean | `false`                          | Toggle optional feature X.                 |
| `timeout`           | Integer | `5`                              | Timeout (seconds) for external calls.      |

### RecordingStudio v3 Host-App Declarations

The dummy host app pins RecordingStudio to `recording_studio/v3.0.0` and keeps strict recordable declarations enabled:

```ruby
RecordingStudio.configure do |config|
  config.recordable_types = ["Workspace", "Folder", "Page"]
  config.require_recordable_declarations = true
end

class Workspace < ApplicationRecord
  recording_studio_recordable label: "Workspace", root: true
end

class Folder < ApplicationRecord
  recording_studio_recordable label: "Folder", root: false, allowed_parent_types: ["Workspace", "Folder"]
end
```

Use `RecordingStudio.validate_recordable_declarations!`, `RecordingStudio.root_recordable_types`, and
`RecordingStudio.allowed_parent_types_for("Page")` to verify the host app wiring.

---

## Configuration Methods

### 1. Ruby Initializer (Recommended)

Edit `config/initializers/gem_template.rb`:

```ruby
GemTemplate.configure do |config|
  config.api_key          = ENV["GEM_TEMPLATE_API_KEY"]
  config.enable_feature_x = true
  config.timeout          = 10
end
```

This approach is flexible and allows dynamic values, environment variables, and Rails credentials.

### 2. YAML Configuration

If you prefer environment-specific static settings, create `config/gem_template.yml`:

```yaml
development:
  api_key: "dev-key"
  enable_feature_x: true
  timeout: 5

production:
  api_key: <%= ENV["GEM_TEMPLATE_API_KEY"] %>
  enable_feature_x: false
  timeout: 5
```

The engine loads this file automatically via `Rails.application.config_for(:gem_template)`.

### 3. `config.x` Namespace

You can also set values in `config/application.rb` or environment files:

```ruby
# config/environments/production.rb
config.x.gem_template.api_key = ENV["GEM_TEMPLATE_API_KEY"]
config.x.gem_template.timeout = 10
```

---

## Load Order & Precedence

Configuration is merged in the following order (later sources override earlier ones):

1. **Defaults** – defined in `GemTemplate::Configuration#initialize`.
2. **YAML** – `config/gem_template.yml` loaded via `config_for`.
3. **`config.x.gem_template`** – values set in Rails config files.
4. **Initializer** – `GemTemplate.configure` block in `config/initializers/gem_template.rb`.

> **Tip:** For most use cases, stick with the Ruby initializer and use environment variables for secrets.

---

## Accessing Configuration at Runtime

```ruby
GemTemplate.configuration.api_key
# => "your-api-key"

GemTemplate.configuration.enable_feature_x
# => true

GemTemplate.configuration.to_h
# => { api_key: "...", enable_feature_x: true, timeout: 5 }
```

You can access these values from anywhere in your application or from within the engine's controllers, models, and jobs.

---

## Secret Management

For sensitive values like `api_key`, we recommend:

- **Environment variables** – `ENV["GEM_TEMPLATE_API_KEY"]`
- **Rails credentials** – `Rails.application.credentials.gem_template[:api_key]`

Avoid committing secrets to version control. The generator templates use `ENV` by default to encourage this practice.

---

## Extending Configuration

To add new options:

1. Add `attr_accessor` in `lib/gem_template/configuration.rb`.
2. Set a sensible default in `#initialize`.
3. Update `#to_h` if you want the option included in hash export.
4. Document the new option in this file and in the initializer template.

---

## Troubleshooting

| Issue                                  | Solution                                                                 |
|----------------------------------------|--------------------------------------------------------------------------|
| YAML not loading                       | Ensure `config/gem_template.yml` exists and has valid YAML syntax.       |
| Initializer values not applied         | Make sure the initializer runs after the engine initializer (default).   |
| `config.x` values ignored              | Verify you're setting them in the correct environment file.             |

---

## Files Reference

| File                                                        | Purpose                                      |
|-------------------------------------------------------------|----------------------------------------------|
| `lib/gem_template/configuration.rb`                         | Configuration class with defaults.           |
| `lib/gem_template/engine.rb`                                | Engine initializer that loads host config.   |
| `lib/generators/gem_template/install/install_generator.rb`  | Install generator that creates config files. |
| `lib/generators/gem_template/install/templates/`            | Templates for initializer and YAML files.    |

---

Happy configuring!
