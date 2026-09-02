#!/usr/bin/env bash
# Cloud Agent install hook for Recording Studio Billing.
#
# Runs at Build time on Cursor's default image (no snapshot) to provision a
# complete development environment: Ruby, PostgreSQL 16, gem dependencies, the
# dummy host app database, and compiled CSS. It is idempotent so it can safely
# run again against a warm or partially prepared machine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

RUBY_VERSION="$(tr -d '[:space:]' < "${ROOT}/.ruby-version")"
PREFIX=/usr/local

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. System packages (build toolchain + PostgreSQL 16 + client libraries)
# ---------------------------------------------------------------------------
log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  build-essential git git-lfs curl ca-certificates \
  libpq-dev postgresql-client libyaml-dev pkg-config \
  libssl-dev zlib1g-dev libffi-dev libreadline-dev libgmp-dev \
  autoconf bison postgresql postgresql-contrib

# ---------------------------------------------------------------------------
# 2. Ruby (pinned by .ruby-version) via ruby-build, installed system-wide
# ---------------------------------------------------------------------------
if command -v ruby >/dev/null 2>&1 && [ "$(ruby -e 'print RUBY_VERSION')" = "${RUBY_VERSION}" ]; then
  log "Ruby ${RUBY_VERSION} already present"
else
  log "Installing Ruby ${RUBY_VERSION}"
  if ! command -v ruby-build >/dev/null 2>&1; then
    rm -rf /tmp/ruby-build
    git clone --depth 1 https://github.com/rbenv/ruby-build.git /tmp/ruby-build
    sudo PREFIX="${PREFIX}" /tmp/ruby-build/install.sh
  fi
  sudo ruby-build "${RUBY_VERSION}" "${PREFIX}"
fi

# Let the agent user manage gems in the system Ruby without sudo.
sudo chown -R "$(id -u):$(id -g)" \
  "${PREFIX}/lib/ruby" "${PREFIX}/bin" "${PREFIX}/include/ruby-${RUBY_VERSION%.*}.0" 2>/dev/null || true

command -v bundle >/dev/null 2>&1 || gem install bundler

# ---------------------------------------------------------------------------
# 3. PostgreSQL cluster: start and ensure the dev role/password exist
# ---------------------------------------------------------------------------
log "Starting PostgreSQL"
sudo pg_ctlcluster 16 main start 2>/dev/null || true
for _ in $(seq 1 30); do
  pg_isready -h localhost -U postgres >/dev/null 2>&1 && break
  sleep 1
done
# database.yml defaults to the postgres/postgres credentials over TCP.
sudo -u postgres psql -tAc "ALTER USER postgres PASSWORD 'postgres';" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 4. Gem dependencies (gem itself + dummy host app)
# ---------------------------------------------------------------------------
log "Installing gem dependencies"
bundle install
( cd test/dummy && bundle install )

# ---------------------------------------------------------------------------
# 5. Database + assets for the dummy host app
# ---------------------------------------------------------------------------
log "Preparing dummy app database and assets"
( cd test/dummy && bundle exec rails db:prepare )
( cd test/dummy && bundle exec rails tailwindcss:build )

# ---------------------------------------------------------------------------
# 6. Fetch Recording Studio Cursor skills and plugin rules (best-effort)
# ---------------------------------------------------------------------------
log "Fetching Recording Studio skills and plugin rules"
"${SCRIPT_DIR}/fetch-skills.sh" || true

log "install.sh complete"
