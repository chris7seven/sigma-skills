#!/usr/bin/env bash
# validate-spec.sh — scan a workbook spec for likely formula-qualification errors.
#
# Flags a bare bracketed reference (e.g. [Dock Count]) that does not resolve to
# a DECLARED column of the same element. A bare [X] binds only when X is a
# declared column: one with an explicit name, OR a passthrough declared as
# [Source/X] (whose display name is the derived X). A bare ref to a source
# column that isn't declared on the element does NOT bind — it renders "Unknown
# column" — so it is flagged. Qualified refs ([Source/col]) are never flagged.
# Authoritative validation is server-side: create the workbook, then run
# verify-workbook.sh (it compiles every element and reports refs that don't resolve).
#
# Accepts YAML (recommended) or JSON input. YAML is detected by the
# .yaml/.yml extension and converted to JSON internally before the jq pass.
#
# Usage: ./validate-spec.sh <path-to-spec.yaml|.json>
# Exit codes:
#   0  — no obvious issues
#   1  — issues found
#   2  — setup / input error
#
# Limitations: regex-based, so it does not parse formulas semantically. It can
# produce false positives on bracketed text inside string literals (e.g.
# DateFormat(..., "[MM] %Y") ) — inspect flagged cases before blindly fixing.
# It does NOT verify that qualified refs ([Source/col]) point to real sources;
# the server reports those.

set -euo pipefail

FILE="${1:-}"
if [ -z "$FILE" ]; then
  echo "Usage: $0 <path-to-spec.yaml|.json>" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install with: brew install jq (macOS) or apt install jq (Debian/Ubuntu)." >&2
  exit 2
fi

if [ ! -f "$FILE" ]; then
  echo "Error: file not found: $FILE" >&2
  exit 2
fi

# Convert YAML → JSON in memory if the file looks like YAML. Try yq first (works
# for both the Python wrapper kislyuk/yq and the Go mikefarah/yq via -o=json
# fallback), then fall back to Python+PyYAML. JSON files pass through untouched.
to_json() {
  case "$FILE" in
    *.yaml|*.yml)
      if command -v yq >/dev/null 2>&1; then
        # Python yq (kislyuk): `yq .` emits JSON. Go yq (mikefarah): `yq .`
        # emits YAML and STILL exits 0, so checking the exit code alone feeds
        # YAML to jq. Verify the output actually parses as JSON before using
        # it; otherwise fall through to Go yq's `-o=json`.
        local out
        out="$(yq . "$FILE" 2>/dev/null)" \
          && printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
          && { printf '%s' "$out"; return 0; }
        out="$(yq -o=json . "$FILE" 2>/dev/null)" \
          && printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
          && { printf '%s' "$out"; return 0; }
      fi
      if command -v python3 >/dev/null 2>&1; then
        python3 - "$FILE" <<'PY' 2>/dev/null && return 0
import sys, json
try:
    import yaml
except ImportError:
    sys.exit(2)
with open(sys.argv[1]) as f:
    print(json.dumps(yaml.safe_load(f)))
PY
      fi
      echo "Error: cannot convert YAML to JSON. Install one of:" >&2
      echo "  - yq:           brew install yq, apt install yq, or pip install yq" >&2
      echo "  - PyYAML:       pip install PyYAML  (python3 + import yaml)" >&2
      exit 2
      ;;
    *)
      cat "$FILE"
      ;;
  esac
}

SPEC_JSON="$(to_json)"

# Elements moved from per-page/panel nesting to a flat document.elements array
# (breaking change, ~Aug 2026) -- support both shapes so this script doesn't
# silently stop checking anything against a new-shape spec. New shape: flat
# document.elements. Old shape: elements nested under document.pages[]/pages[]
# and document.panels[]/panels[] -- flatten those into one list for the same checks.
# (Defined as a jq function, ALL_ELEMENTS, and reused via `import` isn't
# available in a one-shot -r program, so it's inlined verbatim below.)

ISSUES=$(printf '%s' "$SPEC_JSON" | jq -r '
  def all_elements:
    (.document.elements // (
      [(.document.pages // .pages // [])[]?.elements[]?] +
      [(.document.panels // .panels // [])[]?.elements[]?]
    ));
  all_elements[]? |
    . as $element |
    (.columns // []) as $cols |
    # A bare [X] binds iff X is a DECLARED column of this element: a column
    # with an explicit name, OR a passthrough declared as [Source/X] whose
    # display name is the derived X. Build both into the sibling set. A bare
    # ref to a source column that is NOT declared here does not bind (it
    # renders "Unknown column"), so it is correctly flagged.
    ( $cols | map(.name // "") ) as $named |
    ( $cols | map( (.formula // "") | ( (capture("^\\[[^/]+/(?<n>[^\\]]+)\\]$") | .n) // "" ) ) ) as $derived |
    ( ($named + $derived) | map(select(. != "")) ) as $siblings |
    $cols[]? |
    . as $col |
    ($col.formula // "") as $formula |
    ( [ $formula | scan("\\[[^/\\]]+\\]") | .[1:-1] ] ) as $bare_refs |
    ( $bare_refs | map(select(. as $ref | $siblings | index($ref) | not)) ) as $unresolved |
    select($unresolved | length > 0) |
    "Element: \($element.name // $element.id // "(unnamed)")\n  Column: \($col.name // $col.id // "(unnamed)")\n  Formula: \($formula)\n  Unresolved bare refs: \($unresolved | join(", "))\n"
')

FORMULA_ISSUES_FOUND=0
if [ -z "$ISSUES" ]; then
  echo "OK: no obvious formula qualification errors."
  echo ""
  echo "Note: this flags bare refs ([col] with no '/') that don't resolve to a declared"
  echo "column on the same element — counting both explicitly-named columns and passthrough"
  echo "columns ([Source/col], whose display name is the derived 'col'). Qualified refs are"
  echo "not checked here; the server verifies those on publish (verify-workbook.sh)."
else
  FORMULA_ISSUES_FOUND=1
  echo "Likely formula qualification errors:"
  echo ""
  echo "$ISSUES"
  echo "Fix: a bare bracketed ref ([col] with no '/') must resolve to a DECLARED column of the"
  echo "same element — either a column with that 'name', or a passthrough declared as"
  echo "[Source/col]. If the column lives on the source but isn't declared here, add the source"
  echo "prefix ([SourceName/col]) or declare the column — otherwise it renders 'Unknown column'."
fi

# --- Layout elementId cross-check ---------------------------------------
#
# document.layout is a bare-string XML fragment (no XML root — see layout.md)
# naming pages and elements by id. On the NEW (flat document.elements) shape,
# placing an elementId under a <Page>/<Panel> in layout is what ASSIGNS it
# there in the first place -- the server rejects an unplaced element outright
# ("element '<id>' is not placed in layout"), so a typo'd elementId in layout
# just means the REAL element is unplaced, not that the tag silently no-ops.
# On the OLD (per-page-nested) shape, the failure mode is silent instead: a
# <Element>/<Container> whose elementId doesn't match any element
# actually declared on that page is dropped with no error, and neither the
# server nor verify-workbook.sh catches it. This regex-based scan is
# line-oriented, matching this script's existing philosophy: it assumes one
# tag per line (true of every example in this skill and everything the
# CREATE workflow round-trips), and can miss a layout string hand-packed onto
# fewer lines — inspect flagged cases either way.
LAYOUT=$(printf '%s' "$SPEC_JSON" | jq -r '.document.layout // .layout // ""')
HAS_FLAT_ELEMENTS=$(printf '%s' "$SPEC_JSON" | jq -r '(.document.elements != null)')

LAYOUT_ISSUES_FOUND=0
if [ -n "$LAYOUT" ]; then
  if [ "$HAS_FLAT_ELEMENTS" = "true" ]; then
    # New shape: no per-page ownership to correlate against -- just check
    # every referenced elementId exists SOMEWHERE in document.elements.
    LAYOUT_REFS=$(printf '%s' "$LAYOUT" | grep -oE 'elementId="[^"]*"' | sed -E 's/elementId="([^"]*)"/\1/')
    DECLARED_REFS=$(printf '%s' "$SPEC_JSON" | jq -r '.document.elements[]?.id')
    ORPHANED=$(comm -23 <(printf '%s\n' "$LAYOUT_REFS" | sort -u) <(printf '%s\n' "$DECLARED_REFS" | sort -u) | grep -v '^\s*$' || true)
    if [ -n "$ORPHANED" ]; then
      LAYOUT_ISSUES_FOUND=1
      echo ""
      echo "Layout XML references an elementId with no matching entry in document.elements"
      echo "(the real element is unplaced — the server rejects this outright at write time,"
      echo "\"element '<id>' is not placed in layout\" — this is a pre-submit heads-up):"
      echo ""
      echo "$ORPHANED" | awk '{print "  elementId: " $1}'
      echo ""
      echo "Fix: remove the stale <Element>/<Container> tag, or add the missing"
      echo "element to document.elements — usually left over after deleting an element"
      echo "without updating layout, or a typo in elementId."
    else
      echo ""
      echo "OK: every layout elementId resolves to a declared element in document.elements."
    fi
  else

  # pageId<TAB>elementId pairs the layout XML actually references.
  LAYOUT_REFS=$(printf '%s' "$LAYOUT" | awk '
    /<Page[ >]/ {
      match($0, /id="[^"]*"/)
      page = substr($0, RSTART+4, RLENGTH-5)
    }
    /elementId="[^"]*"/ {
      s = $0
      while (match(s, /elementId="[^"]*"/)) {
        eid = substr(s, RSTART+11, RLENGTH-12)
        print page "\t" eid
        s = substr(s, RSTART+RLENGTH)
      }
    }
  ')

  # pageId<TAB>elementId pairs that actually exist in document.pages[].elements[]
  # (old, pre-flatten shape only -- this branch only runs when document.elements
  # is absent).
  DECLARED_REFS=$(printf '%s' "$SPEC_JSON" | jq -r '
    (.document.pages // .pages // [])[]? |
      .id as $pageId | .elements[]?.id as $elId | "\($pageId)\t\($elId)"
  ')

  ORPHANED=$(comm -23 <(printf '%s\n' "$LAYOUT_REFS" | sort -u) <(printf '%s\n' "$DECLARED_REFS" | sort -u) | grep -v '^\s*$' || true)

  if [ -n "$ORPHANED" ]; then
    LAYOUT_ISSUES_FOUND=1
    echo ""
    echo "Layout XML references an elementId with no matching element on that page"
    echo "(silently dropped by the server — the element won't render where you expect):"
    echo ""
    echo "$ORPHANED" | awk -F'\t' '{print "  Page: " $1 "  ->  elementId: " $2}'
    echo ""
    echo "Fix: remove the stale <Element>/<Container> tag, or add the missing"
    echo "element — usually left over after deleting an element without updating layout."
  else
    echo ""
    echo "OK: every layout elementId resolves to a declared element on its page."
  fi
  fi
else
  echo ""
  echo "No document.layout present — skipping layout elementId cross-check."
fi

if [ "$FORMULA_ISSUES_FOUND" -eq 1 ] || [ "$LAYOUT_ISSUES_FOUND" -eq 1 ]; then
  exit 1
fi
exit 0
