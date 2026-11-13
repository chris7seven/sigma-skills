# Tables

Recipe book for `table`, `pivot-table`, and `input-table` elements + style and trap guidance. The full schemas live in the OpenAPI — fetch any element kind by its `kind` value:

```bash
jq --arg k pivot-table 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

Swap `pivot-table` for `table` or `input-table` to inspect the others.

The `table` element is the most common element kind and the primary way data enters a workbook — charts, KPIs, and other elements usually point their `source` at a table.

## Basic shape

```yaml
id: sales-table
kind: table
name: Sales Data
source:
  kind: warehouse-table
  connectionId: <conn-uuid>
  path: [DATABASE, SCHEMA, TABLE]
columns:
  - id: col-1
    name: Column Name
    formula: "[TABLE/column_name]"
  - id: col-2
    name: Total
    formula: Sum([Column Name])
order: [col-1, col-2]
```

See `sources.md` for all source kinds and `formulas.md` for the column-reference rules. Every column needs `id`, `name`, `formula`; optional `format` (see `formatting.md`).

For the `table` kind, `name` is a plain string. The styled title-section object (with `text`, styling, and `noDataText`) applies to `pivot-table` and `input-table` — see those sections below.

## Common optional fields

### `order`

Array of column IDs controlling left-to-right display order. Defaults to declaration order.

### `groupings`

Pivot / aggregation views without changing element kind:

```yaml
groupings:
  - id: by-region
    groupBy: [col-region]
    calculations: [col-total, col-profit]
```

Each `groupings[]` entry is one grouping *level*. A calculation column can appear in at most one level's `calculations[]` — reusing the same column across two levels (e.g. grouping by both region and nation, each listing the same revenue column) is rejected at POST with `Duplicate column or folder reference`. For a two-level rollup, use one entry with a compound `groupBy` (`groupBy: [col-region, col-nation]`) rather than two separate entries.

**The table's top-level `sort: [{ columnId, direction }]` field can't sort by anything inside a `groupings[]` entry** — a `groupBy` or `calculations` column rejects with `Sort column not found`, since grouped columns live at a different level than the ungrouped ("base") columns `sort` resolves against. See `reference/workflows/composition.md`'s sort-ranked-tables note for the workaround (sort a companion chart instead).

### `filters` (top-N, element-level row filters)

```yaml
filters:
  - id: top-20
    columnId: col-revenue
    kind: top-n
    rankingFunction: rank
    mode: top-n
    rowCount: 20
    includeNulls: when-no-value-is-selected
```

> **`rowCount` takes a number literal only** — it cannot be parametrized by a control. `rowCount: "[TopN]"` is rejected. Control bindings apply to filter **values**, not to structural fields like `rowCount`, `rankingFunction`, `mode`, or `kind`. To vary the cap interactively, duplicate the element per cap.

> `conditionalFormats` works on `table`, `pivot-table` and `input-table` (verified 2026-10-19: verify, create and GET round-trip on all three). The wrong *shape* is what gets rejected — `kind: single-color` returns the masked `Invalid kind: "table"`; use `type: single` (see below).

### `frozenColumn` (table and pivot-table)

Freezes columns up to and including the named one so they stay put while the rest scroll horizontally.

```yaml
frozenColumn:
  columnId: col-region
  # pivot-table only: also freeze at a specific field value
  # fieldValues: [...]
```

> Pass `frozenColumn: null` on write to unfreeze; **omit** the field to leave the current freeze unchanged.

### `columns[].image` (table and pivot-table)

Render a **text** column's values as images (Transform > Set image). Only text columns accept it.

```yaml
columns:
  - id: col-logo
    name: Logo
    formula: "[TABLE/logo_url]"
    image:
      type: fixed # `fixed` (with optional height/width) or `original`
      height: 32
      width: 32
      preserveAspectRatio: preserve # fixed only: `preserve` | `stretch`
```

> Pass `image: null` to clear; **omit** to leave unchanged.

### `tableStyle.textStyles.rowHeader` / `columnHeader`

The Subheader tab — style row-header and column-header text. `tableStyle.textStyles` carries `rowHeader` and `columnHeader` style blocks (applies to `pivot-table` / `input-table`). Fetch the full `tableStyle` shape with the `kind`-form recipe at the top.

---

# Pivot tables

The `pivot-table` element is a sibling of `table` for cross-tab analysis — measure cells aggregated across one or more row/column dimensions.

## Shape

```yaml
id: deployments-pivot
kind: pivot-table
name: Deployments by cloud and env
source:
  kind: table
  elementId: deployments-source
columns:
  - id: piv-cloud
    name: Cloud
    formula: "[Deployments/Cloud]"
  - id: piv-env
    name: Environment
    formula: "[Deployments/Environment]"
  - id: piv-count
    name: Deployments
    formula: CountDistinct([Deployments/Deployment UUID])
    format:
      kind: number
      formatString: ",.0f"
values: [piv-count]
rowsBy:
  - id: piv-cloud
columnsBy:
  - id: piv-env
    sort:
      direction: descending
```

`values` (required) is the measure column array — the cells of the pivot. `rowsBy` and `columnsBy` place dimension columns explicitly on the row and column shelves; each item is `{ id, sort? }`, where `sort` is `{ direction: ascending | descending, by?, aggregation? }` (`by` can be a column ID or `"row-count"`). Columns not listed on either shelf still render as available dimensions.

## `display` — layout and column widths

Optional `display` object controlling pivot layout and resized widths (all fields optional; omit blocks that aren't configured):

```yaml
display:
  stacked: false
  showLabels: true
  rowLayout: compact # layout of the row-label area
  measureShelfPosition: columns # where the measure shelf sits
  headerWidths:
    uniformWidth: 120 # after a bulk resize — mutually exclusive with `columns`
    measureLabelWidth: 80
    # columns: [{ ... per-field widths ... }]
  bodyWidths:
    uniformWidth: 100
    # columns: [{ ... per-field widths ... }]
```

> `uniformWidth` (set by a bulk resize) and per-field `columns` are mutually exclusive within a `headerWidths` / `bodyWidths` block.

## `adhocCalcs` — row-axis ad hoc calculations

Array of ad hoc calculation rows on the **row** axis (column-shelf ad hoc calcs aren't supported on the wire). Each row: `id`, `name`, `inColumn`, `position`, `value`, `in`, optional `anchorRow`, and per-value `calculations`.

```yaml
adhocCalcs:
  - id: pct-of-total
    name: "% of total"
    inColumn: piv-count
    position: after
    value: percent-of-total
    in: column
```

## `filters`

Pivot tables take `filters` using the same `ColumnFilter` shape as level tables and charts (list, number-range, date-range, top-n, text-match, hierarchy) — see the `filters` example in the table section.

## `conditionalFormats` — threshold coloring on cells

Available on `table`, `pivot-table` and `input-table`. Apply background/text styling per cell based on column values. Variants include `single`, `backgroundScale`, `fontScale`, and `dataBars` — covering threshold rules, gradient scales, font-color scales, and inline data bars. Inspect the OpenAPI for the full operator + style enums (use the `conditionalFormats` property on either kind's schema).

**Recipe — red/green threshold coloring on a revenue column:**

```yaml
conditionalFormats:
  - type: single
    columnIds: [col-revenue]
    condition: ">"
    value: 1000
    style:
      backgroundColor: "#22c55e"
  - type: single
    columnIds: [col-revenue]
    condition: "<"
    value: 100
    style:
      backgroundColor: "#ef4444"
```

Condition operators include `=`, `!=`, `>`, `>=`, `<`, `<=`, `IsNull`, `IsNotNull`, `Contains`, `NotContains`, `StartsWith`, `EndsWith`, `Between`, `NotBetween`, and `formula` (arbitrary boolean). Style block supports `backgroundColor`, `color`, `bold`, `italic`, `underline`, and column-level `format` override.

---

# Input tables

The `input-table` element is an editable, warehouse-backed grid — users type values directly into cells. Required fields: `id`, `kind`, `source`, `inputMode`. It reuses the display surface documented above (styled title-section `name`/`noDataText`, `filters`, `conditionalFormats`, `sort`, `summary`, `tableStyle`, `frozenColumn`, column `image`).

**See [`input-tables.md`](./input-tables.md) for the full recipe** — the `inputMode` values, the `source` variants (empty vs linked), the column-kind union (system / key / editable / formula), column validation (`values` / `valuesFrom` / `range` / `pills` / `multi-select`), and file-upload columns.
