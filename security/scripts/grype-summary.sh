#!/usr/bin/env bash
# Renders a Grype JSON report as Markdown for the GitHub job summary (or a terminal).
#
# Usage: grype-summary.sh <grype-report.json> <title> <gating|report-only>
#
# In gating mode the verdict follows the gate policy (ADR-014): any Critical finding that is not covered by
# an ignore rule in .grype.yaml fails. The script only reports; Grype's own exit code enforces the gate.
set -euo pipefail

if [[ $# -ne 3 || ! -f $1 || ! $3 =~ ^(gating|report-only)$ ]]; then
  echo "usage: $(basename "$0") <grype-report.json> <title> <gating|report-only>" >&2
  exit 64
fi

report=$1
title=$2
mode=$3
max_rows=25

jq -r --arg title "$title" --arg mode "$mode" --argjson max_rows "$max_rows" '
  def rank: {"Critical": 0, "High": 1, "Medium": 2, "Low": 3, "Negligible": 4}[.] // 5;
  def count($severity): [.[] | select(.vulnerability.severity == $severity)] | length;
  def fixed_in: if .vulnerability.fix.state == "fixed"
                then (.vulnerability.fix.versions | join(", "))
                else "—" + (if .vulnerability.fix.state == "wont-fix" then " (won'\''t fix)" else "" end) end;

  (.matches // []) as $matches
  | ((.ignoredMatches // []) | length) as $ignored
  | ($matches | count("Critical")) as $critical
  | "### \($title)",
    "",
    (if $mode == "gating" then
       (if $critical > 0 then "**FAIL**: \($critical) Critical finding(s). Critical blocks the change (ADR-014)."
        else "**PASS**: no Critical findings. Critical blocks the change; High and lower are reported (ADR-014)." end)
     else "Report only: these findings never block the change (ADR-023)." end),
    "",
    "| Critical | High | Medium | Low | Negligible / unknown | Ignored with a reason |",
    "|---:|---:|---:|---:|---:|---:|",
    "| \($critical) | \($matches | count("High")) | \($matches | count("Medium")) | \($matches | count("Low")) | \(($matches | length) - $critical - ($matches | count("High")) - ($matches | count("Medium")) - ($matches | count("Low"))) | \($ignored) |",
    "",
    (if ($matches | length) == 0 then "No vulnerabilities found."
     else
       "| Severity | Vulnerability | Package | Installed | Fixed in |",
       "|---|---|---|---|---|",
       ($matches
        | sort_by((.vulnerability.severity | rank), .vulnerability.id, .artifact.name)
        | .[:$max_rows][]
        | "| \(.vulnerability.severity) | [\(.vulnerability.id)](\(.vulnerability.dataSource)) | \(.artifact.name) (\(.artifact.type)) | \(.artifact.version) | \(fixed_in) |"),
       (if ($matches | length) > $max_rows then "", "Showing \($max_rows) of \($matches | length); the full report is in the workflow artifacts." else empty end)
     end),
    ""
' "$report"
