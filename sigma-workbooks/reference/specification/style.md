# Making a generated workbook look deliberate

Written for: analysts whose API-built workbooks come out correct but plain.

Correctness and polish are separate problems. The API will happily build a page of
unstyled tables stacked vertically. Everything below is convention, not capability —
which is exactly why a model won't do it unless told.

## 1. A brand kit, before any element

Pull the real palette off the customer's site rather than guessing. Five values are
enough:

```python
NAVY, INK, LIGHT, TEAL, AMBER = "#0a1420", "#1b2430", "#b9c8dd", "#00a4bf", "#f2b568"
SUB, LINE, CARD = "#5b6b7f", "#e3e8ef", "#ffffff"
```

- `INK` for headlines, `SUB` for body and captions — never pure black on white
- one accent (`TEAL`) used *only* for section eyebrows, so it means "new section"
- `AMBER` reserved for caveats, so a caveat is recognisable without reading it

Render the logo as an `image` element with `source: {kind: "url", url: "data:image/svg+xml;base64,…"}`.
A data URI avoids depending on a host.

## 2. Every chart and table inside a styled container

This one change does most of the visual work. A bare element sits on the canvas; a
contained one looks like a card.

```python
{"id": "kpi-card", "kind": "container", "spacing": "medium",
 "style": {"backgroundColor": "#ffffff", "borderRadius": "round",
           "borderColor": "#e3e8ef", "borderWidth": 1}}
```

A `<Container>` in the layout **must also exist as a `kind: container` element**, or
the write fails with `layout references unknown element`.

## 3. The text pattern that carries a narrative

Three stacked spans per section. Consistency matters more than wording:

```
eyebrow   10px, accent, bold, UPPERCASE   "CONCENTRATION · DEBTOR INDUSTRY · LATEST SNAPSHOT"
headline  17px, ink, bold                 "Where the balance sits by industry"
body      12px, sub                       what the number is and how it was calculated
caveat    11px, #8a6410, prefixed ⚑       only when something is genuinely uncertain
```

The eyebrow carries the **grain** — "portfolio level · month-end snapshots" answers
"what am I looking at" before the reader hits a number. This is the single highest-value
piece of text on a page.

## 4. Say what the number is, not what you think of it

Workbook text states the fact and the method. Interpretation belongs to the AI agent,
which can see current values and adapt; baked-in prose goes stale the day it ships.

```
GOOD  "Open A/R at each month's final snapshot, split by debtor type. Purchases count
       the Open A/R leg of each journal entry, which is the leg carrying the invoice
       amount."
BAD   "Broker exposure is dangerously concentrated and needs attention."
```

The same rule makes KPI comparisons honest: set `comparison.direction: "none"` unless
up is genuinely good. Colouring A/R growth green asserts something you may not mean.

Where a definition is unconfirmed, say so in an amber caveat and name who can confirm
it. A visible open question reads as rigour; a silently invented number is a landmine
in a customer meeting.

## 5. KPI tiles: value, comparison, caption

```python
{"kind": "kpi-chart", "source": {...},
 "columns": [{"id": "v", "formula": "[Metrics/Open AR (Latest As-Of)]", "format": USD},
             {"id": "p", "formula": "[Metrics/Open AR (Prior Month)]", "format": USD}],
 "value": {"columnId": "v"},
 "comparisonColumn": {"columnId": "p"},
 "comparison": {"display": "percentage", "direction": "none"}}
```

Put a one-line caption **under** each tile saying what the comparison is against. A
bare "▲ 7.8%" invites the wrong question.

⚠️ A KPI comparison renders as a percentage **of** the comparison value. Comparing two
unlike percentages produced `550.0% vs Share of client count`. If the two numbers
aren't the same kind of thing, drop the comparison and state both in the caption.

## 6. Narrative order beats a feature dump

A mockup is usually one long scroll. Don't reproduce that. Order pages as a reader's
questions:

```
what is this account  ->  how is it trending  ->  what should we charge
   ->  how does that compare  ->  what does the whole book look like  ->  ask
```

Use Sigma's **native page tabs** (`settings.navigation.pageTabsInViewMode` is `"shown"`
by default). Don't hand-roll nav buttons — see GOTCHAS #15.

A persistent `header` panel carrying the logo, title and a live "as of" pill makes every
page feel like one product. Proactive alerts belong there too, so they're visible from
anywhere rather than buried on one page. Panels need
`settings.navigation.pageHeader: "enabled"` or they render nothing at all while the spec
looks complete.

## 7. Give charts every column, not just what they plot

Right-click drill-down can only break out by columns the element carries. Add
debtor/customer, type, industry, status, bucket, owner as `hidden: true` columns on
every chart and summary table. Costs nothing visually and is the difference between a
picture and something you can interrogate.

Display tables are the exception — there, show only what you mean to show.

## 8. Number formats, everywhere, once

Define them at the top and reuse. Unformatted numbers are the fastest way to look
unfinished.

```python
USD0 = {"kind": "number",   "formatString": "$,.0f"}
PCT1 = {"kind": "number",   "formatString": ".1%"}
NUM1 = {"kind": "number",   "formatString": ",.1f"}
MON  = {"kind": "datetime", "formatString": "%b %Y"}
```

In text, format at the reference: `{{[Helper/Amount] | $,.0f}}`. `Text()` strips the
format (GOTCHAS #11).

## 9. Let the numbers into the prose

A sentence with live values reads as insight rather than boilerplate, and it updates
itself:

```
{{Text([Insight Helper/Flagged])}} debtors meet the flag rules,
{{Text([Insight Helper/High Severity])}} at High severity, carrying
{{[Insight Helper/Flagged AR] | $,.0f}} of open A/R between them.
```

Build a small hidden helper element (grouped on a literal) that computes the figures the
sentence needs, then reference it. Keep helpers on a hidden `Data` page.

## 10. Trim what the build leaves behind

Before you call it done: delete duplicate columns from UI editing (`Bucket (1)`), drop
segments that don't belong in the frame (an `Inactive` tier in a table about active
clients), hide join keys, and check no page scrolls past its content. Then screenshot
every page and look at it — see GOTCHAS, final section.
