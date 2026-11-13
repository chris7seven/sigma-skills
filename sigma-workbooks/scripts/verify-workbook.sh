#!/usr/bin/env bash
# verify-workbook.sh — confirm a created workbook's elements compile to valid SQL.
#
# Why this exists: POST /v2/workbooks/spec is generous. It accepts specs whose
# column formulas don't actually resolve, then surfaces the failures at query
# time as string literals embedded in the compiled SQL — e.g.
#   select 'Unknown column "[ORDER_TOTAL]"' V_44 from ...
#   select 'Circular column reference to [Quarter]' V_11 ...
# The UI renders these elements as empty. Catching this is impossible from the
# spec alone; only Sigma's compiler knows. This script asks the server.
#
# For each element on the workbook, it fetches the compiled SQL via
#   GET /v2/workbooks/{id}/elements/{eid}/query
# and greps the markers. Any hit means a formula doesn't resolve.
#
# Usage: ./verify-workbook.sh <workbook-id>
# Requires env: SIGMA_BASE_URL, SIGMA_API_TOKEN.
# Exit codes:
#   0  — every element compiled clean
#   1  — one or more elements have unresolved/circular references, OR one or
#        more elements could not be verified (transient failure) — either way,
#        do not treat this run as a clean pass
#   2  — setup / input error

set -euo pipefail

WB_ID="${1:-}"
if [ -z "$WB_ID" ]; then
  echo "Usage: $0 <workbook-id>" >&2
  exit 2
fi

if [ -z "${SIGMA_BASE_URL:-}" ] || [ -z "${SIGMA_API_TOKEN:-}" ]; then
  echo "Error: SIGMA_BASE_URL and SIGMA_API_TOKEN must be set in the environment." >&2
  echo "Authenticate via the sigma-api skill first." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 2
fi

ELEMENTS_JSON=$(curl -sf -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/workbooks/$WB_ID/elements") || {
  echo "Error: could not fetch elements for workbook $WB_ID." >&2
  exit 2
}

ERRORS=0
UNVERIFIED=0
TOTAL=0
while IFS=$'\t' read -r EID NAME; do
  TOTAL=$((TOTAL + 1))

  # /elements/{id}/query 4xx's on controls and similar non-queryable elements —
  # that's the EXPECTED "nothing to verify" case, distinct from a transient
  # server failure (timeout, 5xx). Distinguishing them by HTTP status matters:
  # a 5xx or empty response for what should be a real, queryable element must
  # NOT be silently bucketed with legitimate non-queryable elements, or a
  # flaky call masks a genuine unresolved reference as a clean pass. One retry
  # after a short pause absorbs a single transient blip before giving up.
  ATTEMPT=0
  HTTP_STATUS=""
  RAW=""
  while [ "$ATTEMPT" -lt 2 ]; do
    RESPONSE=$(curl -s -w $'\n%{http_code}' -H "Authorization: Bearer $SIGMA_API_TOKEN" \
      "$SIGMA_BASE_URL/v2/workbooks/$WB_ID/elements/$EID/query")
    HTTP_STATUS=$(printf '%s' "$RESPONSE" | tail -n1)
    RAW=$(printf '%s' "$RESPONSE" | sed '$d')
    SQL=$(printf '%s' "$RAW" | jq -r '.sql // ""' 2>/dev/null || true)
    if [ -n "$SQL" ] || [[ "$HTTP_STATUS" == 4* ]]; then
      break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    [ "$ATTEMPT" -lt 2 ] && sleep 2
  done

  if [ -n "$SQL" ]; then
    # grep exits 1 when no matches, which would trip `set -o pipefail` — swallow
    # that case explicitly so a clean element doesn't kill the loop.
    BAD=$(printf '%s' "$SQL" \
      | grep -oE "(Unknown column \"[^\"]+\"|Circular column reference to \[[^]]+\])" \
      | sort -u | paste -sd '; ' - || true)
    if [ -n "$BAD" ]; then
      printf '  [FAIL] %-30s (%s) — %s\n' "$NAME" "$EID" "$BAD"
      ERRORS=$((ERRORS + 1))
    else
      printf '  [ok]   %-30s (%s)\n' "$NAME" "$EID"
    fi
  elif [[ "$HTTP_STATUS" == 4* ]]; then
    printf '  [skip] %-30s (%s) — no SQL (control or non-queryable element, HTTP %s)\n' "$NAME" "$EID" "$HTTP_STATUS"
  else
    printf '  [ERROR] %-30s (%s) — query endpoint returned HTTP %s with no SQL after retry; UNVERIFIED, not confirmed clean\n' "$NAME" "$EID" "${HTTP_STATUS:-no response}"
    UNVERIFIED=$((UNVERIFIED + 1))
  fi
done < <(echo "$ELEMENTS_JSON" | jq -r '.entries[]? | [.elementId, .name] | @tsv')

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "$ERRORS of $TOTAL element(s) have unresolved formula references."
  echo "Fix the offending columns in the spec (see reference/specification/formulas.md)"
  echo "and re-PUT the spec, then re-verify."
fi
if [ "$UNVERIFIED" -gt 0 ]; then
  echo "$UNVERIFIED of $TOTAL element(s) could not be verified (server error, not a spec"
  echo "problem) even after a retry. Re-run this script before trusting the result — do"
  echo "NOT treat a run containing [ERROR] lines as a clean pass."
fi
if [ "$ERRORS" -gt 0 ] || [ "$UNVERIFIED" -gt 0 ]; then
  exit 1
fi
echo "All $TOTAL element(s) compile cleanly."
exit 0
