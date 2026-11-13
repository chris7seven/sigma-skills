# Narrative text that reads the current data

A paragraph next to a chart that names the biggest mover, counts the exceptions and
states the rule that produced them. It updates itself, so it never goes stale the way
hand-written commentary does.

**The trick is a hidden helper element.** Text elements have no source of their own, so
`{{formula}}` in a text body resolves against an *ambient* grain you do not control. Build
a one-row table grouped on a literal, compute every figure the sentence needs as a column,
then reference those columns by name.

```python
{"id": "insight-helper", "kind": "table", "name": "Insight Helper",
 "source": {"kind": "data-model", "dataModelId": DM, "elementId": "el-fct-debtor-anomaly"},
 "columns": [
   {"id": "ih-all",   "name": "Book",          "formula": '"All"'},          # the literal
   {"id": "ih-delta", "name": "Top Delta",     "formula": f"Max({delta})", "format": USD},
   {"id": "ih-name",  "name": "Top Mover",     "formula": f"MaxIf([{A}/Debtor Name], {delta} = Max({delta}))"},
   {"id": "ih-count", "name": "Flagged",       "formula": f"CountDistinct([{A}/Debtor Name])", "format": INT},
   {"id": "ih-high",  "name": "High Severity", "formula": f'CountDistinct(If([{A}/Severity] = "High", [{A}/Debtor Name], Null))', "format": INT},
 ],
 "groupings": [{"id": "ih-g", "groupBy": ["ih-all"],
                "calculations": ["ih-delta", "ih-name", "ih-count", "ih-high"]}]}
```

`MaxIf(<the label>, <the measure> = Max(<the measure>))` is the "name the argmax" idiom —
there is no `ArgMax`, and this is the form that works. Keep helpers on a hidden `Data`
page.

Then the text body:

```
{{Text([Insight Helper/Flagged])}} debtors meet the flag rules,
{{Text([Insight Helper/High Severity])}} at High severity.
The largest single move is {{Text([Insight Helper/Top Mover])}}: open A/R up
{{[Insight Helper/Top Delta] | $,.0f}} against its balance 90 days ago.
```

Two things that will bite you:

- **`Text()` strips the column's format** — `1234567.8` renders raw. Format at the
  reference instead: `{{[Helper/Amount] | $,.0f}}`. Use `Text()` only for strings and
  bare integers.
- **`groupings[]` entries need an `id`.** Omit it and you get `Invalid kind: "table"`,
  which points nowhere near the real problem (`gotchas.md` #16).

Always close with the **rule**, not an opinion:

```
GOOD  "Flag rules: A/R growth above 25% together with days outstanding up more than 10.
       Materiality floors of $250k now and $100k at the prior anchor apply, so a small
       balance cannot post a large percentage."
BAD   "Broker exposure is dangerously concentrated and needs attention."
```

Stating the threshold is what makes the paragraph defensible in a meeting. Interpretation
belongs to the AI agent, which can see current values; baked-in judgement goes stale.

## A stronger version: genuine AI narrative, not a templated sentence

The pattern above is deterministic — a `MaxIf` argmax formula, not reasoning. For real
model-generated prose in the same slot, replace the templated sentence with a warehouse
AI call inside a hidden column, still on the same one-row helper element:

```python
{"id": "c-ai-prompt", "name": "AI Trend Prompt", "hidden": True,
 "formula": '"Describe this trend in 2-3 sentences, calling out anything notable. '
            'Total: " & Text(Round([Total], 0)) & ". Change: " & Text(Round([MoM Pct]*100,1)) & "%."'}
{"id": "c-ai-explain", "name": "AI Trend Explanation",
 "formula": 'CallText("SNOWFLAKE.CORTEX.COMPLETE", "<model>", [AI Trend Prompt])'}
```

`CallText(<warehouse function>, ...args)` runs a warehouse AI function as a computed
column — real reasoning over the current numbers, not a template. Two things to get right:

- **Scope it to the one-row grouped helper, never a row-level table.** That's one model
  call per page load, not one per underlying row — the difference between cheap and a
  real cost/latency problem.
- **Not every model name is available on every account/region.** `mistral-large2` and
  `claude-3-5-sonnet` failed outright on one customer's Snowflake account while
  `llama3.1-70b` worked — probe with a trivial prompt (`SELECT SNOWFLAKE.CORTEX.COMPLETE('<model>', 'Say OK')`)
  directly against the connection before committing to a model name, and include an
  unambiguous should-fail case so a uniform failure reads as "wrong model," not "Cortex is broken."

The rendered `text` element needs no plugin for this — plain Markdown (headers, bold,
bullet lists) is native to the `text` element kind; see `content-elements.md`.

## CallText directly in a text element, fed by one facts row (verified 2026-09-22)

The `CallText` call can sit in the text body itself, as long as every number it uses comes from
**one** facts row:

```
{{Replace(CallText("SNOWFLAKE.CORTEX.COMPLETE", "claude-4-sonnet",
   "Summarise ... Total net assets $" & Text(Round(Max([Close Facts/Tna Now]) / 1000000000, 2))
   & " billion ... Write two sentences, plain text only, no preamble, no markdown."), '"', "")}}
```

`Replace(..., '"', "")` strips the quotes models like to wrap answers in. Wrap the text in a
light card: an eyebrow like `✦ AI SUMMARY · SNOWFLAKE CORTEX`, then the call.

**When the facts come from several elements, don't group. Filter to one row and Lookup.** A
grouped helper works when every figure comes from one source. When the prompt needs numbers from
five different elements (GL, positions, holdings, an output grid, a decision log), build an
*ungrouped* table filtered to a single row, and pull each figure in with a compound-key Lookup
against a literal key:

```python
# on each base element:            c("key", "Key", '"1"', hidden=True)
# on the one-row facts element (source: any small DM element, filtered to 1 row):
lk = lambda el, col: f"Coalesce(Lookup(Sum([{el}/{col}]), [Key], [{el}/Key]), 0)"
facts["columns"] = [
    c("cf-key", "Key", '"1"'),
    c("cf-period", "Period", "[PeriodFilter]"),                    # control value, for the prompt
    c("cf-now", "Tna Now", lk("GL Lines", "TNA Now")),             # base col = If(period matches, value)
    c("cf-exc", "Exc N",   lk("Holdings Feed", "Exc Flag")),
    c("cf-agg", "Agg Rev N", lk("Analysis", "Agg Rev")),           # can read an output grid too
]
```

Then KPI tiles, checklists and every CallText prompt all read `Max([Close Facts/<col>])`. **One
row feeds everything, so the AI sentence can never contradict the tile next to it.** Period
awareness comes from the base columns (`If([Period] = [PeriodFilter], value)`), so every summary
regenerates when the control changes.

**Model names.** On a Sigma staging environment, `claude-4-sonnet` and
`mistral-large2` worked and `claude-3-7-sonnet` returned `unknown model`. Availability varies by
account. Probe with a table column `If([k] = "x", CallText(..., "<model>", "Reply with exactly:
OK"))` on a table filtered to one row, then read it through the MCP workbook query. **Test one
model per query:** a single unknown model fails the whole query.

### Prompt rules: every one of these came from a wrong sentence on screen

Read every generated sentence against the element underneath it before shipping. On the D&C build
that check caught five errors across six summaries.

| What the model wrote | Cause | Fix |
|---|---|---|
| Level 1 **$153.64B**, but the grid showed $145.16B | Facts came from all positions, including rows the grid excludes | **Feed a summary from the element it sits on**: hidden columns on that element (`If([Source] = "Appraisal", [1], 0)`), then Lookup into it |
| "$41.90" became "**$41.9 million**" | Bare number, no units | Spell it out: `"41.90 US dollars (dollars, not millions)"` |
| "$41.90" became "**$0.00 billion**", then "**$41,900,000**" | A blanket "use billions" rule collided with a tiny value | **Pass the finished string and forbid conversion**: `"write it exactly as $41.90 and do not convert it"` |
| "moved from **Level 3** to Level 2" | Direction implied, not stated | State direction: `"set to Level 2 that would otherwise be Level 1"` |
| "indicating **market liquidity constraints**" | Model filled in a cause | Append `"State facts only; do not speculate about causes."` |
| "Removed 10/5" became "**October 5th**" | Model interpreted cell text | `"quote it exactly; do not interpret it as a date"` |
| "assets under management" | Loose terminology | Name the measure: `"total net assets, never assets under management"` |
| Led with a known structural gap as "the blocker" | No priority given | `"a known limitation to mention once, not the blocker"` |

Standard suffix: `"Write two sentences, plain text only, no preamble, no markdown. State facts
only; do not speculate about causes."`

### Placement and cost

- **Text in a sidebar or header panel cannot read a page control.** `{{[PeriodFilter]}}` there
  renders "unknown column". Page text can. Keep dynamic period text out of panels.
- **Each CallText text element is one model call per render.** Six on a workbook was fine for
  latency. Don't put CallText on a row-level column of a large table.
- On a page with a colour key, stack it as: AI card, then key, then table. The key belongs
  directly on top of the table it explains.
