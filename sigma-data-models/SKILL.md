---
name: sigma-data-models
description: >-
  Build, edit, and iterate on Sigma data model specs — tables (warehouse +
  custom SQL elements), columns, relationships, and metrics — by calling the
  Sigma REST API directly. Use whenever the user wants to create or modify a
  Sigma data model from a spec, translate a star-schema design into Sigma,
  troubleshoot data model column-resolution errors, set up real Metrics-panel
  metrics, define joins between fact and dim tables, or convert their
  `tables:`-style YAML "as-code" data model into something the JSON API
  accepts. Requires SIGMA_API_TOKEN — obtain via the sigma-api skill first.
---

# Sigma Data Models (Build from Spec via REST API)

Build Sigma data models programmatically by calling `POST /v2/datamodels/spec`. This is **separate from `sigma-workbooks`** — workbooks consume data models; this skill creates the data models they reference.

**Auth prerequisite:** `SIGMA_API_TOKEN` set via the `sigma-api` skill. Pick the env file in `~/.sigma/*.env` matching the target tenant.

```bash
source ~/.sigma/<tenant>.env
export SIGMA_API_TOKEN=$(curl -s -X POST "$SIGMA_BASE_URL/v2/auth/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=client_credentials&client_id=$SIGMA_CLIENT_ID&client_secret=$SIGMA_CLIENT_SECRET" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
```

---

## Critical knowledge — read before building

These are non-obvious facts that took many failed probes to nail down. Most Sigma docs and AI assumptions get them wrong.

### 1. Two YAML formats exist; the JSON API only accepts one shape

- **YAML "as-code" format** (`data_model:`, `tables:` at top level, top-level `metrics:` and `relationships:`) is what Sigma's UI exports and what users hand-edit. It's processed by an internal toolchain you DON'T have access to via the JSON API.
- **JSON API format** (`name`, `schemaVersion`, `pages[].elements[]` nested) is what `POST /v2/datamodels/spec` accepts. You MUST translate the YAML → JSON shape before POSTing.

The user may have `_build_yaml.py` style scripts that do JSON → YAML (one-way export for version control). They don't have a YAML → JSON translator — you do it programmatically in Python.

### 2. SQL element column formulas need the magic `[Custom SQL/...]` prefix

For `kind: sql` source elements, column formulas MUST be exactly `[Custom SQL/<raw_sql_output_col>]`. The `Custom SQL` is the literal source-table name Sigma assigns to every SQL element. The column part is the **raw** SQL output column name (whatever's in the `SELECT col1, col2 AS foo` — lowercase/snake_case as MySQL returns it, or whatever alias you set).

```json
"columns": [
  {"id": "employee_id", "formula": "[Custom SQL/employee_id]", "name": "Employee Id"},
  {"id": "date", "formula": "[Custom SQL/date]", "name": "Date"}
]
```

Wrong (all resolve to "Unknown name"): `[Employee Id]`, `[employee_id]`, `[<element-id>/employee_id]`, `[Dim - Users/Employee Id]`.

### 3. Real Metrics ARE supported — element-level only

Metrics that appear in Sigma's **Metrics panel** (not Columns panel) are supported via the element-level `metrics: []` block:

```json
{
  "id": "el-fct-members",
  "kind": "table",
  "source": {...},
  "columns": [...],
  "metrics": [
    {
      "id": "metric-active-count",
      "formula": "CountIf([Expiration Date] >= Today())",
      "name": "Active Member Count",
      "format": {"kind": "number", "formatString": ",.0f"}
    }
  ]
}
```

Other shapes that are silently STRIPPED:
- Top-level `metrics: []` (sibling of `pages`) — stripped
- Column-level promotion flags (`isMetric: true`, `kind: "metric"`, etc.) — stripped
- `/v2/datamodels/{id}/metrics` endpoint — 404

Aggregate calc columns (`{id, formula: "Sum(...)", name, format}` inside `columns`) work too but land in the **Columns panel**, not Metrics. Use real metrics unless you specifically want a calc column.

### 4. Relationships are stored on the source-side element

```json
"relationships": [
  {
    "id": "rel-1",
    "targetElementId": "<target-element-id>",
    "keys": [{"sourceColumnId": "...", "targetColumnId": "..."}]
  }
]
```

The relationship lives on the **from** element (source side). Field names: `targetElementId` (not `toElementId`), `keys` (not `keyColumns`), `sourceColumnId`/`targetColumnId` (not `from`/`to`).

**Direction convention:** Use **fact → dim** unless told otherwise. The fact element has the relationships, each pointing outward to a dim. Sigma's UI renders this as a hub-and-spoke with the fact at center. (Some users prefer dim → fact for date-spine setups — confirm if unsure.)

### 5. Sigma formula functions ≠ SQL functions

These tripped up many builds. Sigma's formula language:

| Sigma | NOT |
|-------|-----|
| `Avg(x)` | `Average(x)` |
| `AvgIf(x, condition)` | `AverageIf(x, condition)` |
| `CountIf(condition)` (1 arg) | `CountIf(x, condition)` (SQL-style 2-arg) |
| `SumIf(x, condition)` (2 arg) | — |
| `In(x, 'a', 'b')` | `x IN ('a', 'b')` |
| `Concat(a, b, c)` | `a || b || c` |
| `IsNull(x)` | `x IS NULL` |
| `DateDiff('year', a, b)` | — |
| `Today()`, `Lower(x)`, `If(cond, then, else)` | — |

`DateOffset` returns a column with `type: "error"` — don't use it in data-model formulas. Time-intelligence (YoY, MoM) belongs at the workbook level.

### 6. Sigma auto-titles snake_case with stopwords lowercased

When you reference a warehouse column by friendly name, the title-casing treats certain words as stopwords and keeps them lowercase: `to`, `of`, `for`, `at`, etc.

- `prospect_to_member` → friendly name `Prospect to Member` (lowercase `to`)
- `is_online_signup` → `Is Online Signup` (`Is` capitalized — it's a verb, not a stopword)
- `member_number` → `Member Number`

If your metric formula references `[Prospect To Member]` (capital T), it fails with "Unknown name." Verify casing with `GET /v2/datamodels/{id}/columns` after creation.

### 7. Catalog discovery via micro-data-model probes

There's no public endpoint to list databases/schemas/tables. To verify a `warehouse-table` path resolves, POST a minimal single-element data model with the candidate path. Sigma returns either success or `"Source not found: warehouse table 'X.Y' on connection 'Z'"`. Delete with `DELETE /v2/files/{id}` afterward. Parallelize across many candidates. See [reference/build-template.py](reference/build-template.py) `probe_table()`.

### 8. MySQL `cte_max_recursion_depth = 1000` blocks naive date spines

A recursive CTE generating dates aborts at row 1001. For multi-year date spines, use a **cross-join digit table** instead:

```sql
SELECT DATE_ADD('2023-01-01', INTERVAL n DAY) AS date, ...
FROM (
  SELECT a.N + b.N*10 + c.N*100 + d.N*1000 AS n
  FROM (SELECT 0 N UNION ALL SELECT 1 UNION ALL ... UNION ALL SELECT 9) a,
       (SELECT 0 N UNION ALL ... UNION ALL SELECT 9) b,
       (SELECT 0 N UNION ALL ... UNION ALL SELECT 9) c,
       (SELECT 0 N UNION ALL ... UNION ALL SELECT 9) d
) t
WHERE DATE_ADD('2023-01-01', INTERVAL n DAY) <= '2027-12-31'
```

Full version in [reference/build-template.py](reference/build-template.py).

---

## Required workflow

### Step 0 — Authenticate
See the auth block at the top. Confirm with `curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" $SIGMA_BASE_URL/v2/whoami`.

### Step 1 — Pick the connection
```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" "$SIGMA_BASE_URL/v2/connections" \
  | python3 -c "import json,sys; [print(f\"{c['name']!r} ({c['type']}) id={c['connectionId']}\") for c in json.load(sys.stdin)['entries']]"
```

### Step 2 — Find or pick the target folder
Read an existing model's `folderId` (if the user already has data models in the right folder):
```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" "$SIGMA_BASE_URL/v2/files?limit=100" | python3 -m json.tool
```
Or use the user's "My Documents" folder via `GET /v2/whoami`.

### Step 3 — Verify table paths exist
Probe in parallel with micro-data-models (see `probe_table()` in the reference). If any fail, ask the user for the correct table names before building.

### Step 4 — Build the payload
Copy `reference/build-template.py` and customize the `MODEL` dict. The template handles:
- warehouse-table and SQL elements with correct formula prefixes
- Real metrics block at element level
- Relationships in fact → dim direction
- Calc columns alongside source columns (for things like Full Name = Concat(First, Last))

### Step 5 — POST and verify
```bash
RESP=$(curl -s -X POST "$SIGMA_BASE_URL/v2/datamodels/spec" \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" -H "Content-Type: application/json" \
  --data @payload.json)
DM_ID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['dataModelId'])")
echo "Created: $DM_ID"
```

Then validate every column resolved:
```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" "$SIGMA_BASE_URL/v2/datamodels/$DM_ID/columns" \
  | python3 -c "
import json,sys
data = json.load(sys.stdin)
errs = [c for c in data['entries'] if c.get('type',{}).get('type') == 'error']
if errs:
    print(f'{len(errs)} ERRORS:')
    for e in errs:
        print(f'  {e[\"name\"]!r}: {e[\"type\"][\"err\"]}  formula={e[\"formula\"]!r}')
else:
    print('✓ All columns resolve cleanly')"
```

If errors exist, PUT-update the spec with corrected formulas (don't delete+recreate — element IDs and assigned column IDs change, breaking any workbooks that reference them).

### Step 6 — Confirm metrics landed in the Metrics panel
```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" "$SIGMA_BASE_URL/v2/datamodels/$DM_ID/spec" \
  | python3 -c "
import json,sys
spec = json.load(sys.stdin)
for p in spec['pages']:
    for e in p['elements']:
        if e.get('metrics'):
            print(f\"{e['name']}: {len(e['metrics'])} metrics — {[m['name'] for m in e['metrics']]}\")"
```

---

## Endpoint reference

| Endpoint | Use |
|---|---|
| `POST /v2/datamodels/spec` | Create. Returns `{success, dataModelId}` |
| `GET /v2/datamodels/{id}/spec` | Full JSON spec (includes metrics, relationships) |
| `GET /v2/datamodels/{id}/spec?format=yaml` (with `Accept: application/yaml`) | YAML form — same nested schema as JSON |
| `GET /v2/datamodels/{id}/columns` | Flat resolved column list with types — use to detect formula errors |
| `GET /v2/datamodels/{id}/elements` | Element summary list with column names |
| `PUT /v2/datamodels/{id}/spec` | Full-replace update |
| `DELETE /v2/files/{id}` | Delete (data models are files) |

The path is `/v2/datamodels` (no hyphen) despite docs saying `/v2/data-models`. Both `/v2/datamodels` and `/v2/dataModels` (camelCase, used by sigcli) work.

---

## Common build pitfalls (in priority order)

1. **"Unknown name" on every SQL column** → using bare `[Column Name]` instead of `[Custom SQL/raw_col_name]`. See #2 above.
2. **Metrics not in Metrics panel** → putting them at top level or as column-level flags. They must be in `element.metrics: []`. See #3.
3. **"Invalid arg type" on CountIf** → using 2-arg SQL-style. Sigma's `CountIf` is 1-arg (just the condition). See #5.
4. **"Unknown function: Average"** → use `Avg`/`AvgIf`. See #5.
5. **"Unknown name [Prospect To Member]"** → capital `T` doesn't match Sigma's auto-titling (stopword lowercased). See #6.
6. **Date spine aborts at 1001 rows** → MySQL recursive CTE limit. Use cross-join digits. See #8.
7. **Top-level `metrics` block silently stripped** → must be element-level.
8. **Top-level `relationships` block silently stripped** → must be element-level on the source-side element.
9. **`SQL_IN` syntax rejected** → use Sigma's `In(col, 'a', 'b')` function.
10. **Source not found errors** → table name typo. Probe to confirm before building large models.

---

## Reference files

- [reference/build-template.py](reference/build-template.py) — copy-and-adapt Python builder. Defines tables, relationships, metrics declaratively; generates a valid POST payload. Includes the non-recursive date spine, table-path probing helper, and column-error inspector.
- [reference/example-yaml-as-code.yaml](reference/example-yaml-as-code.yaml) — example of the YAML "as-code" format users export (read-only — not the API format). Useful for translating user-supplied YAML to API JSON.

## When asked to convert a user's YAML to a working data model

1. Parse the YAML's `tables`, `metrics`, `relationships` blocks.
2. For each `tables[i]`:
   - Map `source.kind: warehouse-table` + `source.path: "DB.SCHEMA.TABLE"` → JSON `{kind: "warehouse-table", connectionId, path: ["DB","SCHEMA","TABLE"]}` (use 2-part for MySQL).
   - Map `source.kind: sql` + `source.sql` → JSON `{kind: "sql", connectionId, statement: <sql>}`. The `from` field is informational; drop it.
   - For each column, set `formula` based on source kind: warehouse-table uses `[<table>/<Display Name>]`, SQL uses `[Custom SQL/<raw_col_id>]` (use the `id` from the YAML, which is the SQL output name).
3. For each `metrics[i]`: attach to the named element's `metrics: []` block. Translate `format: "$,.0f"` → `{kind: "number", formatString: "$,.0f"}`.
4. For each `relationships[i]`: attach to the source-side element's `relationships: []` block. Translate `from`/`to` (table names) and key `from`/`to` (column display names) into element IDs and column IDs via lookups built during step 2.
5. POST. Then `GET /columns` to verify. Fix any errors via PUT.
