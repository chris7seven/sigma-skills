# Sigma workbook API — silent failures

Written for: analysts building Sigma workbooks through the REST API with Claude.

## Settle shapes with `/spec/verify`, not with guesswork

Before anything else: **there is an endpoint that validates a representation without
creating or modifying a workbook.**

```
POST /v2/workbooks/spec/verify
body: {"name": "...", "folderId": "<uuid>", "document": {...}}
->    {"valid": true}
->    {"valid": false, "errors": [{"summary": "Layout XML: unknown element <Tab> ... (expected Element, Container, or TabbedContainer)"}]}
```

Its `errors[].summary` messages are far better than the create endpoint's, and it
costs nothing. Use it for every shape question instead of create-then-delete probing.
Note it validates the **whole create payload**, so omitting `name`/`folderId` produces
errors about those rather than about your element.

**Primary references, in this order:**

1. `POST /v2/workbooks/spec/verify` — the arbiter for any "is this shape legal" question
2. <https://help.sigmacomputing.com/reference/create-workbook-spec> — the rendered
   request schema (element kinds, panels, sources, controls)
3. <https://help.sigmacomputing.com/docs/workbook-representation-example-library> —
   worked representations for specific configurations
4. <https://help.sigmacomputing.com/docs/function-index> — the formula arbiter

This file only covers what those four do **not** tell you: cases where the API accepts
your input and then produces a wrong number.

Every item below was hit and verified live. They share one property that makes them
expensive: **the spec write succeeds.** You get a 200, the element appears, and the
number is wrong or blank. None of them are discoverable from the API reference.

If you read one thing, read [What the spec endpoint does and does not
validate](#what-the-spec-endpoint-actually-validates).

---

## 1. `Divide()` does not exist

Sigma's math functions are `Div` (integer component) and `Mod`. There is no `Divide`
and no `SafeDivide`. `Divide(a, b)` is an unknown function — **accepted at write**,
then fails at query time with `Reference to errored column`.

```
WRONG   Divide([Gross Earnings], [Purchases])
RIGHT   ([Gross Earnings]) / If(([Purchases]) = 0, Null, ([Purchases]))
```

The `If` is the `NULLIF` equivalent. On one data model 14 formulas used `Divide()`,
7 of them from the original build — those metrics had never returned a value, and
nothing surfaced it because nothing consumed them.

**Unknown functions in general are accepted and fail at render.** `TotalOverAll(...)`
and `Strftime(...)` both wrote cleanly and rendered as
`Invalid Query: Unknown function`. Check the function index before using a name:
<https://help.sigmacomputing.com/docs/function-index>

## 2. Window functions exist — under names you may not guess

Do not conclude a capability is missing because a name is. There is no `Total()`,
but there are:

| Need | Function |
|---|---|
| grand total / share of total | `GrandTotal(agg)`, `Subtotal(agg, mode)`, `PercentOfTotal(agg, mode)` |
| share within a group | `PercentOfTotal(agg, "parent_grouping")` |
| running total | `CumulativeSum` (not `RunningSum`) |
| rolling window | `MovingSum([col], above, below)`, `MovingAvg` |
| prior/next row | `Lag`, `Lead`, `First`, `Last`, `Nth`, `FillDown` |
| ranking | `Rank`, `RankDense`, `RankPercentile`, `Ntile` |
| trendline + error term | `RegressionSlope`, `RegressionIntercept`, `RegressionR2` |
| distribution | `PercentileCont`, `PercentileDisc`, `StdDev`, `Median` |

All of these resolve against a `data-model` source, so **needing a window function is
not a reason to drop to custom SQL.**

## 3. A data-model metric cannot reference another metric

It writes fine and errors at query time with
`Reference to errored column "[Metrics/<name>]"`.

```
WRONG   Pct of Book = PercentOfTotal([Open AR (Latest)], "grand_total")
RIGHT   Pct of Book = PercentOfTotal(SumIf([Open Amount], [As Of Date] = Max([As Of Date])), "grand_total")
```

Inline the referenced metric's definition so each metric is self-contained. Same
applies to a metric reference inside a `SumIf` **condition**.

Consuming `[Metrics/<name>]` from a **workbook** is fine — it's only
metric-to-metric inside the model that breaks.

## 4. Relationship traversal returns NULL. Use `Lookup()`

A relationship is necessary but not sufficient to pull a dimension column onto a fact.

| Form on the fact element | `GET /columns` type | Actual values |
|---|---|---|
| `[Dim - Debtor/Debtor Type]` | `text` ✅ | **null, 0 of 500 rows** |
| `Lookup([Dim - Debtor/Debtor Type], [Dim Debtor Sk], [Dim - Debtor/Dim Debtor Sk])` | `text` ✅ | correct, 500 of 500 |

`Lookup(<dim column>, <fact's FK>, <dim's PK>)`, everything by **name** — column ids
fail with `Unknown name`. Note both forms report a healthy type: an *errored* formula
shows `type: "error"`, but a *null-producing* one looks fine.

A workbook element sourced on one model element sees **only that element's own
columns** — traversal doesn't reach through at all there. Materialise the attributes
on the fact in the model first.

## 5. Ungrouped table aggregates do not push down

A flat table of aggregate columns with no `groupings[]` aggregates only the **loaded
row page**. It reported Open A/R of **$3,368** against a true **$2,149,049,461**, and
`Max([As Of Date])` as the wrong year.

Any element whose columns are aggregates needs a `groupings[]` entry — group on a
literal (`"All"`) if there's no real dimension. A `groupings[]` entry also requires an
`id`, or the write fails with the masked `Invalid kind: "table"`.

## 6. `Sum()` over a GROUPED element multiplies by the base row count

The other half of #5, and the most dangerous item here.

`groupings` is a **display transform, not a new grain.** A child element sourced from
a grouped table queries the ungrouped rows underneath, where each group-level value
repeats on every row.

```
Sum([KPI Helpers/Total Open AR])   $651,868,389,931,478,800   = x303,328,705
[KPI Helpers/Total Open AR]        $2,149,049,461             correct
Max([KPI Helpers/Total Open AR])   $2,149,049,461             correct
[Metrics/Open AR (Latest)] off the model element              correct
```

**Point KPI tiles at the data model element and reference `[Metrics/…]` with no
aggregate wrapper.**

Two traps inside the trap:

- **Adding a grouping to an existing element is a breaking change** for every child
  that aggregates it. Grep for `Sum([<That Element>/` first.
- A text `{{formula}}` is **not** affected — it resolves the grouped value directly.
  Correct prose sitting next to a wrong KPI, reading the same column of the same
  element, is the signature of this bug.

## 7. Trailing-window measures break inside a period grouping

`SumIf` only sees rows inside the current group. A 4-month trailing average grouped by
month returned that month's value ÷ 4 — $429,444,154 for a month whose purchases were
$1,717,776,616.

Compute trailing windows at the entity grain (one row per client/debtor), in SQL or a
dedicated model element. Also: a **metric cannot be used as a `groupBy`** — Sigma
rejects it with `Dependency not found`. If you need to group by a derived tier, make it
a column.

## 8. Ratios of totals, never averages of ratios

Averaging a per-entity rate across a long tail is dominated by the tail. The same AR
Turn measure, same data:

```
Avg(per-client ar_turn)                        ~140 days   wrong
Sum(balance) * 30 / Sum(collections)            ~37 days   right
```

And watch the window length: dividing a **summed** stock (4 months of balances) by a
120-day rate inflated it ~4x. `(o4/4) / (c4/120)` simplifies to `o4*30/c4`, which is
also grain-independent — prefer the form that can't be wrong at another grain.

## 9. Partial periods poison every rate

The in-flight month has only part of its collections posted. AR Turn read **124.8
days** against a true ~37 because 11 days of collections were divided by 30. Flag the
partial period as a column and exclude it from every rate and trailing average; show
the month-to-date row if you want, but label it.

## 10. A `/` in a column NAME breaks references to it

A column named `Open A/R` cannot be referenced — `[Metrics/Open AR]` built on it
rendered `Reference to errored column` and a value of 0. Same for a metric named
`Clients w/ Rating Change`. Keep slashes out of names; put them in the label if you
need them visually.

## 11. `Text()` strips a column's format

`Text([Credit Limit])` renders `2000000`, and `Text([Contract Since])` renders a raw
timestamp. Use the pipe instead:

```
{{[Client Profile/Credit Limit] | $,.0f}}
{{[Client Profile/Contract Since] | %Y-%m-%d}}
{{[Forecast Helper/Month 1] | %b %Y}}
```

## 12. `<span style>` allows four properties, and cannot contain a blank line

Allowed: `color`, `background-color`, `font-size`, `font-family`. **`font-weight` is
rejected outright** — use markdown `**bold**` inside the span. And a blank line
(paragraph break) inside a `<span>` closes the markdown block before the tag, giving
`unclosed inline HTML tag <span>`: emit **one span per paragraph**.

Markdown `**` must not straddle a `{{formula}}` — it renders literally
(`25** debtors**`).

## 13. Charts stack by default

`stacking` defaults to `"stacked"`. A P10 / median / P90 band rendered stacked on top
of each other, which is meaningless. Set `stacking: "none"` for a comparison band.

Secondary axis is `yAxis2: {columnIds: [...]}`, and series shape goes **inline** on
`yAxis.columnIds` as `{columnId, type}` — a separate `series` key is silently ignored,
which left an AR-turn line flat along zero under a purchases bar scale.

## 14. Grid rows are absolute positions

`gridRow="900 / 905"` is not "append at the end" — it's row 900, and the page renders
**21,855px tall** with ~800 empty rows. Find the page's real maximum row first.

When you do need to shift rows, **never** regex the whole page: container children use
container-**relative** rows, so a blanket shift collapses them to zero height. Edit
top-level element lines explicitly.

Also: one layout placement per element. "Show this on every page" is a move into a
panel, not a second placement.

## 15. Minimal probes under-report what's buildable — check the schema, not just `/spec/verify`

The request schema's `kind` enum has 81 values, and a handful of *shapes* need more than
`{kind, controlType}` to pass. Sending the bare minimum and reading `Invalid kind:
"date-range"` as "not supported" is **wrong** — that's the masked error (#16) for a
missing nested field, and I fell into it twice on this build. Before writing off a shape,
pull its schema and check what's actually `required`:

```python
sch = openapi["components"]["schemas"]["Control"]  # or whichever schema
# walk sch["oneOf"] / sch["allOf"] for {"required": [...]} nodes
```

Confirmed with `/spec/verify`, correctly shaped:

| Shape | Result |
|---|---|
| `controlType: "date"` + `mode: "<="` | **valid** — `mode` (`<=`/`=`/`>=`) is required, undocumented in a minimal probe |
| `controlType: "date-range"` + `mode: "between"` | **valid** — `startDate`/`endDate` optional |
| `controlType: "text"` | still rejected minimal; likely the same trap, not yet re-derived |
| `controlType: "list"`, `"number-range"`, `"segmented"` | `{"valid": true}` minimal |
| element kind `navigation` | rejected on a page **and** in a panel, re-tested with several shapes |
| element kind `tabbed-container` | **valid** — see below |
| panel `type` other than `header` / `sidebar` | rejected (`drawer`, `left`, `right`, `filter`) |

**Date and date-range controls exist and are spec-authorable.** A Sigma SE on the
A customer corrected this in a live call after I'd told the customer's analyst the
opposite. Minimal working shapes:

```jsonc
{"id": "date-control", "kind": "control", "controlId": "AsOf", "name": "As Of",
 "controlType": "date", "mode": "<=",
 "filters": [{"source": {"kind": "table", "elementId": "trend"}, "columnId": "t-date"}]}

{"id": "range-control", "kind": "control", "controlId": "DatePick", "name": "Range",
 "controlType": "date-range", "mode": "between",
 "startDate": "2026-01-01", "endDate": "2026-12-31",
 "filters": [{"source": {"kind": "table", "elementId": "trend"}, "columnId": "t-date"}]}
```

`mode` is the field a minimal `{kind, controlType}` probe never surfaces, because its
absence produces the generic masked `Invalid kind` rather than a "missing field: mode"
message. If a `list`/`number-range` workaround is already live in a workbook, it isn't
wrong, just no longer necessary — replacing it with a native date control is optional
polish, not a fix.

**Navigation.** No `navigation` element, but you rarely need one:
`settings.navigation.pageTabsInViewMode` defaults to `"shown"`, so viewers already get
Sigma's native page tab bar. Don't hand-roll nav buttons. PNG export hides the tab bar,
which is exactly what tempts people into building them.

**For tabs *within* a page, use `tabbed-container`** — it is real, and it needs its own
layout tag. The layout XML accepts exactly three: `Element`, `Container`,
`TabbedContainer`.

```jsonc
{"id": "tc", "kind": "tabbed-container", "tabs": [{"name": "Alpha"}, {"name": "Beta"}]}
```

```xml
<TabbedContainer elementId="tc" gridColumn="1 / 25" gridRow="1 / 10">
  <Tab name="Alpha" type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="t1" gridColumn="1 / 25" gridRow="1 / 4"/>
  </Tab>
  <Tab name="Beta" type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="t2" gridColumn="1 / 25" gridRow="1 / 4"/>
  </Tab>
</TabbedContainer>
```

`<Tab>` inside a plain `<Container>` is rejected, and bare `<Element>` children inside
a `<TabbedContainer>` are rejected — tabs must be `<Tab>` and content must sit inside
them.

**Panels.** `sidebar` *is* the pull-out drawer, gated on
`settings.navigation.pageSidebar: "enabled"`. A sidebar rejects `scroll: "fixed"` and
`borderStyle`, both of which a header accepts.

## 16. `Invalid kind: "<the kind you sent>"` usually means a bad nested field

`Invalid kind: "table"` rarely means `table` is wrong. It means something nested is —
a `groupings` entry missing its `id`, a filter with the wrong shape. Bisect by removing
optional blocks until it writes, rather than rewriting the kind.

Related masked errors: `Invalid value: object` on a panel (a config key that type
doesn't accept), and `Invalid effect: "set-control-value"` when the effect is valid but
the key is `control`, not `controlId`.

## 17. Linked input-table keys are frozen at creation

`Cannot change key columns on existing linked input table`. Changing them needs a new
element id. And **every** carried-over source column must be a `key` — keying only the
first made the rest render as *multiple values*.

Input tables also need write access on the connection, which is a per-connection
setting: `Connection does not support input tables. Enable write access on the
connection to use it as an input-table source.`

## 18. A column named like a control silently reads the control

If a column's name equals a control's `controlId`, a bare `[name]` in the same element
resolves to the **control's value**, not the column. Verified 2026-10-19: with control
`region` set to `East`, `"x" & [region]` compiled to `concat('x', 'East')` on every row. No
error, no warning, just wrong data. (It used to fail with "Expected text; received
variant", which was at least visible.) Never give a control an id that matches a column
name; prefix them (`ctl-region`, `RegionPick`).

## 19. Unknown fields are silently dropped, not rejected

A misspelt or misplaced field passes `/spec/verify` and create, then is missing from the
GET. Verified 2026-10-19: `bogusField: 123` on a bar chart, `yAxis.scale` (it belongs at
`yAxis.format.scale`), `series` on a combo chart, `style` on a `text` element, and greeting
`suggestions` all vanished without an error. **After every create, diff the GET-back against
what you sent.** A field that disappeared was never applied.

Two related render-only traps from the same pass:

- An element `list` filter with `values: [True]` on a boolean computed from a control
  compiles and renders in the UI, but **page PNG export fails** ("Export failed ... with
  errors"). Use a `1`/`0` column with a `number-range` filter.
- `{{[Control]}}` in a header or sidebar panel's text renders `Invalid Query: Unknown column`.
  The same text on the page works.

---

## What the spec endpoint actually validates

| Invalid input | Result |
|---|---|
| `[Element/Unknown Column]` | rejected — `Dependency not found` |
| `[Unknown Element/Col]` | rejected |
| `Sum((((` | rejected — `Invalid formula` |
| `[Metrics/No Such Metric]` | **accepted**, fails at render |
| nonexistent function | **accepted**, renders `Unknown function` |
| bare `[No Such Col]` (no element prefix) | **accepted** |
| a formula that returns NULL for every row | **accepted**, looks healthy |
| an unknown field anywhere | **accepted**, silently dropped (#19) |
| a control filter or agent `dataSource` pointing at a deleted element | rejected by `/spec/verify` (since 2026-10) |

**A passing spec write proves your prefixed column references. Nothing else.**

Data-model writes validate less. As of 2026-10-19, `POST /v2/dataModels/spec` rejects a bad
*prefixed* reference (`[Custom SQL/nosuch]`), but accepts an unknown function, an unknown
bare name, a metric that references another metric, and a metric that reads a workbook
control. All of these only fail later. Validate a model with
`GET /v2/datamodels/{id}/columns?limit=500` and check `type.type == "error"`. Metrics
don't appear there at all, so metrics can only be checked by reading values.

## So how do you actually get this right

Not by knowing more formulas. By measuring.

1. **Capture a baseline before you change anything.** `verify/export_element_values.py`
   exports every element to CSV. Run it before and after, and diff.
2. **Verify numbers, not specs.** `verify/verify_metrics.py` runs a metric in a
   *grouped* element and prints the value against an expected figure.
3. **Always include a should-fail control in a probe.** One probe of mine reported
   "13/13 PASS" while measuring nothing — only the deliberately invalid case exposed
   that the harness was broken.
4. **Reconcile from the render.** `verify/shoot.py` PNG-exports each page. Read them.
   Half the items in this file are invisible in a spec and obvious in a screenshot.
5. **Tie to a number you already trust.** Every measure here was checked against a
   known total ($2.15B of open A/R) before it shipped.

See `skills/sigma-workbooks/reference/workflows/parity-reconciliation.md` for the
build-from-a-mockup procedure that wraps all of this.
