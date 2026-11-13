# Sigma Formula Reference

This is the highest-traffic reference file — Sigma's formula DSL is the largest source of spec errors and the OpenAPI doesn't fully describe its semantics. Treat this as the source of truth for the **formula language itself** (syntax, qualification, operator behavior). Field-level shape (where formulas appear in the spec) is in the OpenAPI per-element schemas.

## ⚠️ READ FIRST: The #1 Formula Mistake

When an element sources another element (e.g., a KPI or chart sourcing a table), **every column reference inside aggregations must include the source element's name as a prefix.** Forgetting the prefix is the single most common Sigma spec error.

**Wrong:**
```yaml
kind: kpi-chart
source: { kind: table, elementId: usage-table }
columns:
  - name: Total
    formula: Count([Question ID])
```

**Right:**
```yaml
kind: kpi-chart
source: { kind: table, elementId: usage-table }
columns:
  - name: Total
    formula: Count([AI Usage Data/Question ID])
```

**Why:** a bare `[column_name]` means *defined in THIS element's own `columns[]` array* — not *visible through the source*. SQL intuition leaks here: `Count([col])` feels local because the source "is" the table, but Sigma's formula language requires you to name the source explicitly.

**Rule of thumb:** if your element's `source` points at another element (or a warehouse table, or a join), 90%+ of your formulas will start with `[<SourceName>/...]`. Bare refs are only for columns you literally defined a line or two above in the same `columns[]` array.

Before publishing, run `./scripts/validate-spec.sh <spec.yaml>` — it catches exactly this mistake.

---

## ⚠️ READ SECOND: Raw vs. Friendly Column Names

Sigma's formula DSL references columns by their **friendly name**, not their raw warehouse name. The two diverge in two ways:

1. **Special characters** — `/`, `-`, `.`, `[`, `]`, and leading/trailing whitespace are stripped or replaced.
2. **Casing and word boundaries** — `ALL_CAPS_WITH_UNDERSCORES` is title-cased and underscores become spaces; `camelCase` is split on case boundaries.

Examples observed on real Sigma instances:

| Raw warehouse name | Friendly name used in formulas |
|---|---|
| `DATE` | `Date` |
| `UNIT PRICE` | `Unit Price` |
| `ORDER_ID` | `Order ID` |
| `V userId` | `V User Id` |
| `Net/Gross` | `Net Gross` |

The trap: `GET /v2/connections/tables/{inodeId}/columns` returns **raw warehouse names** (`DATE`, `V userId`). Formulas written against those raw names will silently fail to resolve if you get the friendly-name conversion wrong — and it matters a lot *which kind* of reference you got wrong, because the two behave completely differently:

**A *prefixed* reference (`[SourceName/column]`) is validated strictly and immediately at `POST` — verified live, not deferred.** This is the common case: per "READ FIRST" above, 90%+ of formulas are prefixed, whether pointing at a warehouse table's raw column or another element's column. A bad guess anywhere in a prefixed reference fails the *entire request* immediately with `elements[N]: Dependency not found: '<source>/<column>'` — the workbook is never created, so there is no "POST your best guess, then check `verify-workbook.sh`" loop to run; there's nothing to verify. Get the friendly name right *before* POSTing:

1. Convert `ALL_CAPS_WITH_UNDERSCORES` to the canonical friendly form yourself — title-case each underscore-separated word, underscores become spaces (`ORDER_ID` → `Order ID`). Don't rely on auto-normalization to save you; it covers some simple cases (`[ORDERS/DATE]` → `[ORDERS/Date]`) but not everything in the table above.
2. If you're not confident in the guess, probe before you build the real spec: POST a throwaway element declaring your candidate names as columns. A bad name fails the whole POST immediately, naming the exact bad reference — drop that one candidate from the batch and retry the rest, rather than falling back to one-at-a-time. See `reference/workflows/discover.md` for the full probe-and-bisect pattern.
3. Once a probe POST succeeds, `GET` the workbook's spec back — Sigma's readback shows the canonical friendly names it actually resolved against. Use those in your real spec, then delete the probe workbook.

**A *bare*, unprefixed `[ColumnName]` reference is the one case that's actually lenient.** It means "a column declared elsewhere in this same element's own `columns[]` array" (see "READ FIRST" above) — and if that name doesn't match any declared column, `POST` still succeeds; the mismatch defers to query time and surfaces as `'Unknown column "[X]"'` in the compiled SQL, catchable with `./scripts/verify-workbook.sh <workbookId>`. Don't confuse this narrower case with the prefixed case above — they have opposite failure behavior, and the prefixed case is the one you'll hit far more often.

**Join keys follow the same strict, immediate rule as any other prefixed reference — verified live, no special case.** A `join` source's `joins[].columns[].left`/`.right` (the columns you're joining on — see `sources.md`) are matched by exact string equality against the friendly name: a raw or mis-cased join key fails immediately at `POST` with `Column reference not found: '[X]'`. Convert `ALL_CAPS_WITH_UNDERSCORES` to the canonical friendly form yourself before writing a join key (`O_CUSTKEY` → `O Custkey`, `C_NATIONKEY` → `C Nationkey`) — same conversion as step 1 above.

Wrong: `[ORDERS/Net/Gross Revenue]` (slash inside a column name; unparseable)
Wrong: `[ORDERS/Order-ID]` (raw warehouse name with a dash)
Wrong: `[ORDERS/ORDER_ID]` (raw underscore form; usually needs `Order ID`)
Right: `[ORDERS/Net Gross Revenue]` (friendly name)
Right: `[ORDERS/Order ID]` (friendly name)

---

## Column Reference Rules

Every column formula references either a column **outside** the element or a column **inside** the same element.

### Outside the element — use `[SourceName/column_name]`

The prefix depends on the source type:

- **Warehouse table**: `SourceName` = last segment of the `path` array.
  - Path `["DB", "SCHEMA", "ORDERS"]` → `[ORDERS/revenue]`
  - Path `["ANALYTICS", "PUBLIC", "USERS"]` → `[USERS/email]`

- **Another workbook element**: `SourceName` = that element's `name` field.
  - Element named "Sales Table" → `[Sales Table/Revenue]`

- **Join source**: `SourceName` = the `name` field on a specific join leg, or the top-level `name` on the join object (for the `primarySource` leg).
  - Join with `primarySource` implicitly tied to top-level `name: "Sales Star"` → `[Sales Star/Order Number]` for primary columns.
  - Join leg with `name: "Sales"` → `[Sales/Cust Key]` for that joined table's columns.
  - Warehouse path segments do **not** become the prefix inside a join — use the join leg's `name` instead.

- **`sql` (custom SQL) source**: `SourceName` is always the literal string `Custom SQL`, and the column name is the **raw SQL alias**, not friendly-cased — the inverse of the casing rule below. See `sources.md`'s `sql` section for the full detail; this is the one source kind where guessing the friendly-cased form actively fails.

- **`data-model` source**: `SourceName` = the data model element's own `name` (not the data model's name, not `elementId`). See `sources.md`'s `data-model` section — this is the skill's *recommended* source kind when a relevant model exists, so don't skip it because it looks like a rare case.

- **Union source**: `SourceName` = the union's `name` field. References resolve against the union's `matches[].outputColumnName` values, not the underlying tables' columns.
  - Union with `name: "All Sales"` → `[All Sales/Order Number]`.
  - If you omit `name`, Sigma assigns `"Union of N Sources"`; **a bare reference like `[Order Number]` to a column the consuming element also defines named `Order Number` is a circular reference and the SQL won't compile.** Set the `name` explicitly to avoid this.

- Column names must match exactly what the describe endpoint returns. **Never invent column names.**

### Inside the same element — use `[column_name]` (no prefix)

References a column already defined in this element by its `name` field.

```
// Given columns: "Revenue" (formula: [ORDERS/revenue]), "Cost" (formula: [ORDERS/cost])
// A third column can reference them:
[Revenue] - [Cost]       // valid — references sibling columns by name
Sum([Revenue])           // valid — aggregation over a sibling column
```

**A column cannot reference itself** — that is a circular reference error. This trips up copy-paste: if a column's `name` field matches any bracketed reference inside its own `formula`, the server treats it as circular even when you meant to reference a different column. Rename one side to break the cycle.

### Common mistakes

| Wrong | Correct | Why |
|-------|---------|-----|
| `[revenue]` | `[ORDERS/revenue]` | Missing table prefix for warehouse column |
| `[ORDERS/Total Revenue]` | `[Total Revenue]` | "Total Revenue" is a sibling column, not a warehouse column |
| `[Revenue]` in the "Revenue" column | Rename one side | A column cannot reference itself |
| `Count([Question ID])` on a sourced element | `Count([AI Usage Data/Question ID])` | Aggregation argument needs the source prefix |

## Operators

### Arithmetic
`+`, `-`, `*`, `/`, `%` (modulo), `^` (power)

**Do not use** `Power()` or `Mod()` — use `^` and `%` instead.

### Boolean
`and`, `or`, `not` are **prefix/infix operators, not function calls** — always put a space before the operand.

```
Wrong: Not(Contains([Deployment], "staging"))       // parses, but every row is null
Right: Not (Contains([Deployment], "staging"))      // space after Not

Wrong: And([Active], [Paid])                         // not a function
Right: [Active] And [Paid]                           // infix

Wrong: Or([Trial], [Free])                           // not a function
Right: [Trial] Or [Free]                             // infix

Right: Not [Active]
Right: [A] And Not [B]
Right: ([Status] = "Active") And ([Plan] = "Pro")
```

The trap: `Not(...)` parses successfully (the parens become grouping), so the failure is silent — null rows, no error. Easy to get wrong by analogy with `Sum([X])` / `If(...)`.

### String concatenation
`&` (not `+`)

**Do not use** `Concat()` — use `&` instead.

## Aggregation Functions

| Function | Description |
|----------|-------------|
| `Sum([col])` | Sum of values |
| `Avg([col])` | Average of values |
| `Count([col])` | Count of non-null values |
| `CountDistinct([col])` | Count of distinct values |
| `Min([col])` | Minimum value |
| `Max([col])` | Maximum value |
| `Median([col])` | Median value |

## Date Functions

| Function | Example |
|----------|---------|
| `DateTrunc(<part>, <date>)` | `DateTrunc("month", [Date])` |
| `DateDiff(<part>, <start>, <end>)` | `DateDiff("day", [Start], [End])` |
| `DateAdd(<part>, <units>, <date>)` | `DateAdd("month", 3, [Date])` |
| `DateFormat(<date>, <fmt>)` | `DateFormat([Date], "%Y-%m-%d")` |

Date parts (must be quoted strings): `"year"`, `"quarter"`, `"month"`, `"week"`, `"day"`, `"hour"`, `"minute"`, `"second"`

## Conditional

```
If(<condition>, <then>, <else>)
```

Supports multiple conditions (chained):
```
If([Status] = "Active", "Active", [Status] = "Pending", "Pending", "Other")
```

**Do not use** `Case` — use `If` instead.

## Text Functions

| Function | Description |
|----------|-------------|
| `Contains(<text>, <search>)` | True if text contains search |
| `Left(<text>, <n>)` | First n characters |
| `Right(<text>, <n>)` | Last n characters |
| `Upper(<text>)` | Uppercase |
| `Lower(<text>)` | Lowercase |
| `Trim(<text>)` | Remove leading/trailing whitespace |
| `Length(<text>)` | Character count |
| `Replace(<text>, <old>, <new>)` | Replace occurrences |

## JSON / Struct Field Access

Columns containing JSON or struct data (common for event payload / metadata columns) support **field access via dot notation** on the bracketed column reference. The extracted value is untyped — wrap it in the appropriate type constructor (`Text`, `Number`, `Date`) to coerce before passing it to downstream functions.

```
Text([Langfuse Metadata].agentId)           // extracts agentId as text
Text([Event Payload].user.id)               // nested access
Number([Event Payload].latency_ms)          // numeric cast
Text([Organizations].users[0])              // array index — first element
Text([Organizations].users[0].email)        // index + nested field
```

Without the wrapping cast, comparisons (`=`, `<`), aggregations (`Count`, `CountDistinct`), and text ops (`Contains`, concatenation with `&`) will often behave unexpectedly or fail silently — the extracted value keeps its variant/untyped flavor. If a JSON-derived formula appears to return `null` or mismatched values for every row, check that it's wrapped in `Text()` / `Number()` first.

Dot notation goes directly on the `]` — no space: `[Col].field`, not `[Col] .field`.

## Other Functions

| Function | Description |
|----------|-------------|
| `Coalesce(<a>, <b>, ...)` | First non-null value |
| `In([col], "a", "b", "c")` | True if value is in the list |
| `IsNull([col])` | True if null |
| `Null` | Null literal |

## Window Functions

> **The authoritative list is <https://help.sigmacomputing.com/docs/function-index>.**
> Fetch it before concluding a capability is missing. Each function has its own doc
> page with the exact signature. The tables below were verified live 2026-09-15
> (`POST /v2/workbooks/spec` resolves formulas and rejects bad ones, so a passing
> spec write is real evidence) but the index is what to trust.

**Do not reason from a missing name to a missing capability.** `Total()` and
`TotalOverAll()` genuinely don't exist — but window *totals* do, as `GrandTotal` /
`Subtotal` / `PercentOfTotal`. Concluding "Sigma can't do percent-of-total" from the
absence of `Total()` once caused nine workbook elements to be built as raw custom SQL
alongside an unused data model. Check the index.

| Category | Functions |
|---|---|
| Cumulative | `CumulativeSum`, `CumulativeAvg`, `CumulativeCount`, `CumulativeMin`, `CumulativeMax`, `CumulativeStdDev`, `CumulativeVariance`, `CumulativeCorr`, `CumeDist` |
| Moving | `MovingSum`, `MovingAvg`, `MovingCount`, `MovingMin`, `MovingMax`, `MovingStdDev`, `MovingVariance`, `MovingCorr` |
| Shifting | `Lag`, `Lead`, `First`, `Last`, `Nth`, `FillDown`, `FirstNonNull`, `LastNonNull` |
| Ranking | `Rank`, `RankDense`, `RankPercentile`, `RowNumber`, `Ntile`, `VisibilityLimit` |

`MovingSum([col], above, below)` — `above` is how many rows back to start (required),
`below` how many forward to end (optional, defaults `0` = current row). Negative
`below` is legal: `MovingSum([Weekly Sales], 8, -4)`. There is **no** partition or
order-by argument — the window follows the element's own sort and grouping.

`RunningSum` / `RunningAvg` are **not** the documented names; use `CumulativeSum` /
`CumulativeAvg`.

## Totals, shares and distribution

These are *aggregate* functions, not window functions, but they're what people reach
for when they want a window total:

| Function | Notes |
|---|---|
| `GrandTotal(<agg>)` | Shorthand for `Subtotal(<agg>, "grand_total")` |
| `Subtotal(<agg>, <mode>)` | Total at a chosen level |
| `PercentOfTotal(<agg>, <mode>, <params>)` | Share of a total — replaces `SUM() OVER ()` |
| `PercentileCont` / `PercentileDisc` | Continuous / discrete percentile |
| `RegressionSlope(y, x)` / `RegressionIntercept` / `RegressionR2` | Trendline **and** a modelled error term for a real confidence band |
| `StdDev`, `Variance`, `VariancePop`, `Median`, `Corr`, `SumProduct` | |
| `SumIf`, `AvgIf`, `CountIf`, `CountDistinctIf`, `MinIf`, `MaxIf` | Conditional aggregates |
| `ListAgg`, `ListAggDistinct`, `ArrayAgg`, `ArrayAggDistinct` | |

`PercentOfTotal`'s `mode` is `"grand_total"` (default), `"parent_grouping"`,
`"column"`, `"row"`, `"column_parent"`, `"row_parent"`, `"x_axis"`, `"color"`,
`"trellis_column"`, `"trellis_row"`. Use `"parent_grouping"` for a share *within*
each group — that's the one that replaces a partitioned `SUM() OVER (PARTITION BY …)`.
The third argument says how many parent levels to skip for the `*_parent` modes.

```
PercentOfTotal(Sum([Quantity]), "grand_total")
Divide(Sum([Open Amount]), GrandTotal(Sum([Open Amount])))   // equivalent, explicit
```

Both of these, and every function in the tables above, resolve against a
`data-model` source — so needing a window function is **not** a reason to drop to
custom SQL. See `sources.md`.
