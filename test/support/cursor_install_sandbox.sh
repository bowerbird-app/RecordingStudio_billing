#!/usr/bin/env bash
# Run .cursor/install.sh against stubbed PATH. Modes: warm, cold-apt-fail.
# Prints SANDBOX_* lines a test can parse. Does not talk to apt or the network.

set -euo pipefail

MODE="${1:?mode required: warm or cold-apt-fail}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_SH="${INSTALL_SH:-${ROOT}/.cursor/install.sh}"
RUBY_VERSION="$(tr -d '[:space:]' < "${ROOT}/.ruby-version")"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cursor-install-sandbox.XXXXXX")"

BIN="${SANDBOX}/bin"
FAKE_ROOT="${SANDBOX}/app"
FAKE_CURSOR="${FAKE_ROOT}/.cursor"
LOG="${SANDBOX}/calls.log"
mkdir -p "${BIN}" "${FAKE_CURSOR}" "${FAKE_ROOT}/test/dummy"
: > "${LOG}"

link_tool() {
  local name="$1"
  local path
  path="$(command -v "${name}" || true)"
  if [[ -n "${path}" && ! -e "${BIN}/${name}" ]]; then
    ln -s "${path}" "${BIN}/${name}"
  fi
}

for tool in bash tr seq sleep id rm cat chmod mkdir ls tee mktemp git uname dirname basename head cut grep mv cp touch; do
  link_tool "${tool}"
done

cat > "${BIN}/sudo" << 'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${STUB_LOG}"
case " $* " in
  *" apt-get "*) exit "${APT_GET_EXIT:-1}" ;;
esac
exit 0
EOF
chmod +x "${BIN}/sudo"

cat > "${FAKE_CURSOR}/fetch-skills.sh" << 'EOF'
#!/usr/bin/env bash
printf 'fetch-skills\n' >> "${STUB_LOG}"
printf 'fetch-skills: ok\n'
exit 0
EOF
chmod +x "${FAKE_CURSOR}/fetch-skills.sh"

cp "${INSTALL_SH}" "${FAKE_CURSOR}/install.sh"
chmod +x "${FAKE_CURSOR}/install.sh"
printf '%s\n' "${RUBY_VERSION}" > "${FAKE_ROOT}/.ruby-version"

if [[ "${MODE}" == "warm" ]]; then
  cat > "${BIN}/ruby" << EOF
#!/usr/bin/env bash
printf 'ruby %s\n' "\$*" >> "\${STUB_LOG}"
if [[ "\$1" == "-e" && "\$2" == "print RUBY_VERSION" ]]; then
  printf '%s' "${RUBY_VERSION}"
  exit 0
fi
exit 0
EOF
  cat > "${BIN}/bundle" << 'EOF'
#!/usr/bin/env bash
printf 'bundle %s\n' "$*" >> "${STUB_LOG}"
exit 0
EOF
  cat > "${BIN}/pg_isready" << 'EOF'
#!/usr/bin/env bash
printf 'pg_isready %s\n' "$*" >> "${STUB_LOG}"
exit 0
EOF
  chmod +x "${BIN}/ruby" "${BIN}/bundle" "${BIN}/pg_isready"
elif [[ "${MODE}" != "cold-apt-fail" ]]; then
  echo "unknown mode: ${MODE}" >&2
  exit 2
fi

export STUB_LOG="${LOG}"
export APT_GET_EXIT=1
export PATH="${BIN}"
export HOME="${SANDBOX}"

set +e
STDOUT_FILE="${SANDBOX}/stdout.log"
"${FAKE_CURSOR}/install.sh" > "${STDOUT_FILE}" 2>&1
SANDBOX_EXIT=$?
set -e

SANDBOX_FETCHED=0
grep -qx 'fetch-skills' "${LOG}" && SANDBOX_FETCHED=1

SANDBOX_APT=0
grep -q 'apt-get' "${LOG}" && SANDBOX_APT=1

SANDBOX_SKIP=0
grep -q 'already usable' "${STDOUT_FILE}" && SANDBOX_SKIP=1

printf 'SANDBOX_EXIT=%s\n' "${SANDBOX_EXIT}"
printf 'SANDBOX_FETCHED=%s\n' "${SANDBOX_FETCHED}"
printf 'SANDBOX_APT=%s\n' "${SANDBOX_APT}"
printf 'SANDBOX_SKIP=%s\n' "${SANDBOX_SKIP}"
printf 'SANDBOX_DIR=%s\n' "${SANDBOX}"
printf 'SANDBOX_LOG=%s\n' "${LOG}"
printf 'SANDBOX_STDOUT=%s\n' "${STDOUT_FILE}"
