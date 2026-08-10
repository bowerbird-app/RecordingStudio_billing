> **Architecture Documentation**
> *   **Canonical Source:** [bowerbird-app/gem_template](https://github.com/bowerbird-app/gem_template/tree/main/docs/gem_template)
> *   **Last Updated:** May 5, 2026
>
> *Maintainers: Please update the date above when modifying this file.*

---

> **📌 Note:** This documentation directory (`docs/gem_template/`) is preserved during gem renaming and serves as architectural reference material. When you rename your gem, these files intentionally remain under `gem_template` to document the original template structure.

---

# GemTemplate

A template for building **Rails mountable engine gems** with PostgreSQL UUID primary keys, TailwindCSS, and GitHub Codespaces integration.

---

## ✅ What's Working

- ✓ Rails Engine mounted and operational
- ✓ PostgreSQL with UUID primary keys
- ✓ TailwindCSS styling (auto-rebuilds in development)
- ✓ Codespaces environment automatically sets up on build
- ✓ Install generator for host applications
- ✓ Migrations generator for database setup
- ✓ Service object pattern with Result monad
- ✓ Dummy app sidebar with starter documentation pages and a minimal demo home page

---

## 🚀 Quick Start

### GitHub Codespaces (Recommended)

1. Click **Code** → **Codespaces** → **Create codespace**
2. Wait for setup to complete (~3-5 minutes)
3. Run:
   ```bash
   cd test/dummy
   bin/rails db:setup
   bin/dev
   ```
4. Open port 3000 and visit `/`

→ [Codespaces Setup Guide](CODESPACES.md)

### Local Development

1. Clone and install dependencies
2. Setup database and build Tailwind
3. Run `bin/dev`

→ [Local Development Guide](LOCAL_DEVELOPMENT.md)

## Dummy App Guidance

The dummy app includes a starter authenticated sidebar in `test/dummy/app/views/layouts/flat_pack/_sidebar.html.erb` with linked pages for install, config, recordable types, recordings tree, gem views, and methods. Those pages are intentionally scaffolded examples with a consistent FlatPack style; update their labels, routes, and content so they fit the gem you are building.

The home page in `test/dummy/app/views/home/index.html.erb` is the corresponding starting point for a very minimal demo of the gem's primary behavior. Keep it narrowly focused and use the sidebar pages for the broader explanation of concepts, setup, and API surface.

For current UI work, prefer the top-level README plus the live FlatPack demo app at `https://flatpack-c6p8f.ondigitalocean.app/`. Its component table is the quickest way to discover shared components, user-provided FlatPack demo URLs should be treated as task context, and if the demo is blocked in Codespaces or another restricted environment, ask for access or request sanitized screenshots, copied markup, or component details instead of guessing.

---

## 📚 Documentation

| Guide | Description |
|-------|-------------|
| [Renaming](RENAMING.md) | Instructions for renaming this template gem to your own name. |
| [Installation](INSTALLING.md) | Step-by-step guide for installing this engine in a host Rails application. |
| [Configuration](CONFIGURATION.md) | Details on configuring the gem via initializers and environment variables. |
| [Private Gems](PRIVATE_GEMS.md) | How to authenticate and access private gem dependencies in Codespaces, local, and production environments. |
| [Database Migrations](MIGRATIONS.md) | How to generate and manage database migrations for the engine. |
| [Service Objects](SERVICES.md) | Explanation of the Service Object pattern and Result monad used for business logic. |
| [Engine Hooks](HOOKS.md) | Guide to customizing engine behavior using lifecycle and service hooks. |
| [Asset Architecture](CSS_JS_ASSETS_ARCHITECTURE.md) | Details on TailwindCSS setup and asset pipeline integration. |
| [Security](SECURITY.md) | Security considerations. |
| [Changelog](../../CHANGELOG.md) | Version history. |

---

## 📁 Project Structure

```
gem_template/
├── app/
│   ├── controllers/gem_template/
│   └── views/gem_template/
├── config/routes.rb
├── db/migrate/              # Engine migrations
├── lib/
│   ├── gem_template.rb
│   ├── gem_template/
│   │   ├── configuration.rb
│   │   ├── engine.rb
│   │   ├── version.rb
│   │   └── services/        # Service objects
│   │       ├── base_service.rb
│   │       └── example_service.rb
│   └── generators/
├── test/dummy/              # Test Rails app
├── docs/                    # Documentation
└── gem_template.gemspec
```

---

## 📋 Tech Stack

| Component | Version |
|-----------|---------|
| Ruby | 3.3 |
| Rails | 8.1 |
| PostgreSQL | 16 |
| Redis | 7 |
| TailwindCSS | 4 |

---

## 📄 License

MIT – see [MIT-LICENSE](../../MIT-LICENSE)

---

**Happy coding!**
