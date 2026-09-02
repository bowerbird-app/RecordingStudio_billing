#!/usr/bin/env bash
# Cloud Agent install hook for Recording Studio Billing.
#
# Cold image: provision Ruby, PostgreSQL 16, gems, the dummy database, and CSS.
# Warm snapshot: skip apt, ruby-build, db:prepare, and tailwind when Ruby, bundle,
# and Postgres are already usable. Always fetch skills last. A skippable
# provision failure must not fail the Build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

RUBY_VERSION="$(tr -d '[:space:]' < "${ROOT}/.ruby-version")"
PREFIX=/usr/local

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

ruby_ok() {
  command -v ruby >/dev/null 2>&1 || return 1
  [ "$(ruby -e 'print RUBY_VERSION')" = "${RUBY_VERSION}" ]
}

bundle_ok() {
  command -v bundle >/dev/null 2>&1
}

postgres_ok() {
  command -v pg_isready >/dev/null 2>&1 || return 1
  pg_isready -h localhost -U postgres >/dev/null 2>&1
}

# Run fn in a subshell with errexit. Sets TRY_OK. Never call this from if/&&/||;
# that context ignores set -e even inside the subshell.
try() {
  local on_fail="$1"
  local fn="$2"
  local status
  set +e
  (
    set -euo pipefail
    "${fn}"
  )
  status=$?
  set -e
  if [ "${status}" -ne 0 ]; then
    log "${on_fail}"
    TRY_OK=0
  else
    TRY_OK=1
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends \
    build-essential git git-lfs curl ca-certificates \
    libpq-dev postgresql-client libyaml-dev pkg-config \
    libssl-dev zlib1g-dev libffi-dev libreadline-dev libgmp-dev \
    autoconf bison postgresql postgresql-contrib
}

install_ruby() {
  if ! command -v ruby-build >/dev/null 2>&1; then
    rm -rf /tmp/ruby-build
    git clone --depth 1 https://github.com/rbenv/ruby-build.git /tmp/ruby-build
    sudo PREFIX="${PREFIX}" /tmp/ruby-build/install.sh
  fi
  sudo ruby-build "${RUBY_VERSION}" "${PREFIX}"
}

install_gems_and_dummy() {
  bundle install
  ( cd test/dummy && bundle install )
  log "Preparing dummy app database and assets"
  ( cd test/dummy && bundle exec rails db:prepare )
  ( cd test/dummy && bundle exec rails tailwindcss:build )
}

start_postgres() {
  sudo pg_ctlcluster 16 main start 2>/dev/null || true
  if command -v pg_isready >/dev/null 2>&1; then
    for _ in $(seq 1 30); do
      pg_isready -h localhost -U postgres >/dev/null 2>&1 && break
      sleep 1
    done
  fi
  sudo -u postgres psql -tAc "ALTER USER postgres PASSWORD 'postgres';" >/dev/null 2>&1 || true
}

if ruby_ok && bundle_ok && postgres_ok; then
  log "Ruby ${RUBY_VERSION}, bundle, and Postgres already usable; skipping apt, ruby-build, db:prepare, and tailwind"
else
  if ruby_ok; then
    log "Ruby ${RUBY_VERSION} already present; skipping apt and ruby-build"
  else
    log "Installing system packages"
    try "apt failed; skipping ruby-build" install_packages
    if [ "${TRY_OK}" -eq 1 ]; then
      log "Installing Ruby ${RUBY_VERSION}"
      try "Ruby install failed; continuing to fetch-skills" install_ruby
      sudo chown -R "$(id -u):$(id -g)" \
        "${PREFIX}/lib/ruby" "${PREFIX}/bin" "${PREFIX}/include/ruby-${RUBY_VERSION%.*}.0" 2>/dev/null || true
      if ! command -v bundle >/dev/null 2>&1; then
        gem install bundler || log "bundler install failed; continuing to fetch-skills"
      fi
    fi
  fi

  if postgres_ok; then
    log "Postgres already usable; skipping cluster start"
  else
    log "Starting PostgreSQL"
    start_postgres
    postgres_ok || log "Postgres is not ready; continuing to fetch-skills"
  fi

  if ruby_ok && bundle_ok; then
    log "bundle already usable; skipping bundle install, db:prepare, and tailwind"
  elif ! ruby_ok; then
    log "Ruby is not usable; skipping bundle install, db:prepare, and tailwind"
  else
    log "Installing gem dependencies"
    try "bundle, db:prepare, or tailwind failed; continuing to fetch-skills" install_gems_and_dummy
  fi
fi

log "Fetching Recording Studio skills and plugin rules"
"${SCRIPT_DIR}/fetch-skills.sh"

log "install.sh complete"
