# GemTemplate

Internal template for building Rails engine addons on top of RecordingStudio.

## What's Included

- **RecordingStudio** gem installed and configured
- **Devise** authentication with a pre-seeded admin user
- **Workspace**, **Folder**, and **Page** recordables seeded into the dummy host app
- **FlatPack** UI component library for all views
- **Dummy app** (`test/dummy/`) with a FlatPack-based sign-in screen, a simple home page, mounted RecordingStudio routes, and FlatPack's built-in rounded theme enabled by default

The dummy app ships with a starter sidebar documentation shell for authenticated pages. The menu entries in `test/dummy/app/views/layouts/flat_pack/_sidebar.html.erb` and the linked docs pages are intended to be rewritten to suit the addon you are building; the template provides the structure and styling, not final product copy. By default, that starter shell uses FlatPack's built-in rounded theme via the root layout attribute rather than custom Tailwind theme recreation.

## Quick Start

### GitHub Codespaces (Recommended)

1. Click **Code** → **Codespaces** → **Create codespace**
2. Wait for setup to complete
3. Run:
   ```bash
   cd test/dummy
   bin/rails db:setup
   bin/dev
   ```
4. Open port 3000 — you'll land on the dummy app home page and can sign in at `/users/sign_in`

The dummy app is intended as a host-app validation surface for authentication, FlatPack rendering, Tailwind source scanning, and RecordingStudio route wiring.

### Login Credentials

| Field    | Value             |
|----------|-------------------|
| Email    | admin@admin.com   |
| Password | Password          |

The login form is prefilled with these credentials for fast access.

### Useful Routes

- `/` — dummy app home page
- `/users/sign_in` — Devise sign-in page
- `/recording_studio` — redirect to `/` while the mounted RecordingStudio engine remains data/API-focused
- `/docs/install` — install guide rendered inside the dummy app
- `/docs/config`, `/docs/recordable_types`, `/docs/recordings_tree`, `/docs/gem_views`, `/docs/methods` — starter sidebar pages to customize for your gem

The home page in `test/dummy/app/views/home/index.html.erb` is also a deliberate starting point. Keep it focused on a minimal demo of the gem's primary behavior; use the sidebar pages for deeper explanations and supporting reference material.

## Architecture

### Root Recording Pattern

This template follows RecordingStudio's root recording pattern:

- **Workspace** is the top-level recordable
- **Folder** and **Page** demonstrate nested recordables under the workspace root
- Each configured recordable declares `recording_studio_recordable(...)`; strict declaration validation stays enabled
- A root `RecordingStudio::Recording` wraps the Workspace
- `Current.actor` is set from `current_user` (Devise) in `ApplicationController`

### Extending RecordingStudio

To add new recordable types:

1. Create your model (e.g., `Page`, `Comment`)
2. Register it in `config/initializers/recording_studio.rb`:
   ```ruby
   RecordingStudio.configure do |config|
     config.recordable_types = ["Workspace", "YourNewType"]
   end
   ```
3. Declare whether the model can be a root and which parents may contain it:
   ```ruby
   class YourNewType < ApplicationRecord
     recording_studio_recordable label: "Your new type",
                                 root: false,
                                 allowed_parent_types: ["Workspace", "Folder"]
   end
   ```
4. Validate declarations and create recordings under the root:
   ```ruby
   RecordingStudio.validate_recordable_declarations!
   root_recording = RecordingStudio.root_recording_for(workspace)
   root_recording.record(YourNewType) do |record|
     record.title = "Example"
   end
   ```

### RecordingStudio v3 Declarations

RecordingStudio v3 expects every configured ActiveRecord recordable type to declare its hierarchy rules:

- `Workspace` declares `root: true`
- `Folder` and `Page` declare `root: false, allowed_parent_types: ["Workspace", "Folder"]`
- `config.require_recordable_declarations = true` remains enabled in the dummy app initializer

Useful console checks:

```ruby
RecordingStudio.validate_recordable_declarations!
RecordingStudio.root_recordable_types
RecordingStudio.allowed_parent_types_for("Page")
```

### FlatPack UI Components

All views use FlatPack ViewComponents. Available components include:

- `FlatPack::Button::Component` — Buttons (`:primary`, `:secondary`, `:ghost`)
- `FlatPack::Card::Component` — Cards (`:default`, `:elevated`, `:outlined`)
- `FlatPack::Alert::Component` — Alerts (`:success`, `:error`, `:warning`, `:info`)
- `FlatPack::Badge::Component` — Status badges
- `FlatPack::Table::Component` — Data tables
- `FlatPack::TextInput::Component`, `EmailInput`, `PasswordInput` — Form inputs
- `FlatPack::Breadcrumb::Component` — Navigation breadcrumbs
- `FlatPack::Navbar::Component` — Navigation sidebar

Use the live FlatPack demo app at [flatpack-c6p8f.ondigitalocean.app](https://flatpack-c6p8f.ondigitalocean.app/) as the approved UI reference for current shared patterns. Its component table is the fastest way to discover available FlatPack components before introducing new custom UI, and user-provided FlatPack demo URLs should be treated as task context.

In GitHub Codespaces or other restricted environments, you may need to enable access to that URL before the agent can inspect the app. If access is unavailable, provide sanitized screenshots, copied markup, or component details so the agent can stay aligned with the shared UI.

See the [FlatPack README](https://github.com/bowerbird-app/flatpack) for full documentation.

## Tech Stack

| Component       | Version |
|-----------------|---------|
| Ruby            | 3.3+    |
| Rails           | 8.1+    |
| PostgreSQL      | 16      |
| TailwindCSS     | 4       |
| RecordingStudio | v3.0.0 (pinned to `recording_studio/v3.0.0` in `test/dummy/Gemfile`) |
| FlatPack        | v0.1.129 (pinned in `test/dummy/Gemfile`) |
| Devise          | latest  |

## Documentation

The original gem template documentation is preserved in `docs/gem_template/` as architectural reference material. Use it as background on the engine conventions; the README and dummy app are the source of truth for the Recording Studio addon workflow.
