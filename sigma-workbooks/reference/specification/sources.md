# Sources (non-warehouse)

Recipe book for source kinds other than `warehouse-table`. For the canonical schema of any source kind, pull it by its `kind` value (`warehouse-table`, `sql`, `csv-table`, `table`, `data-model`, `metric-view`, `semantic-view`, `join`, `union`, `transpose`):

```bash
jq --arg k join 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

Every element with columns has a `source` that defines where its data comes from. This file focuses on the **patterns** and **formula-prefix conventions** for each non-warehouse source kind — the parts the OpenAPI alone won't teach.

**For warehouse-table** — the most common source — see the dedicated `sources-warehouse.md`. It's loaded by default because nearly every workbook uses it.

**For discovery** (finding connection IDs, paths, data model IDs, element IDs) see `reference/workflows/discover.md`.

---

## table (cross-element reference)

Sources another element in the same workbook. This is the most common source kind for charts, KPIs, and derived tables.

```yaml
kind: table
elementId: <id of another element on some page>
```

Column formulas reference that element's columns using its `name`:

- Element named "Sales Table" → `[Sales Table/Revenue]`

## data-model

References an element from an existing data model. **Prefer this source kind when the user's org has relevant data models** — it inherits the data model's joins, filters, and column-level security, which is usually closer to what the user wants than re-deriving from raw warehouse tables. Discover available models with `GET /v2/dataModels`; if none are relevant, fall back to `warehouse-table` rather than trying to manufacture a model.

```yaml
kind: data-model
dataModelId: <data-model-uuid>
elementId: <data-model element id>
```

**`elementId` is not a UUID** — verified live, it's an opaque short id (e.g. `QnTScgyIVd`) assigned by the data model, not something you can construct. Find it via `GET /v2/dataModels/<dataModelId>/spec` and read `pages[].elements[].id`.

Optionally add `groupingId` to apply one of the model element's groupings.

**A workbook element sourced on a data model element sees ONLY that element's own
columns.** Relationship traversal does *not* reach through: `[Dim - Debtor/Debtor Type]`
from an element sourced on a fact fails with `Dependency not found: 'dim - debtor/debtor
type'`, even though the model has the relationship. Dimension attributes must first be
added as columns **on the fact element in the model** (where traversal does work — see
below), and then the workbook can group by them. Data model *metrics* propagate fine as
`[Metrics/<name>]` without any of this.

Inside the data model, cross-element refs use the element **name** and column **name**:
`[Dim - Debtor/Debtor Type]` resolves; `[el-dim-debtor/Debtor Type]` (element id) and
`[Dim - Debtor/debtor_type]` (column id) both fail with `Unknown name`. An explicit
`Lookup([Dim - Debtor/Debtor Type], [Dim Debtor Sk], [Dim - Debtor/Dim Debtor Sk])` also
works but is unnecessary when a relationship exists.

⚠️ **`PUT /v2/datamodels/{id}/spec` does not validate formulas** — it returns 200 on
`[No Such Column Xyz]`. Verify with `GET /v2/datamodels/{id}/columns?limit=400` and check
each entry's `type`; a bad formula shows `{"type":"error","err":{"type":"Unknown name",…}}`.
The workbook spec endpoint *does* validate, which makes the asymmetry easy to forget.

**Needing a window function is not a reason to use custom SQL.** `PercentOfTotal`,
`GrandTotal`, `Subtotal`, `MovingSum`, `CumulativeSum`, `Lag`/`Lead`/`First`/`Last`/`Nth`,
`Rank*`, `Ntile`, `RegressionSlope`/`Intercept`/`R2`, `StdDev` and `PercentileCont` all
resolve against a `data-model` source — verified live. See `formulas.md`.

**Column formula prefix — verified live, undocumented elsewhere:** the prefix is the data model element's own `name` (not `dataModelId`, not `elementId`, not the data model's own name) — `[<data model element name>/<column name>]`, e.g. `[Orders/Order Key]` for an element named "Orders" with a column named "Order Key". The column's own `id` also resolves as a fallback (`[Orders/<column-id>]`), but prefer the friendly column `name`.

## metric-view / semantic-view

Two **connection sources** (like `warehouse-table`) that back an element with a data model's metric view or semantic view object, addressed by warehouse `path`:

```yaml
kind: metric-view # a data-model metric view
connectionId: <conn-uuid>
path: [DB, SCHEMA, METRIC_VIEW]
```

```yaml
kind: semantic-view # a data-model semantic view, pinned to a base logical table
connectionId: <conn-uuid>
path: [DB, SCHEMA, SEMANTIC_VIEW, BASE_TABLE] # the base table is the final path segment
```

Both are `{ kind, connectionId, path }`. A `semantic-view` pins its base logical table as the last `path` element.

## join

Joins multiple sources into one logical source via an array of `joins`. Each leg (`primarySource`, `left`, `right`) can be any source kind, so warehouse tables, other elements, and data-model elements can be joined interchangeably.

Only `joins` (with each entry's `left`, `right`, `columns`) is required. `primarySource` is optional — if omitted, Sigma infers it as the source that appears on the left of some join but never on the right. Each join's `name` (used as the formula prefix — `[<name>/column]`; defaults to the right source's name) and `joinType` (defaults to inner) are also optional.

```yaml
kind: join
name: Sales Star
primarySource:
  kind: warehouse-table
  connectionId: <conn-uuid>
  path: [DB, SCHEMA, F_POS]
joins:
  - name: Sales
    joinType: left-outer
    left:
      kind: warehouse-table
      connectionId: <conn-uuid>
      path: [DB, SCHEMA, F_POS]
    right:
      kind: warehouse-table
      connectionId: <conn-uuid>
      path: [DB, SCHEMA, F_SALES]
    columns:
      - left: "[Order Number]"
        right: "[Order Number]"
```

Each entry in a join's top-level `columns[]` is a join-key pair (`left`/`right`, with an optional `op` for non-equi joins) — a different shape from an element's `columns[]` (see below). Pull `joinType` values and the column-pair shape from the spec via the recipe at the top.

**Join keys require the exact canonical friendly name and fail at POST, not at verify — the same strict rule as any other prefixed reference** (see `formulas.md`'s prefixed-vs-bare distinction — join keys are always effectively prefixed, never bare). `columns[].left`/`.right` here are matched by strict exact-string equality. A raw or mis-cased key (`[O_CUSTKEY]` instead of `[O Custkey]`) rejects the whole `POST` immediately with `Column reference not found`, rather than compiling and surfacing the problem later via `verify-workbook.sh`.

**Column formula prefixes with joins** — see `formulas.md` for the full rules:

- Primary-source columns use the **join's top-level `name`**: `[Sales Star/Order Number]`
- Joined-table columns use the **join leg's `name`**: `[Sales/Cust Key]`
- Warehouse path segments are **not** used as prefixes inside a join.

## sql

A custom SQL query against a connection — `kind: sql` with `connectionId` + `statement`. Pull the shape from the spec via the recipe.

**Column formula prefix and casing are both unusual here — verified live, undocumented elsewhere in this skill:**

- **The prefix is always the literal string `Custom SQL`** — `[Custom SQL/<column>]` — regardless of the element's own `name`, the connection, or the statement. There's no `name` field on a `sql` source to set instead; adding one is silently ignored and the prefix stays `Custom SQL`.
- **Column names are the raw SQL alias, not the friendly-cased form** — the inverse of the general rule in `formulas.md`'s "Raw vs. Friendly Column Names". `[Custom SQL/order_month]` (your statement's actual `AS` alias) resolves; `[Custom SQL/Order Month]` (friendly-cased) does not, and fails the same way as any other bad prefixed reference (`Dependency not found`, immediate, at `POST`).
- The bare-reference leniency (POST succeeds, `Unknown column` shows up later in `verify-workbook.sh`) does **not** rescue a wrong guess here either — a `sql`-sourced column reference is always prefixed, never bare, so it's always in the strict, immediate-rejection path. Get the alias right from your own `SELECT ... AS <alias>` before writing the formula.
- **Control references (`[ControlId]`) inside the `statement` text now resolve** — previously a known gap for `sql` sources specifically, since fixed.

## csv-table

A `kind: table` element backed by a workbook-uploaded CSV. Unlike `warehouse-table`, there is no browsable `path` — `inodeId` is the only stable identifier for the uploaded file.

```yaml
source:
  kind: csv-table
  connectionId: <conn-uuid>
  inodeId: <inode-id>
```

Reading and referencing an existing CSV-backed table round-trips; **originating a new CSV upload through the spec API is not supported** — upload the CSV in the product first, then reference it by `inodeId`.

## transpose

Pivots a source's rows and columns. Needs a `source` (any source kind) plus a direction config — `row-to-column` (pivot wider) or `column-to-row` (unpivot longer), each with its own fields. Pull the per-direction shape from the spec via the recipe.

> **⚠️ Doesn't produce data on a workbook `table` (verified 2026-10-19).** `{kind: transpose, source: {kind: table, elementId}, direction: column-to-row, columnsToMerge, columnLabelForMergedColumns, columnLabelForValues}` verifies, creates and round-trips — but the element's query fails ("Could not get query") and it renders 0 rows / 0 columns. A `sql` inner source is rejected outright (`Invalid kind: "table"`). In the OpenAPI the transpose source appears under `repeated-container` and `single-row-container` sources. To unpivot, do it in the data model or in custom SQL.

## Element `columns[]` vs. join `columns[]`

Two unrelated things share the name. An element's `columns[]` is its **output columns** (each a `formula`); a join source's top-level `columns[]` is its **join keys** (`left`/`right` pairs). Don't conflate them.

## union

Combines two or more sources (`warehouse-table`, `table`, or `data-model`) into a single source whose columns are explicitly mapped via `matches[]`.

```yaml
kind: union
name: All Sales
sources:
  - kind: warehouse-table
    connectionId: <conn-uuid>
    path: [DB, SCHEMA, JULY_SALES]
  - kind: warehouse-table
    connectionId: <conn-uuid>
    path: [DB, SCHEMA, AUGUST_SALES]
matches:
  - outputColumnName: Order ID
    sourceColumns:
      - "[Order ID]" # column from the first source
      - "[Order ID]" # column from the second source
  - outputColumnName: Sales
    sourceColumns:
      - "[Sales]"
      - "[Sales]"
```

`sourceColumns` is an array aligned to `sources` — one entry per source, in order. `outputColumnName` becomes the column users see and the name your element formulas reference.

**Set `name` explicitly.** Formula prefixes for the consuming element use the union's `name`, e.g. `[All Sales/Order ID]`. If you omit `name`, Sigma assigns `"Union of N Sources"`; if your element also defines a column whose `name` matches an `outputColumnName`, a bare `[Order ID]` formula becomes a circular self-reference and the SQL fails to compile. See `formulas.md` > Union source.
