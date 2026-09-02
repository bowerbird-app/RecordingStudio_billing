#!/usr/bin/env bash
# Cloud Agent Build hook. Fetches project skills into .cursor/skills and plugin
# *.mdc rules into .cursor/rules (both gitignored). Lists recording-studio-*
# from the plugin skills directory, then extra skills from skill-sources.json,
# then type=file *.mdc from the plugin rules directory. Discover ids via the
# public GitHub contents API, then GET each file from raw.githubusercontent.com.
# Never clones. Never writes ~/.cursor/skills or ~/.cursor/rules. Fetch failures
# warn on stderr and continue; always exit 0 so the Build succeeds.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${ROOT}/.cursor/skills"
RULES_DIR="${ROOT}/.cursor/rules"

PLUGIN_OWNER="bowerbird-app"
PLUGIN_REPO="RecordingStudio_cursor_plugin"
PLUGIN_REF="main"
PLUGIN_CONTENTS_API="https://api.github.com/repos/${PLUGIN_OWNER}/${PLUGIN_REPO}/contents/skills?ref=${PLUGIN_REF}&per_page=100"
PLUGIN_RAW="https://raw.githubusercontent.com/${PLUGIN_OWNER}/${PLUGIN_REPO}/${PLUGIN_REF}/skills"
PLUGIN_CATALOG="https://raw.githubusercontent.com/${PLUGIN_OWNER}/${PLUGIN_REPO}/${PLUGIN_REF}/skill-sources.json"
PLUGIN_RULES_API="https://api.github.com/repos/${PLUGIN_OWNER}/${PLUGIN_REPO}/contents/rules?ref=${PLUGIN_REF}"
PLUGIN_RULES_RAW="https://raw.githubusercontent.com/${PLUGIN_OWNER}/${PLUGIN_REPO}/${PLUGIN_REF}/rules"
USER_AGENT="RecordingStudio-gem-template-fetch-skills"
SKIP_ID="add-skill-or-agent"

warn() {
  printf 'fetch-skills: %s\n' "$*" >&2
}

mkdir -p "${SKILLS_DIR}"

fetch_raw() {
  local dest_id="$1"
  local url="$2"
  local dest_dir="${SKILLS_DIR}/${dest_id}"
  local tmp

  mkdir -p "${dest_dir}"
  tmp="$(mktemp "${dest_dir}/.SKILL.md.XXXXXX")" || {
    warn "could not create temp file for ${dest_id}"
    return 0
  }

  if curl -fsSL --retry 2 --retry-delay 1 -A "${USER_AGENT}" -o "${tmp}" "${url}" && [[ -s "${tmp}" ]]; then
    mv -f "${tmp}" "${dest_dir}/SKILL.md"
  else
    warn "failed to fetch ${dest_id} from ${url}"
    rm -f "${tmp}"
  fi
}

fetch_rule() {
  local filename="$1"
  local url="$2"
  local tmp

  mkdir -p "${RULES_DIR}"
  tmp="$(mktemp "${RULES_DIR}/.${filename}.XXXXXX")" || {
    warn "could not create temp file for ${filename}"
    return 0
  }

  if curl -fsSL --retry 2 --retry-delay 1 -A "${USER_AGENT}" -o "${tmp}" "${url}" && [[ -s "${tmp}" ]]; then
    mv -f "${tmp}" "${RULES_DIR}/${filename}"
  else
    warn "failed to fetch ${filename} from ${url}"
    rm -f "${tmp}"
  fi
}

dir_names_from_contents_json() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for item in data:
    if not isinstance(item, dict):
        continue
    if item.get("type") != "dir":
        continue
    name = item.get("name") or ""
    if name:
        print(name)
'
}

file_names_from_contents_json() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for item in data:
    if not isinstance(item, dict):
        continue
    if item.get("type") != "file":
        continue
    name = item.get("name") or ""
    if name.endswith(".mdc") and "/" not in name:
        print(name)
'
}

list_dir_ids() {
  local api_url="$1"
  local json

  json="$(curl -fsSL --retry 2 --retry-delay 1 -A "${USER_AGENT}" \
    -H "Accept: application/vnd.github+json" \
    "${api_url}")" || {
    warn "failed to list skills from GitHub contents API"
    return 0
  }

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; cannot parse skill list"
    return 0
  fi

  printf '%s' "${json}" | dir_names_from_contents_json
}

catalog_sources() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(2)
sources = data.get("sources")
if not isinstance(sources, list):
    sys.exit(3)
for source in sources:
    if not isinstance(source, dict):
        continue
    contents_api = source.get("contents_api") or ""
    raw_base = source.get("raw_base") or ""
    if contents_api and raw_base:
        print(contents_api + "\t" + raw_base)
'
}

fetch_catalog_extras() {
  local catalog
  local sources
  local parse_status
  local contents_api
  local raw_base
  local skill_id

  catalog="$(curl -fsSL --retry 2 --retry-delay 1 -A "${USER_AGENT}" "${PLUGIN_CATALOG}")" || {
    warn "skill-sources.json unavailable; skipping extras"
    return 0
  }

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; cannot parse skill-sources.json"
    return 0
  fi

  sources="$(printf '%s' "${catalog}" | catalog_sources)"
  parse_status=$?
  if [[ "${parse_status}" -ne 0 ]]; then
    if [[ "${parse_status}" -eq 2 ]]; then
      warn "skill-sources.json is invalid JSON; skipping extras"
    else
      warn "skill-sources.json has no sources; skipping extras"
    fi
    return 0
  fi

  while IFS=$'\t' read -r contents_api raw_base; do
    [[ -z "${contents_api}" || -z "${raw_base}" ]] && continue
    while IFS= read -r skill_id; do
      [[ -z "${skill_id}" ]] && continue
      fetch_raw "${skill_id}" "${raw_base}/${skill_id}/SKILL.md"
    done < <(list_dir_ids "${contents_api}")
  done <<< "${sources}"
}

list_rule_files() {
  local json

  json="$(curl -fsSL --retry 2 --retry-delay 1 -A "${USER_AGENT}" \
    -H "Accept: application/vnd.github+json" \
    "${PLUGIN_RULES_API}")" || {
    warn "failed to list rules from GitHub contents API; skipping"
    return 0
  }

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; cannot parse rule list; skipping"
    return 0
  fi

  printf '%s' "${json}" | file_names_from_contents_json
}

fetch_plugin_rules() {
  local filename

  while IFS= read -r filename; do
    [[ -z "${filename}" ]] && continue
    fetch_rule "${filename}" "${PLUGIN_RULES_RAW}/${filename}"
  done < <(list_rule_files)
}

while IFS= read -r skill_id; do
  [[ -z "${skill_id}" ]] && continue
  [[ "${skill_id}" == "${SKIP_ID}" ]] && continue
  [[ "${skill_id}" == recording-studio-* ]] || continue
  fetch_raw "${skill_id}" "${PLUGIN_RAW}/${skill_id}/SKILL.md"
done < <(list_dir_ids "${PLUGIN_CONTENTS_API}")

fetch_catalog_extras
fetch_plugin_rules

exit 0
