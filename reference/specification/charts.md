# Charts

Chart elements: `line-chart`, `bar-chart`, `donut-chart`. This file is a **recipe book** for chart specs and the style choices that go with each kind. The OpenAPI is the source of truth for every field — chart schemas are inlined behind their `kind` discriminator, so fetch one by its kind:

```bash
# Swap `bar-chart` for any kind: line-chart, area-chart, combo-chart, scatter-chart, donut-chart, pie-chart, waterfall-chart
jq --arg k bar-chart 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

The field lists below are curated, not exhaustive — use the recipe above to discover the full shape of any field.

All three share the same skeleton: a `source`, a `columns` array, and axis/value pointers that reference column IDs. Formulas on a chart that sources another element must use the source's prefix (`[<SourceName>/col]`) — see `formulas.md`.

Every viz element (charts included) is an `on-select` **actions** host — see `actions.md`. Any chart can also hide its description while keeping the stored text via `description: { visibility: hidden, text? }`.

---

## Line chart (revenue over time)

```yaml
id: sales-over-time
kind: line-chart
name: Sales over time
source:
  kind: table
  elementId: sales-table
columns:
  - id: col-month
    name: Month
    formula: DateTrunc("month", [Master/Date])
    format:
      kind: datetime
      formatString: "%b %Y"
  - id: col-sales
    name: Sales
    formula: Sum([Master/Sales Amount])
    format:
      kind: number
      formatString: "$,.0f"
xAxis:
  columnId: col-month
yAxis:
  columnIds:
    - col-sales
```

- `xAxis` — single `{ columnId, sort?, format? }`
- `yAxis` — single `{ columnIds: [<colId>, ...], format? }`. On any cartesian chart, a `columnIds` entry may be an object `{ columnId, type }` (`type`: `bar` | `line` | `area` | `scatter`) to set that series' shape — most useful on `combo-chart`
- `yAxis2` — `combo-chart` only: `{ columnIds: [<colId>, ...], format? }`, where every id must also be listed on `yAxis.columnIds`. It selects which of those series use a secondary scale; see "Combo charts" below
- `xAxis.sort` shape: `{ by: <colId>, direction: ascending | descending }`
- Optional `format` on each axis configures title, labels, marks, and scale — it's inlined on `xAxis.format` / `yAxis.format`; inspect it via the kind recipe above rather than transcribing the whole object

## Bar chart (revenue by category)

Same axis shape as line-chart. Adds `stacking`.

```yaml
id: sales-by-region
kind: bar-chart
name: Sales by region
source:
  kind: table
  elementId: sales-table
columns:
  - id: col-region
    name: Region
    formula: "[Master/Store Region]"
  - id: col-sales
    name: Sales
    formula: Sum([Master/Sales Amount])
    format:
      kind: number
      formatString: "$,.0f"
xAxis:
  columnId: col-region
  sort:
    by: col-sales
    direction: descending
yAxis:
  columnIds:
    - col-sales
stacking: none
```

`stacking`: `none` | `stacked` | `"100"` (the percent-stacked variant must be quoted in YAML to keep it a string, not a number).

On a **stacked** bar chart with a `color` channel or multiple y-axis series, each `columns[]` entry may set `showOnSegments` (`shown` | `hidden`, default hidden) and `showOnTotals` (`shown` | `hidden`, default shown) to control per-segment and total data labels.

## Bar chart with custom category colors

`bar-chart` accepts an optional `color` channel with three variants:

```yaml
# Single fixed color
color:
  by: single
  value: "#3b82f6"

# One color per category (positional — see below)
color:
  by: category
  column: col-region
  scheme: ["#3b82f6", "#ef4444", "#10b981", "#f59e0b"]

# Continuous scale across a measure
color:
  by: scale
  column: col-sales
  scheme: ["#fef3c7", "#fbbf24", "#dc2626"]
  domain: { min: 0, max: 10000, mid: 5000 } # `mid` is optional; its presence makes the gradient diverging, otherwise sequential
```

**A column can only be on one channel at a time** — if `col-region`/`col-sales` above is also your `xAxis`/`yAxis` column, reusing its `id` for `color.column` rejects at `POST`. See the recipe below for the workaround (a second column with the same formula, a different `id`).

**Recipe — pin specific categories to specific colors:**

`scheme` is a **positional** array: Sigma assigns colors to categories in the order they appear on the axis, not by category name. To pin Electronics → blue, Apparel → red, Home → green, control the sort order alongside the color array:

**A column can only be bound to one channel at a time — verified live.** Putting the same `columnId` on both `xAxis` and `color` rejects at `POST` with `Column '<id>' is referenced from both 'xAxis' and 'color'; a column can only be on one channel at a time`. If you want the axis category and the color category to be the same field, declare **two columns with the same formula** (different `id`s) — one for each channel:

```yaml
kind: bar-chart
name: Revenue by category
columns:
  - id: col-cat
    name: Category
    formula: "[Sales/Product Category]"
  - id: col-cat-color
    name: Category (color)
    formula: "[Category]" # same value as col-cat, bare-ref to the column above, distinct id for the color channel
  - id: col-sales
    name: Revenue
    formula: Sum([Sales/Revenue])
    format:
      kind: number
      formatString: "$,.0f"
xAxis:
  columnId: col-cat
  sort:
    by: col-cat
    direction: ascending
yAxis:
  columnIds:
    - col-sales
color:
  by: category
  column: col-cat-color
  scheme: ["#3b82f6", "#ef4444", "#10b981"]
```

For category-by-name binding rather than position, use a derived column with an `If(...)` that emits the categories in a known order, then sort by that order.

## Donut

Uses `value` and `color` instead of `xAxis` / `yAxis`.

```yaml
id: sales-by-family
kind: donut-chart
name: Sales by product family
source:
  kind: table
  elementId: sales-table
columns:
  - id: col-family
    name: Family
    formula: "[Master/Product Family]"
  - id: col-sales
    name: Sales
    formula: Sum([Master/Sales Amount])
    format:
      kind: number
      formatString: "$,.0f"
value:
  id: col-sales
color:
  id: col-family
  sort:
    by: col-sales
    direction: descending
```

`holeValue` is optional. When set, it references one of the donut's columns by ID — that column's aggregated value drives the hole label/render — not a literal number:

```yaml
holeValue:
  id: col-sales
```

## Element-level filters (Top-N, etc.)

Charts take the same `filters` array as tables — the top-N example in `tables.md` applies to `bar-chart`, `line-chart`, and `donut-chart` without changes.

Top 10 regions by `Sales` on a bar chart:

```yaml
filters:
  - id: top-10
    columnId: col-sales
    kind: top-n
    rankingFunction: rank
    mode: top-n
    rowCount: 10
    includeNulls: when-no-value-is-selected
```

`rowCount` takes a number literal — it cannot be bound to a control (see `controls.md`, "Where Control Bindings Apply").

## Cartesian-only optional features

These apply to `bar-chart`, `line-chart`, `area-chart`, `scatter-chart`, and `combo-chart`. Use the kind recipe at the top of this file to read the full operator and styling enums for any of them.

### `refMarks` — reference lines and bands

```yaml
refMarks:
  - type: line
    axis: series # axis | series | series2
    value: 1000 # number, column ID, or formula string
    line: { color: "#ef4444", width: 2 }
    label: { text: "Threshold" }
  - type: band
    axis: series
    value: 800
    endValue: 1200 # required for bands
```

### `trendlines` — regression overlays

```yaml
trendlines:
  - columnId: col-sales # which series to fit
    model: linear # linear | quadratic | polynomial | exponential | logarithmic | power
    line: { color: "#336699", width: 2 }
    label: { visibility: shown, text: "Sales trend" }
```

Trendlines are rejected when the chart has no `xAxis`, uses stacking on bar/area/combo, or has a `color` channel — discover those constraints by submitting and reading the error.

**`line.width` is accepted at `POST` but silently dropped on readback — verified live.** `line: { color: "#94a3b8", width: 2 }` round-trips as `line: { color: "#94a3b8" }`, `width` gone, no error either way. Don't rely on it; treat trendline line width as not currently settable through the spec API.

### `dataLabel` — value labels on marks

```yaml
dataLabel:
  labels: shown # shown | hidden
  labelDisplay: all # auto | minimum | maximum | min-max | all
  valueFormat: percent
  precision: 1 # decimal places for the formatted value (e.g. percent labels)
  totals: { display: shown }
```

`valueFormat` + `precision` format the label value — notably for percent-formatted labels on `scatter-chart` and combo scatter layers.

For `combo-chart`, optional `seriesDataLabel` is a map keyed by layer shape (`bar`, `line`, `area`, `scatter`) with per-shape overrides:

```yaml
seriesDataLabel:
  bar: { labelDisplay: maximum }
  line: { labelDisplay: all }
```

## Combo charts (mixed series + secondary axis)

A `combo-chart` mixes bar/line/area/scatter series on one plot. `yAxis.columnIds` lists **every** series on the chart — use the `{ columnId, type }` form to set each one's shape. `yAxis2` then names the subset of those series to plot against a secondary scale: every id in `yAxis2.columnIds` must also appear on `yAxis.columnIds`, or the write is rejected. Assigning a series to `yAxis2` changes its scale only — its shape still comes from `type` on `yAxis`.

```yaml
kind: combo-chart
xAxis:
  columnId: col-month
yAxis: # every series on the chart, each with its shape
  columnIds:
    - { columnId: col-revenue, type: bar }
    - { columnId: col-margin-pct, type: line } # listed again on yAxis2 below
yAxis2: # subset of yAxis.columnIds — secondary scale only
  columnIds:
    - col-margin-pct
  format:
    visibility: shown # set to `hidden` to hide the axis (no other fields on that branch)
```

`yAxis2` is `combo-chart`-only; it's rejected on the other cartesian kinds.

> **⚠️ A combo chart keeps only ONE bar series, and no stacking (verified 2026-10-19).** Send `[{y1, bar}, {y2, bar}, {y3, line}]` and the GET-back is `['y1', {y2, line}, {y3, line}]` — every bar after the first is rewritten to a line, with no error. `stacking` is dropped too. For grouped or stacked bars plus a line, use a `bar-chart` (with `color` for the series) and put the line on a separate chart or a reference mark.

> **Y-axis domain only applies with all three settings together** (verified by PNG, 2026-10-19): `yAxis.format.scale: {type: linear, zero: false, domain: {min, max}}`. `domain` alone, or `zero: false` alone, is kept in the spec and ignored at render. `scale` placed directly on `yAxis` (not under `format`) is silently dropped.

> **Legend:** `visibility: shown` is accepted (and normalised away on GET), but `{visibility: shown, position: …}` fails verify with "cannot mix `visibility: 'hidden'` with legend content" — verify reads `shown` as `hidden`. To show a legend in a position, send `position` alone.

Per-series styling is keyed by layer shape (`bar` / `line` / `area` / `scatter`):

- `seriesLineAreaStyle` — stroke/fill, curve, and area opacity for line/area layers
- `seriesPointStyle` — marker shape/size for points
- `seriesDataLabel` — per-shape data-label overrides (above)

Chart-wide fallbacks `barStyle`, `lineAreaStyle`, `pointStyle`, and `gap` also exist. Inspect the kind recipe for the full sub-field set of any of these.

### More cartesian options

Each of these is a top-level key on cartesian charts; one-liner here, full sub-fields via the kind recipe at the top of this file.

- `orientation: horizontal` on `bar-chart` — horizontal bars. Omit for the default vertical bars.
- `trellis` — small multiples (faceted grid). `{ column, row, share?, tileSize? }` facets by the `column` / `row` column IDs. It also carries **shelf bindings**: `rowsBy` / `columnsBy` (category trellis, each an array with optional sort) or `series` (trellis by series) — category and series modes are mutually exclusive.
- `legend: { visibility, position, ... }` — legend placement and styling.
- `tooltip: { columnNames?, multiSeries?, valueFormat? }` — hover-tooltip content and formatting.

(Trendlines and `refMarks` are covered above.)

## Other chart kinds

Per the OpenAPI, these are all valid `kind` values; documented examples for the most common are above. The shape mirrors the `bar-chart`/`line-chart` pattern (`source`, `columns`, `xAxis`, `yAxis`). Inspect any of them with the kind recipe at the top of this file:

- `area-chart`, `combo-chart`, `scatter-chart` — same shape as `bar-chart`/`line-chart`, just a different `kind` (and `combo-chart` adds the series configs above).
- `pie-chart` — like `donut-chart` (`value` + `color`), but without the donut-only `hole` / `holeValue` / `innerRadius` / `trellis` keys.
- `pivot-table` — uses `values` instead of `yAxis`; useful for cross-tab analysis. See `tables.md`.
- `waterfall-chart` — cartesian (`source`, `columns`, `xAxis`, `yAxis`, `legend`, `tooltip`, `dataLabel`, `filters`, `style`, `refMarks`) plus waterfall-specific keys: `grouping`, `splitBy`, `color`, `waterfallColors`, `waterfallShape`, `startPoint`. Pull the sub-shapes with the kind recipe (`--arg k waterfall-chart`).
- `box-chart` — box-and-whisker plot. Cartesian-shaped (`source`, `columns`, `xAxis`, `yAxis`); pull the exact sub-shape with the kind recipe (`--arg k box-chart`) before using it — not yet hand-documented here.

## Progress

A `kind: progress` element renders a progress bar / gauge against a target — not a cartesian chart, so it has no `source`/`columns`/axes. `value`, `min`, and `max` are formula strings (like a KPI's value):

```yaml
- id: goal-progress
  kind: progress
  shape: bar # enum — inspect the recipe for the full set
  mode: manual # enum
  value: Sum([Master/Revenue])
  min: "0"
  max: "1000000"
  config: {} # progress-specific styling — inspect the recipe
```

Inspect `shape`, `mode`, and `config` sub-shapes with the kind recipe (`--arg k progress`).

For element-level reference of `kind: "text"` (free-form Markdown blocks), see `content-elements.md`.
