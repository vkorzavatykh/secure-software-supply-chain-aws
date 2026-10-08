#!/usr/bin/env bash
# Uploads a CycloneDX SBOM to Dependency-Track and applies the policy gate (security §5, ADR-014).
#
# Usage: dtrack-upload-and-gate.sh --url URL --sbom FILE --project NAME --version VERSION
#                                  [--report-only] [--timeout SECONDS]
# Environment:
#   DTRACK_API_KEY   API key of the "ci" team. Read from the environment, never from an argument.
#
# Writes a Markdown summary to stdout and progress to stderr. Exit codes:
#   0  no unsuppressed FAIL violation (or --report-only)
#   1  at least one unsuppressed FAIL violation: the gate blocks
#   2  the server couldn't be reached, processing failed or timed out: fails closed (ADR-015)
#
# "Processing finished" for the upload token covers BOM import, vulnerability analysis and policy
# evaluation in Dependency-Track v5 (ADR-024), so violations are complete once it reports COMPLETED.
set -euo pipefail

url='' sbom='' project='' version='' gate=true timeout=300
while [[ $# -gt 0 ]]; do
  case $1 in
    --url) url=${2%/}; shift 2 ;;
    --sbom) sbom=$2; shift 2 ;;
    --project) project=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --report-only) gate=false; shift ;;
    --timeout) timeout=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
if [[ -z $url || -z $project || -z $version || ! -f $sbom ]]; then
  echo "usage: $(basename "$0") --url URL --sbom FILE --project NAME --version VERSION [--report-only] [--timeout SECONDS]" >&2
  exit 64
fi
: "${DTRACK_API_KEY:?DTRACK_API_KEY is required}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
printf 'X-Api-Key: %s\n' "$DTRACK_API_KEY" > "$work/auth"

log() { echo "dtrack: $*" >&2; }
fail_closed() { echo "dtrack: ERROR: $*" >&2; exit 2; }

# api METHOD PATH [curl args...]: body in $work/body, headers in $work/headers, status in $status.
api() {
  local method=$1 path=$2
  shift 2
  status=$(curl -sS --retry 3 --retry-connrefused -o "$work/body" -D "$work/headers" -w '%{http_code}' \
    -X "$method" -H @"$work/auth" "$@" "$url$path") || status=000
}

# get_all PATH: every page of a paginated v1 list (the API returns 100 items by default).
get_all() {
  local path=$1 page=1 size=100 separator='?'
  [[ $path == *\?* ]] && separator='&'
  echo '[]' > "$work/all"
  while :; do
    api GET "$path${separator}pageNumber=$page&pageSize=$size"
    [[ $status == 200 ]] || fail_closed "GET $path returned $status"
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

# --- Upload ---------------------------------------------------------------------------------------------
api POST /api/v1/bom -F autoCreate=true -F "projectName=$project" -F "projectVersion=$version" -F "bom=@$sbom"
[[ $status == 200 ]] || fail_closed "BOM upload returned $status: $(head -c 300 "$work/body" 2>/dev/null)"
token=$(jq -r .token "$work/body")
project_uuid=$(jq -r '.projectUuid // empty' "$work/body")
log "uploaded $sbom as $project@$version (token $token)"

# --- Wait for import, analysis and policy evaluation ----------------------------------------------------
deadline=$((SECONDS + timeout))
while :; do
  api GET "/api/v1/event/token/$token"
  [[ $status == 200 ]] || fail_closed "token status returned $status"
  processing=$(jq -r .processing "$work/body")
  state=$(jq -r '.status // "UNKNOWN"' "$work/body")
  if [[ $processing == false ]]; then
    [[ $state == COMPLETED ]] || fail_closed "processing ended with status $state"
    break
  fi
  (( SECONDS < deadline )) || fail_closed "processing not finished after ${timeout}s (status $state)"
  sleep 5
done
log "analysis completed"

if [[ -z $project_uuid ]]; then
  api GET "/api/v1/project/lookup?name=$(jq -rn --arg v "$project" '$v | @uri')&version=$(jq -rn --arg v "$version" '$v | @uri')"
  [[ $status == 200 ]] || fail_closed "project lookup returned $status"
  project_uuid=$(jq -r .uuid "$work/body")
fi

# --- Results --------------------------------------------------------------------------------------------
get_all "/api/v1/violation/project/$project_uuid?suppressed=false" > "$work/violations.json"
get_all "/api/v1/finding/project/$project_uuid" > "$work/findings.json"
failing=$(jq '[.[] | select(.policyCondition.policy.violationState == "FAIL")] | length' "$work/violations.json")

jq -rn --slurpfile violations "$work/violations.json" --slurpfile findings "$work/findings.json" \
  --arg title "Dependency-Track: $project@$version" --arg link "$url/projects/$project_uuid" \
  --argjson gate "$gate" --argjson failing "$failing" '
  def count($items; f; $value): [$items[] | select(f == $value)] | length;
  def rank: {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "INFO": 4}[.] // 5;
  $violations[0] as $v | $findings[0] as $f
  | "### \($title)",
    "",
    (if $gate | not then "Report only: this project never blocks the change (ADR-023)."
     elif $failing > 0 then "**FAIL**: \($failing) unsuppressed FAIL policy violation(s) (ADR-014)."
     else "**PASS**: no unsuppressed FAIL policy violations. Critical fails, High warns (ADR-014)." end),
    "",
    "| Policy violations | FAIL | WARN | INFO |", "|---|---:|---:|---:|",
    "| unsuppressed | \(count($v; .policyCondition.policy.violationState; "FAIL")) | \(count($v; .policyCondition.policy.violationState; "WARN")) | \(count($v; .policyCondition.policy.violationState; "INFO")) |",
    "",
    "| Findings | Critical | High | Medium | Low | Other |", "|---|---:|---:|---:|---:|---:|",
    "| all | \(count($f; .vulnerability.severity; "CRITICAL")) | \(count($f; .vulnerability.severity; "HIGH")) | \(count($f; .vulnerability.severity; "MEDIUM")) | \(count($f; .vulnerability.severity; "LOW")) | \(($f | length) - count($f; .vulnerability.severity; "CRITICAL") - count($f; .vulnerability.severity; "HIGH") - count($f; .vulnerability.severity; "MEDIUM") - count($f; .vulnerability.severity; "LOW")) |",
    "",
    (if ($v | length) > 0 then
       "| State | Policy | Component |", "|---|---|---|",
       ($v | sort_by(.policyCondition.policy.violationState) | .[]
        | "| \(.policyCondition.policy.violationState) | \(.policyCondition.policy.name) | \(.component.name)@\(.component.version) |"),
       ""
     else empty end),
    (if ($f | length) > 0 then
       "| Severity | Vulnerability | Component |", "|---|---|---|",
       ($f | sort_by((.vulnerability.severity | rank), .vulnerability.vulnId) | .[:25][]
        | "| \(.vulnerability.severity) | \(.vulnerability.vulnId) (\(.vulnerability.source)) | \(.component.name)@\(.component.version) |"),
       ""
     else empty end),
    "Project in Dependency-Track: \($link)",
    ""'

if [[ $gate == true && $failing -gt 0 ]]; then
  log "gate: FAIL ($failing FAIL violation(s))"
  exit 1
fi
if [[ $gate == true ]]; then log "gate: PASS"; else log "report only"; fi
