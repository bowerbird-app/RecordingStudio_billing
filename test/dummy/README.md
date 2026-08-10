# Dummy App

This Rails app exists to validate the Recording Studio addon template in a real host application.

## What It Covers

- Devise authentication with a seeded admin user
- `Current.actor` wiring for Recording Studio events
- Root workspace plus seeded folder and page recordables
- FlatPack layout integration and Tailwind source scanning
- Mounted `RecordingStudio::Engine` route behavior inside a host app
- A starter sidebar menu and companion docs pages for gem-specific onboarding

## Quick Start

```bash
cd test/dummy
bundle install
bin/rails db:setup
bin/dev
```

Run the commands above from the dummy app directory, not the repository root.

Then open the app and sign in with:

- Email: `admin@admin.com`
- Password: `Password`

## Useful Routes

- `/` - dummy app home page and template guidance
- `/recording_studio` - redirects to `/` while the mounted Recording Studio engine stays available under that prefix for non-root routes
- `/users/sign_in` - Devise sign-in page
- `/docs/install`, `/docs/config`, `/docs/recordable_types`, `/docs/recordings_tree`, `/docs/gem_views`, `/docs/methods` - starter sidebar pages to adapt for the gem
- `/up` - Rails health check

## Why This App Exists

Use this app to verify the generated addon experience before renaming the gem or copying patterns into another host app. If a layout, route, asset source, or Recording Studio initializer change breaks here, the template likely needs adjustment before reuse.

The authenticated layout in `app/views/layouts/flat_pack_sidebar.html.erb` and sidebar menu in `app/views/layouts/flat_pack/_sidebar.html.erb` are a styled skeleton, not the final information architecture for every addon. Replace the sidebar items and docs page content so they match the gem's actual concepts and workflows.

Likewise, the home page in `app/views/home/index.html.erb` should stay a minimal demo surface for the gem's core feature. Do not turn it into a wall of documentation; the dedicated sidebar pages exist so deeper explanations can live in focused sections.
