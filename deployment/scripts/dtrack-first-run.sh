#!/usr/bin/env bash
# First-run configuration of a fresh Dependency-Track v5 instance (architecture §6, steps 9-10; ADR-020).
# Idempotent: it runs on every boot, and on an already configured instance it changes nothing.
#
# Talks to the apiserver directly (localhost on the instance), never through the load balancer:
#   1. replaces the default admin password (admin/admin) with DTRACK_ADMIN_PASSWORD
#   2. ensures team "ci" with the minimal permissions for upload and reading results (security §3)
#   3. creates an API key for "ci" if the team has none, and writes it to --api-key-file
#   4. applies the policies in DTRACK_POLICY_DIR (security §6)
#   5. enables the OSV vulnerability data source for DTRACK_OSV_ECOSYSTEMS (NVD alone matches npm poorly)
#   6. verifies that a login with the default credentials is rejected; only then does it report success
#
# Environment:
#   DTRACK_ADMIN_PASSWORD   the admin password to set or expect (generated and stored by the caller)
#   DTRACK_URL              apiserver base URL (default http://localhost:8081)
#   DTRACK_POLICY_DIR       policy JSON files (default: security/policies next to this repository's scripts)
#   DTRACK_OSV_ECOSYSTEMS   comma-separated OSV ecosystems to mirror (default: npm)
# Options:
#   --api-key-file PATH     write a newly created CI API key here (mode 0600). Required when one is created.
#
# Secrets never appear on command lines: passwords and tokens go to curl through 0600 temporary files.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
url=${DTRACK_URL:-http://localhost:8081}
policy_dir=${DTRACK_POLICY_DIR:-$script_dir/../../security/policies}
osv_ecosystems=${DTRACK_OSV_ECOSYSTEMS:-npm}
api_key_file=
ci_team=ci
ci_permissions=(BOM_UPLOAD PROJECT_CREATION_UPLOAD VIEW_PORTFOLIO VIEW_VULNERABILITY VIEW_POLICY_VIOLATION)

while [[ $# -gt 0 ]]; do
  case $1 in
    --api-key-file) api_key_file=$2; shift 2 ;;
    *) echo "usage: $(basename "$0") [--api-key-file PATH]" >&2; exit 64 ;;
  esac
done
: "${DTRACK_ADMIN_PASSWORD:?DTRACK_ADMIN_PASSWORD is required}"
if [[ $DTRACK_ADMIN_PASSWORD == admin || ${#DTRACK_ADMIN_PASSWORD} -lt 16 ]]; then
  echo "first-run: DTRACK_ADMIN_PASSWORD must be at least 16 characters and not the default" >&2
  exit 64
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077

log() { echo "first-run: $*"; }
fail() { echo "first-run: ERROR: $*" >&2; exit 1; }

# Writes a value to a private file and prints its path, for curl's @file syntax.
secret_file() {
  local path="$work/$1"
  printf '%s' "$2" > "$path"
  echo "$path"
}

# api METHOD PATH [curl args...]: response body in $work/body, status in $status.
api() {
  local method=$1 path=$2
  shift 2
  status=$(curl -sS -o "$work/body" -D "$work/headers" -w '%{http_code}' -X "$method" \
    -H @"$work/auth" "$@" "$url$path")
}

# get_all PATH: every page of a paginated v1 list, as one JSON array.
get_all() {
  local path=$1 page=1 size=100 separator='?'
  [[ $path == *\?* ]] && separator='&'
  echo '[]' > "$work/all"
  while :; do
    api GET "$path${separator}pageNumber=$page&pageSize=$size"
    [[ $status == 200 ]] || fail "GET $path returned $status"
    jq -s '.[0] + .[1]' "$work/all" "$work/body" > "$work/all.next" && mv "$work/all.next" "$work/all"
    local total count
    total=$(grep -i '^x-total-count:' "$work/headers" | tr -dc '0-9' || true)
    count=$(jq length "$work/all")
    if [[ -n $total ]]; then (( count >= total )) && break
    elif (( $(jq length "$work/body") < size )); then break
    fi
    page=$((page + 1))
  done
  cat "$work/all"
}

# login USER PASSWORD: status in $status, body (token or error code) in $work/login.
login() {
  status=$(curl -sS -o "$work/login" -w '%{http_code}' -X POST "$url/api/v1/user/login" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "username=$1" --data-urlencode "password@$(secret_file login-password "$2")")
}

use_token() {
  printf 'Authorization: Bearer %s\n' "$(cat "$work/login")" > "$work/auth"
}

# --- 0. Wait for the apiserver ------------------------------------------------------------------------
deadline=$((SECONDS + 600))
until curl -fs -o /dev/null "$url/api/version"; do
  (( SECONDS < deadline )) || fail "apiserver at $url not ready after 10 minutes"
  sleep 5
done
log "apiserver ready ($(curl -fsS "$url/api/version" | jq -r .version))"

# --- 1. Admin password ----------------------------------------------------------------------------------
login admin "$DTRACK_ADMIN_PASSWORD"
if [[ $status == 200 ]]; then
  log "admin password already set"
else
  login admin admin
  [[ $status == 401 && $(cat "$work/login") == FORCE_PASSWORD_CHANGE ]] ||
    fail "admin accepts neither the configured nor the default password ($status $(cat "$work/login")); refusing to continue"
  status=$(curl -sS -o "$work/body" -w '%{http_code}' -X POST "$url/api/v1/user/forceChangePassword" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode username=admin \
    --data-urlencode "password@$(secret_file old admin)" \
    --data-urlencode "newPassword@$(secret_file new "$DTRACK_ADMIN_PASSWORD")" \
    --data-urlencode "confirmPassword@$(secret_file confirm "$DTRACK_ADMIN_PASSWORD")")
  [[ $status == 200 ]] || fail "password change returned $status"
  log "default admin password replaced"
  login admin "$DTRACK_ADMIN_PASSWORD"
  [[ $status == 200 ]] || fail "login with the new admin password returned $status"
fi
use_token

# --- 2. Team "ci" and its permissions -------------------------------------------------------------------
team=$(get_all /api/v1/team | jq -c --arg name "$ci_team" '.[] | select(.name == $name)')
if [[ -z $team ]]; then
  api PUT /api/v1/team -H 'Content-Type: application/json' --data "$(jq -n --arg name "$ci_team" '{name: $name}')"
  [[ $status == 201 ]] || fail "creating team $ci_team returned $status"
  team=$(cat "$work/body")
  log "team $ci_team created"
fi
team_uuid=$(jq -r .uuid <<<"$team")

for permission in "${ci_permissions[@]}"; do
  api POST "/api/v1/permission/$permission/team/$team_uuid"
  [[ $status == 200 || $status == 304 ]] || fail "granting $permission returned $status"
done
log "team $ci_team has: ${ci_permissions[*]}"

# --- 3. CI API key: created once; the plaintext is returned only at creation ---------------------------
if [[ $(jq '.apiKeys // [] | length' <<<"$team") -eq 0 ]]; then
  [[ -n $api_key_file ]] || fail "team $ci_team has no API key and no --api-key-file was given"
  api PUT "/api/v1/team/$team_uuid/key"
  [[ $status == 201 ]] || fail "creating the API key returned $status"
  jq -j .key "$work/body" > "$api_key_file"
  chmod 600 "$api_key_file"
  log "CI API key created and written to $api_key_file"
else
  log "team $ci_team already has an API key"
fi

# --- 4. Policies ------------------------------------------------------------------------------------------
policies=$(get_all /api/v1/policy)
for file in "$policy_dir"/*.json; do
  desired=$(cat "$file")
  name=$(jq -r .name <<<"$desired")
  current=$(jq -c --arg name "$name" '.[] | select(.name == $name)' <<<"$policies")
  if [[ -z $current ]]; then
    api PUT /api/v1/policy -H 'Content-Type: application/json' \
      --data "$(jq -c '{name, operator, violationState}' <<<"$desired")"
    [[ $status == 201 ]] || fail "creating policy $name returned $status"
    current=$(cat "$work/body")
    log "policy $name created"
  elif [[ $(jq -c '{operator, violationState}' <<<"$current") != $(jq -c '{operator, violationState}' <<<"$desired") ]]; then
    api POST /api/v1/policy -H 'Content-Type: application/json' \
      --data "$(jq -c --argjson desired "$desired" '. + {operator: $desired.operator, violationState: $desired.violationState}' <<<"$current")"
    [[ $status == 200 ]] || fail "updating policy $name returned $status"
    log "policy $name updated"
  fi
  uuid=$(jq -r .uuid <<<"$current")
  while read -r condition; do
    exists=$(jq --argjson c "$condition" \
      '[.policyConditions // [] | .[] | select(.subject == $c.subject and .operator == $c.operator and .value == $c.value)] | length' <<<"$current")
    if [[ $exists -eq 0 ]]; then
      api PUT "/api/v1/policy/$uuid/condition" -H 'Content-Type: application/json' --data "$condition"
      [[ $status == 201 ]] || fail "adding a condition to policy $name returned $status"
      log "policy $name: condition $(jq -r '"\(.subject) \(.operator) \(.value)"' <<<"$condition") added"
    fi
  done < <(jq -c '.conditions[]' <<<"$desired")
done
log "policies applied from $policy_dir"

# --- 5. OSV vulnerability data source -------------------------------------------------------------------
osv_path=/api/v2/extension-points/vuln-data-source/extensions/osv/config
api GET "$osv_path"
[[ $status == 200 ]] || fail "reading the OSV configuration returned $status"
desired_osv=$(jq -c --arg ecosystems "$osv_ecosystems" \
  '{config: (.config + {enabled: true, ecosystems: ($ecosystems | split(","))})}' "$work/body")
if [[ $(jq -c '{config}' "$work/body") != "$desired_osv" ]]; then
  api PUT "$osv_path" -H 'Content-Type: application/json' --data "$desired_osv"
  [[ $status == 204 || $status == 304 ]] || fail "enabling OSV returned $status: $(cat "$work/body")"
  log "OSV enabled for: $osv_ecosystems"
else
  log "OSV already enabled for: $osv_ecosystems"
fi

# Enabling OSV doesn't start a mirror until its next scheduled run, hours away. Start the first one now.
api GET /api/v2/vuln-data-sources/osv/mirror-runs/latest
if [[ $status == 404 ]]; then
  api POST /api/v2/vuln-data-sources/osv/mirror-runs
  [[ $status == 202 ]] || fail "starting the first OSV mirror returned $status"
  log "first OSV mirror started"
fi

# --- 6. The barrier condition (ADR-020): the default login must now be rejected -------------------------
# Both cases answer 401, so the check must read the body: FORCE_PASSWORD_CHANGE would mean the default
# password still works.
login admin admin
[[ $status == 401 && $(cat "$work/login") == INVALID_CREDENTIALS ]] ||
  fail "the default admin login is not rejected ($status $(cat "$work/login"))"
log "verified: the default admin login is rejected"
log "done"
