"""Template for building a Sigma data model via JSON spec API.

Copy and customize the MODEL dict at the bottom, then run:
    python3 build-template.py > payload.json
    curl -s -X POST "$SIGMA_BASE_URL/v2/datamodels/spec" \\
      -H "Authorization: Bearer $SIGMA_API_TOKEN" \\
      -H "Content-Type: application/json" \\
      --data @payload.json

Then verify with the validate_columns() function (or one-liner in SKILL.md Step 5).

Handles:
- warehouse-table elements (formula = [<last_path>/<Display>])
- SQL elements (formula = [Custom SQL/<raw_col>])
- Real metrics via element.metrics: []
- Relationships fact → dim (configurable)
- Calc columns (e.g., Concat for full_name)
- Non-recursive MySQL date spine
- Table-path probing for catalog discovery
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request


# =============================================================================
# Configuration — set these to match your environment
# =============================================================================
CONN_ID = os.environ.get("SIGMA_CONN_ID", "REPLACE_ME")
FOLDER_ID = os.environ.get("SIGMA_FOLDER_ID", "REPLACE_ME")
TOKEN = os.environ.get("SIGMA_API_TOKEN", "")
BASE = os.environ.get("SIGMA_BASE_URL", "https://aws-api.sigmacomputing.com")


# =============================================================================
# Reusable: non-recursive MySQL date spine
# Sidesteps cte_max_recursion_depth = 1000
# =============================================================================
DATE_SPINE_SQL_MYSQL = """SELECT
  DATE_ADD('2023-01-01', INTERVAL n DAY) AS date,
  CAST(DATE_FORMAT(DATE_ADD('2023-01-01', INTERVAL n DAY), '%Y-%m-01') AS DATE) AS month_start,
  EXTRACT(YEAR FROM DATE_ADD('2023-01-01', INTERVAL n DAY)) AS year_num,
  EXTRACT(MONTH FROM DATE_ADD('2023-01-01', INTERVAL n DAY)) AS month_num,
  DAYNAME(DATE_ADD('2023-01-01', INTERVAL n DAY)) AS day_of_week,
  ((MOD(EXTRACT(MONTH FROM DATE_ADD('2023-01-01', INTERVAL n DAY)) - 1, 3)) + 1) AS month_in_quarter,
  CEIL(EXTRACT(MONTH FROM DATE_ADD('2023-01-01', INTERVAL n DAY)) / 3.0) AS quarter_num,
  CASE WHEN DATE_ADD('2023-01-01', INTERVAL n DAY) = CURRENT_DATE THEN 'Y' ELSE 'N' END AS is_today
FROM (
  SELECT a.N + b.N*10 + c.N*100 + d.N*1000 AS n
  FROM (SELECT 0 N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a,
       (SELECT 0 N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b,
       (SELECT 0 N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c,
       (SELECT 0 N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d
) t
WHERE DATE_ADD('2023-01-01', INTERVAL n DAY) <= '2027-12-31'
ORDER BY date"""

DATE_SPINE_COLS = [
    ("date", "Date"),
    ("month_start", "Month Start"),
    ("year_num", "Year"),
    ("month_num", "Month"),
    ("day_of_week", "Day of Week"),
    ("month_in_quarter", "Month in Quarter"),
    ("quarter_num", "Quarter"),
    ("is_today", "Is Today"),
]


# =============================================================================
# Helpers
# =============================================================================
def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def wh(name, schema, table, cols, extra_calc=None):
    """warehouse-table element.

    cols: {warehouse_col_name: display_name}
    extra_calc: [(display_name, formula)] — Sigma formulas, e.g. Concat([First], ' ', [Last])
    """
    return {
        "name": name,
        "source_kind": "warehouse-table",
        "source": {"kind": "warehouse-table", "connectionId": CONN_ID, "path": [schema, table]},
        "warehouse_col_to_display": cols,
        "extra_calc": extra_calc or [],
    }


def sql_table(name, statement, cols, extra_calc=None):
    """SQL element. cols: [(sql_output_name, display_name)]."""
    return {
        "name": name,
        "source_kind": "sql",
        "source": {"kind": "sql", "connectionId": CONN_ID, "statement": statement},
        "sql_col_to_display": cols,
        "extra_calc": extra_calc or [],
    }


def date_spine(name="Dim - Date Spine"):
    return sql_table(name, DATE_SPINE_SQL_MYSQL, DATE_SPINE_COLS)


def build_payload(model):
    """Convert MODEL dict → POST-ready JSON payload."""
    elements = []
    table_to_element_id = {}
    table_to_column_lookup = {}  # table_name → {display_name → column_id}

    for t in model["tables"]:
        elem_id = "el-" + slug(t["name"])
        table_to_element_id[t["name"]] = elem_id
        columns, order, col_lookup = [], [], {}

        if t["source_kind"] == "warehouse-table":
            ref = t["source"]["path"][-1]  # last component, e.g. "v_members"
            for warehouse_col, display in t["warehouse_col_to_display"].items():
                col_id = f"{elem_id}/{warehouse_col}"
                columns.append({"id": col_id, "formula": f"[{ref}/{display}]", "name": display})
                order.append(col_id)
                col_lookup[display] = col_id
        else:  # sql
            for sql_col, display in t["sql_col_to_display"]:
                col_id = f"{elem_id}/{sql_col}"
                # ★ The literal "Custom SQL" prefix is REQUIRED for SQL element formulas
                columns.append({"id": col_id, "formula": f"[Custom SQL/{sql_col}]", "name": display})
                order.append(col_id)
                col_lookup[display] = col_id

        # Extra calc columns (e.g., Full Name = Concat(...))
        for display, formula in t.get("extra_calc", []):
            col_id = f"{elem_id}/calc-{slug(display)}"
            columns.append({"id": col_id, "formula": formula, "name": display})
            order.append(col_id)
            col_lookup[display] = col_id

        table_to_column_lookup[t["name"]] = col_lookup

        # Real metrics (Metrics panel) — element-level only
        metrics = []
        for mt, mname, mformula, mfmt in model.get("metrics", []):
            if mt == t["name"]:
                metrics.append({
                    "id": f"metric-{slug(mname)}",
                    "formula": mformula,
                    "name": mname,
                    "format": {"kind": "number", "formatString": mfmt},
                })

        el = {
            "id": elem_id, "kind": "table", "name": t["name"],
            "source": t["source"], "columns": columns, "order": order,
        }
        if metrics:
            el["metrics"] = metrics
        elements.append(el)

    # Relationships go on the SOURCE element (the "from" side)
    rels_by_source = {}
    for i, (from_tbl, to_tbl, keys) in enumerate(model.get("relationships", [])):
        from_el = table_to_element_id[from_tbl]
        rel = {
            "id": f"rel-{slug(model['name'])}-{i+1}",
            "targetElementId": table_to_element_id[to_tbl],
            "keys": [
                {
                    "sourceColumnId": table_to_column_lookup[from_tbl][fk],
                    "targetColumnId": table_to_column_lookup[to_tbl][tk],
                }
                for fk, tk in keys
            ],
        }
        rels_by_source.setdefault(from_el, []).append(rel)

    for el in elements:
        if rels_by_source.get(el["id"]):
            el["relationships"] = rels_by_source[el["id"]]

    return {
        "folderId": FOLDER_ID,
        "name": model["name"],
        "schemaVersion": 1,
        "pages": [{
            "id": slug(model["name"]) + "-page",
            "name": model["name"],
            "elements": elements,
        }],
    }


# =============================================================================
# Validation / probing helpers
# =============================================================================
def validate_columns(data_model_id):
    """Print column errors for an existing data model. Run after POST."""
    req = urllib.request.Request(
        f"{BASE}/v2/datamodels/{data_model_id}/columns",
        headers={"Authorization": f"Bearer {TOKEN}"},
    )
    data = json.loads(urllib.request.urlopen(req).read())
    errs = [c for c in data["entries"] if c.get("type", {}).get("type") == "error"]
    if errs:
        print(f"{len(errs)} ERRORS:")
        for e in errs:
            err = e["type"]["err"]
            print(f"  {e.get('name', '?')!r}: {err.get('type')}: {err.get('name', '')}  formula={e.get('formula', '?')!r}")
        return False
    print("✓ All columns resolve cleanly")
    return True


def probe_table(schema, table, label=None):
    """Probe whether a warehouse table path resolves. Creates and deletes a micro data model.

    Returns True if the path exists, False otherwise. Print-friendly.
    """
    import uuid

    payload = {
        "folderId": FOLDER_ID,
        "name": f"probe-{(label or table)}-{uuid.uuid4().hex[:6]}",
        "schemaVersion": 1,
        "pages": [{
            "id": "p1", "name": "P",
            "elements": [{
                "id": "e1", "kind": "table",
                "source": {"kind": "warehouse-table", "connectionId": CONN_ID, "path": [schema, table]},
                "columns": [], "order": [],
            }],
        }],
    }
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"{BASE}/v2/datamodels/spec", data=json.dumps(payload).encode(),
            headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
            method="POST",
        ))
        new_id = json.loads(r.read())["dataModelId"]
        # Cleanup
        urllib.request.urlopen(urllib.request.Request(
            f"{BASE}/v2/files/{new_id}",
            headers={"Authorization": f"Bearer {TOKEN}"}, method="DELETE",
        ))
        print(f"  ✓ {schema}.{table}")
        return True
    except urllib.error.HTTPError as e:
        err = json.loads(e.read()).get("errors", [{}])[0].get("summary", "?")
        print(f"  ✗ {schema}.{table}  {err}")
        return False


# =============================================================================
# YOUR MODEL — customize below
# =============================================================================
MODEL = {
    "name": "My Data Model",
    "tables": [
        wh("Fct - Sales", "MY_SCHEMA", "sales_fact", {
            "sale_id": "Sale Id",
            "customer_id": "Customer Id",
            "amount": "Amount",
            "sale_date": "Sale Date",
        }),
        date_spine(),
        wh("Dim - Customers", "MY_SCHEMA", "customers", {
            "customer_id": "Customer Id",
            "name": "Name",
            "region_id": "Region Id",
        }, extra_calc=[("Full Name", "Concat([First Name], ' ', [Last Name])")]),
    ],
    # relationships: from FACT → to DIM (typical convention)
    "relationships": [
        ("Fct - Sales", "Dim - Date Spine", [("Sale Date", "Date")]),
        ("Fct - Sales", "Dim - Customers", [("Customer Id", "Customer Id")]),
    ],
    # Real Metrics-panel metrics: (table_name, metric_name, sigma_formula, d3_format_string)
    "metrics": [
        ("Fct - Sales", "Total Revenue", "Sum([Amount])", "$,.0f"),
        ("Fct - Sales", "Avg Sale", "Avg([Amount])", "$,.2f"),
        ("Fct - Sales", "Sales Count", "Count([Sale Id])", ",.0f"),
        ("Fct - Sales", "Big Sales Count", "CountIf([Amount] > 1000)", ",.0f"),
    ],
}


if __name__ == "__main__":
    print(json.dumps(build_payload(MODEL), indent=2))
