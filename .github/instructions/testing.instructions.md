---
description: "Use when writing or updating Minitest coverage, regression tests, generator tests, or validation steps for this Rails engine template."
applyTo: "test/**/*.rb"
---

# Testing Guidelines

- Use Minitest for engine and template coverage.
- Prefer focused regression tests for hooks, generators, Recording Studio integration points, and template UX guidance.
- Run `bundle exec rake test` from the repository root for standard validation.
- If a change affects dummy app boot, assets, or migrations, also validate the dummy app path the same way CI does.
- Keep tests deterministic and fix production code rather than weakening assertions to make tests pass.