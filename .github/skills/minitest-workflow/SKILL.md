---
name: minitest-workflow
description: 'Use when adding or reviewing Minitest coverage, regression tests, generator tests, or Rails engine validation. Covers root suite expectations, dummy app verification, and coverage-minded test design for this repository.'
user-invocable: false
---

# Minitest Workflow

## When To Use

- Adding or updating Minitest coverage
- Writing regression tests for generators, hooks, services, or engine wiring
- Verifying changes that affect the dummy app or Recording Studio integration
- Reviewing whether validation coverage is adequate before merge

## Procedure

1. Identify the narrowest tests that can falsify the change first.
2. Add focused happy-path, failure-path, and edge-case coverage for the touched behavior.
3. Prefer unit tests for POROs and services, and minimal integration tests for engine wiring and generator behavior.
4. Preserve public behavior; do not bypass production code to make tests pass.
5. Run `bundle exec rake test` from the repository root.
6. If the change affects dummy app boot, assets, or migrations, also validate the dummy app setup used in CI.

## Repository Expectations

- Cover configuration defaults and overrides.
- Cover hook ordering, arguments, and error isolation.
- Add regression coverage for rename and generator flows.
- Keep tests fast, deterministic, and scoped to the change.