# Dummy App

This Rails app validates the Recording Studio Billing foundation in a real host application.

## What It Covers

- Devise authentication with a seeded admin user
- `Current.actor` wiring for Recording Studio events
- One Workspace billing root, one AdminRoot billing-admin root, and their capability-owned child recordables
- FlatPack layout integration and Tailwind source scanning
- Mounted `RecordingStudio::Engine` route behavior inside a host app

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

- `/` - dummy app home page and billing foundation overview
- `/recording_studio` - redirects to `/` while the mounted Recording Studio engine stays available under that prefix for non-root routes
- `/users/sign_in` - Devise sign-in page
- `/up` - Rails health check

## Why This App Exists

Use this app to verify the provider-agnostic foundation before adding commercial billing behavior. If a layout, route, asset source, or Recording Studio initializer change breaks here, fix the integration before adding provider adapters.

The authenticated layout in `app/views/layouts/flat_pack_sidebar.html.erb` and its minimal sidebar preserve the FlatPack host-app validation surface. Keep the home page focused on the billing foundation rather than adding commercial billing screens before their provider-neutral design is ready.
