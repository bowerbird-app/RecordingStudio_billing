> **Architecture Documentation**
> *   **Canonical Source:** [bowerbird-app/gem_template](https://github.com/bowerbird-app/gem_template/tree/main/docs/gem_template)
> *   **Last Updated:** May 5, 2026
>
> *Maintainers: Please update the date above when modifying this file.*

---

# GitHub Codespaces Setup

This document covers how the devcontainer is configured and how to work in GitHub Codespaces.

---

## Quick Start

1. **Create a Codespace** on this repository (click the green "Code" button → "Codespaces" → "Create codespace on main").
2. **Wait** for the container to build and the `postCreateCommand` to complete (3-5 minutes).
3. **Start the development server**:
   ```bash
   cd test/dummy
   bin/dev
   ```
4. **Open the app** – click the forwarded port 3000 in the "Ports" tab.
5. **Start from the dummy app home page** at `/` and use `/users/sign_in` or `/docs/install` as needed.

---

## What Runs Automatically

The `postCreateCommand` in `.devcontainer/devcontainer.json` executes:

```bash
git lfs install && \
bundle config set --local path '/usr/local/bundle' && \
bundle install && \
cd test/dummy && \
bundle exec rails db:prepare && \
bundle exec rails tailwindcss:build
```

This:
- Installs Git LFS (if needed)
- Installs gem dependencies
- Prepares the PostgreSQL database (creates, migrates, seeds)
- Builds TailwindCSS assets

---

## Docker Compose Services

The devcontainer uses Docker Compose with three services defined in `.devcontainer/docker-compose.yml`:

| Service | Image | Port | Notes |
|---------|-------|------|-------|
| **db** | `postgres:16` | 5432 | UUID support via `pgcrypto`; volume `pgdata` |
| **redis** | `redis:7-alpine` | 6379 | Volume `redis_data` |
| **app** | Built from `.devcontainer/Dockerfile` | 3000 | Ruby 3.3 slim; mounts `/workspace` |

Health checks ensure dependent services are ready before Rails boots.

---

## Environment Variables

Set automatically inside the container:

| Variable | Value |
|----------|-------|
| `DB_HOST` | `db` |
| `DB_PORT` | `5432` |
| `DB_USER` | `postgres` |
| `DB_PASSWORD` | `postgres` |
| `REDIS_URL` | `redis://redis:6379/0` |
| `CODESPACES` | `true` |

---

## Private Gem Access (Deprecated)

**⚠️ As of February 2025, this gem template no longer uses private gems.**

All dependencies are now public and available on RubyGems.org or public GitHub repositories. No authentication tokens or special configuration is required.

For historical reference: Previously, this template used private gems that required authentication via Codespaces secrets. This is no longer necessary.

---

## CSRF Protection

When `ENV["CODESPACES"] == "true"`:
- CSRF **origin check is relaxed** (avoids issues with GitHub's forwarded URLs).
- CSRF **authenticity tokens remain enabled** for security.

For best results, access your app consistently via:
- The Codespaces forwarded URL (`*.app.github.dev`), **or**
- `localhost:3000` (if port forwarding is set to local).

See [SECURITY.md](../SECURITY.md) for details.

---

## Running the Server

Use `bin/dev` to start both Rails and the Tailwind watcher:

```bash
cd test/dummy
bin/dev
```

This runs Foreman with `Procfile.dev`:

```
web: bin/rails server -b 0.0.0.0
css: bin/rails tailwindcss:watch
```

Binding to `0.0.0.0` is required for Codespaces port forwarding.

---

## Port Forwarding

Codespaces automatically forwards port 3000. Find it in the **Ports** tab and click the globe icon to open in your browser.

If port 3000 is busy:

```bash
PORT=3001 bin/dev
```

---

## Rebuilding the Container

If you change `.devcontainer/` files:

1. Open the Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`).
2. Run **Codespaces: Rebuild Container**.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Container fails to start | Check Docker Compose logs in the terminal. |
| Database connection refused | Ensure `db` service is healthy (`docker ps`). |
| Tailwind not rebuilding | Restart `bin/dev` or run `bin/rails tailwindcss:build`. |
| Port already in use | Use a different port: `PORT=3001 bin/dev`. |

---

## Files Reference

| File | Purpose |
|------|---------|
| `.devcontainer/devcontainer.json` | Codespaces/VS Code configuration |
| `.devcontainer/docker-compose.yml` | Service definitions |
| `.devcontainer/Dockerfile` | Ruby container build |
| `test/dummy/Procfile.dev` | Foreman process definitions |
| `test/dummy/bin/dev` | Development startup script |

---

Happy coding in Codespaces! ☁️
