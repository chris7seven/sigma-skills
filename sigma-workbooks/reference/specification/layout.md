# Layout

Recipe book for the workbook's `layout` XML — when to write it, the two-tag grammar, and the silent-failure traps to watch for. `layout` lives under the spec's **`document`** envelope (`document.layout`); its value is the XML string described below. **Default to writing explicit `layout` XML for multi-element workbooks.**

**`layout` now does more than position elements — it's the only thing that assigns an element to a page at all.** `document.elements` is a flat array with no page reference of its own; `document.pages` is metadata only. An element placed nowhere in `layout` is rejected at write time (`element '<id>' is not placed in layout`), so `layout` is effectively required for any workbook with elements, not just a positioning nicety.

Container _elements_ (the `kind: "container"` JSON placeholders that pair with `<Container>` in this XML) are covered in **Container elements** below.

## When to write layout vs. let Sigma auto-arrange

Write explicit `layout` when **any** of these apply:

- The page has **mixed element kinds** (charts + KPIs, controls + charts, text/image/divider polish). Auto-arrange treats them as a vertical stack and gives every element the same height — KPIs end up the size of charts, dividers get huge gutters around them.
- The user asked for specific positioning ("logo on left, title on right", "KPIs across the top", side-by-side charts).
- There's a `kind: "container"` element on the page. Containers without a matching `<Container>` are functionally no-ops.
- The workbook has more than ~4 elements on a page. Auto-arrange becomes a long scroll.

Auto-arrange (omit `layout`) is fine when:

- The page has a single element.
- The page is a uniform stack of tables — auto-arrange produces a reasonable list view.
- The user explicitly says default layout is fine.

If unsure, write the layout. Writing one is cheap (the patterns below are copy-paste); a visually broken dashboard is expensive.

## Two-tag grammar

**The layout XML is a root-less fragment: one `<?xml?>` declaration followed by N sibling `<Page>` blocks, with no wrapper element around them — this is deliberate, not an omission.** A multi-page workbook's `document.layout` string is not well-formed XML by the usual single-root rule, and it's tempting to wrap the `<Page>` siblings in something like `<Document>...</Document>` to fix that. Don't — the parser expects bare siblings and rejects a wrapper:

```
Expecting "Page" at 1.elements.0.0.name but instead got: "Docu..."
```

```xml
<?xml version="1.0" encoding="utf-8"?>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="<pageId>">
  <Container elementId="<containerId>" type="grid" gridColumn="1 / 25" gridRow="1 / 4"
                 gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="<childId>" gridColumn="1 / 13" gridRow="1 / 4"/>
  </Container>
  <Element elementId="<elementId>" gridColumn="1 / 25" gridRow="4 / 16"/>
</Page>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="<secondPageId>">
  <Element elementId="<anotherElementId>" gridColumn="1 / 25" gridRow="1 / 16"/>
</Page>
```

Each `<Page id>` matches a `pages[].id`. Each `elementId` matches an entry in the flat, top-level `document.elements[]` array — **placing an `elementId` inside a given `<Page>` is what puts that element on that page**; `document.pages` itself carries no element list. `gridColumn` / `gridRow` use standard CSS grid line syntax (`start / end`). One `<Page>` block per workbook page, all as top-level siblings — never nested inside a wrapper.

**A page's `gridTemplateColumns` is always 24 columns — this is not a convention, it's the only value the renderer honors.** The UI ignores whatever value is actually in the spec and always renders a page as a 24-column grid, so writing anything other than `repeat(24, 1fr)` for a `<Page>` doesn't do what it looks like it does — the number in the spec and the number of columns the viewer actually sees silently diverge. Always write `gridTemplateColumns="repeat(24, 1fr)"` on every `<Page>`, full stop.

## `<Container>` vs `<Element>`

- `<Element elementId="X" .../>` — **leaf**. Positions a single element; no children.
- `<Container elementId="X" ...>...</Container>` — **container**. Wraps child `<Element>`s in its own inner grid.

Use `<Container>` for any tag with nested children — a `<Element>` only renders as a leaf.

## Container elements

A `kind: "container"` element in `document.elements[]` is a grouping placeholder — a labeled section, a branded header strip, a KPI row treated as a unit. It renders **only** when a matching `<Container elementId="…">` positions it; declared without one, it's a no-op. Containers carry optional `style` (background color, border, corner radius, padding) and `backgroundImage` — pull the current shape from the spec rather than hardcoding it (the set of container/layout options is growing):

```bash
jq --arg k container 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

```yaml
- id: header
  kind: container
  style: { backgroundColor: "#0B3D91" }
```

- **Element on a background image:** to place an element _on top of_ a container's `backgroundImage`, make it a **child** of that container in the layout XML — the background spans the container and the child sits on top.
- **When to skip:** with no shared background or logical grouping, position elements directly with `<Element>`. A container around a single element is usually overkill.

**A `<Container>`'s own `gridTemplateColumns` (the nested grid its children position within) must be `repeat(6, 1fr)`, `repeat(12, 1fr)`, or `repeat(24, 1fr)` — no other value is supported.** Unlike a page (always 24), a container genuinely has three usable densities, matching the product editor's low/medium/high presets. Pick whichever divides evenly for your children's split (e.g. `6` for two equal halves, `12` for thirds/quarters, `24` to mirror the page grid for fine-grained control).

## Tabbed containers

A `kind: "tabbed-container"` element groups children into switchable tabs. Required `id`, `kind`, and `tabs` (each `{ name }`); optional `tabBar` (`visibility`: `shown`/`hidden`; `style`: `open`/`box`/`button`; `alignment`: `left`/`center`/`right`/`justify` — `start`/`end` are rejected, verified 2026-10-19; `size`: `small`/`medium`/`large`), `spacing`, `elementGap`, and `style`. Pull the current shape (and how children bind to a tab) from the spec:

```bash
jq --arg k tabbed-container 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

```yaml
- id: detail-tabs
  kind: tabbed-container
  tabs:
    - { name: Overview }
    - { name: Detail }
  tabBar: { alignment: left }
```

> Switch the active tab from an action with the `select-tab` effect (see `reference/specification/actions.md`).

**A tabbed container does NOT render via `<Container>` — it needs its own distinct tags, `<TabbedContainer>` and `<Tab>`.** This is easy to get wrong by analogy with a plain `container` element, and getting it wrong is expensive: `<Container type="tabbed-container">` doesn't validate with a helpful message — it 500s with an opaque, undiagnosable `invalid_request` and no detail at all, nothing to bisect from. The correct grammar:

```xml
<TabbedContainer elementId="detail-tabs" gridColumn="1 / 25" gridRow="4 / 28">
  <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="overview-chart" gridColumn="1 / 25" gridRow="1 / 25"/>
  </Tab>
  <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="detail-table" gridColumn="1 / 25" gridRow="1 / 25"/>
  </Tab>
</TabbedContainer>
```

- `<TabbedContainer>` itself takes `elementId`, `gridColumn`, `gridRow` — **no `gridTemplateColumns`/`gridTemplateRows` of its own** (unlike `<Container>`).
- Each `<Tab>` carries its **own** `gridTemplateColumns`/`gridTemplateRows` (same 6/12/24-only rule as any other container grid) and its own `elements` — not inherited from the `<TabbedContainer>` or from each other.
- **Tabs are positional, not named in the XML.** The Nth `<Tab>` binds to the Nth entry in the element's own `tabs[]` array (which is where the tab *names* live) — there's no `name`/id attribute on `<Tab>` itself to match by.

## Repeated containers

A `kind: "repeated-container"` element renders a **card per row** of a data source — a small element layout repeated across the source's rows. Required `id`, `kind`, and `source`; optional `arrangement`, `scroll`, `cardStyle`, `cardGap`, `cardSize`, `elementGap`, `style`, `noDataText`, `sort`, `filters`. Pull the full shape (and how the per-card element layout is expressed) from the spec:

```bash
jq --arg k repeated-container 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

```yaml
- id: product-cards
  kind: repeated-container
  source: { ... } # a data source (see sources.md); one card is rendered per row
  # arrangement / scroll / cardStyle / cardGap / cardSize — inspect the recipe for values
```

**A repeated container cannot contain a data element — this rejects at POST, not silently.** Its children (positioned in the layout XML the same way container children are) are restricted to non-data content: `text`, `image`, `divider`, `button`, `embed`, `navigation`, a plain `container`, or `plugin`. Every element kind that queries a source is denied as a repeater child: `table`, `kpi-chart`, every chart kind (`bar-chart`, `pie-chart`, `donut-chart`, `line-chart`, `area-chart`, `scatter-chart`, `combo-chart`, `waterfall-chart`), every map kind (`point-map`, `region-map`, `geography-map`), `pivot-table`, `input-table` — plus `control`, `chat`, and nesting another `repeated-container` or `tabbed-container`. The rejection is explicit (`element kind '<kind>' cannot be placed inside a repeated container`), but it's easy to reach for a `kpi-chart` per card before finding that out, since nothing else in this file warns you off it.

**So a per-card metric has to be a `text` element with `{{formula}}` dynamic-text** — not a KPI or chart. This means the repeater's `source` almost always wants to be a **grouped table** (`groupings`, see `tables.md`) with a `groupingId` on the repeater's `source`, so each row (= each card) already carries its pre-computed metrics as plain columns:

```yaml
source: { kind: table, elementId: sales-by-product, groupingId: by-product }
```

**The `{{formula}}` reference must name the repeater, not the sourced table** — `{{[Product Cards/Revenue] | $,.0f}}` (the `repeated-container`'s own name), never `{{[Sales By Product/Revenue] | $,.0f}}` (the underlying table element's name), even though `Revenue` only exists as a column on that table. Referencing the table directly *looks* valid — the column name resolves, the spec round-trips unchanged, `verify-workbook.sh` passes — but every card renders "Multiple values" for every field, including plain (non-aggregated) columns: the reference bound to the full multi-row grouped result, not to the current card's single row. Only a reference through the repeater's own name carries the per-card row scope. Confirmed by direct comparison in the product UI — building the same reference by hand vs. picking the column from the UI's column picker, which always emits the repeater-qualified form. If the repeater element has no explicit `name`, its default display name (`Repeated container`) is still what the reference must use.

> **⚠️ Per-card binding is not authorable from the spec API (re-verified 2026-10-19).** The `repeated-container` schema has **no `name` field**, and every repeater-qualified reference is rejected at verify and POST with `Dependency not found`: `{{[Cards/col]}}` (after setting `name: Cards`), `{{[Repeated container/col]}}`, and `{{[<Source> repeated container/col]}}` — the form a UI-built repeater shows in its GET-back. Flat or grouped sources made no difference. `{{[<Source table>/col]}}` passes but renders "Multiple values" on every card, as described above. So: build the repeater's layout and styling from code, then bind the per-card text in the UI (or round-trip a UI-built repeater's GET-back and edit only its non-binding fields). See `unsupported.md`.

## `gridTemplateRows`: always `"auto"`, but row **span still controls rendered height**

Row tracks are always `"auto"` — write `gridTemplateRows="auto"`; there's no fixed-pixel or `fr` row-sizing option. But don't read "auto" as "row span doesn't matter, only content does" — **it does matter**: a chart, KPI, or table stretches to fill however many row-lines its `Element`/`Container` spans, the same way `gridColumn` width does. Under-allocating rows produces visibly cramped elements (thin charts with unreadable axes, KPIs squeezed into a sliver) even though the spec validates and renders without error — this is a real, verified rendering behavior (confirmed by comparing a workbook before/after widening only the `gridRow` ranges, no other change), not a hypothetical.

**There's no fixed row-count convention the way there is for columns** (`repeat(24, 1fr)` is the near-universal column convention across every example in this file). Rows need a proportionally generous range, sized by judgment, not a fixed constant. As a concrete calibration point: a page with a KPI + a chart side-by-side, plus a table below, needs roughly the range **`1 / 13` for the top row and `13 / 27` for the table** (26 total row-units) to render each element at a readable size — a` 1 / 5` / `5 / 13` split (13 total units) for the same three elements renders every element cramped into a thin sliver at the top of the page with dead space below. When in doubt, size generously — a page that's taller than the viewport scrolls; a page where every element is squeezed into a fraction of its needed height doesn't recover just because the spec was otherwise correct.

### Stacking children inside a container

A container's own row tracks are `"auto"` too, so give the container itself a generous `gridRow` span on its parent (per the calibration note above) — its children's spans are relative to *its* row range, not the page's. Two patterns work:

**Side-by-side** — children share the container's row range, differ by `gridColumn`:

```xml
<Container elementId="kpi-row" type="grid"
               gridColumn="1 / 25" gridRow="1 / 4"
               gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <Element elementId="kpi-1" gridColumn="1 / 9"  gridRow="1 / 4"/>
  <Element elementId="kpi-2" gridColumn="9 / 17" gridRow="1 / 4"/>
  <Element elementId="kpi-3" gridColumn="17 / 25" gridRow="1 / 4"/>
</Container>
```

**Stacked rows** — children have disjoint `gridRow` spans within the container's row range:

```xml
<Container elementId="header-row" type="grid"
               gridColumn="1 / 25" gridRow="1 / 12"
               gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <Element elementId="title"  gridColumn="1 / 25" gridRow="1 / 4"/>
  <Element elementId="kpi-1"  gridColumn="1 / 9"  gridRow="4 / 12"/>
  <Element elementId="kpi-2"  gridColumn="9 / 17" gridRow="4 / 12"/>
  <Element elementId="kpi-3"  gridColumn="17 / 25" gridRow="4 / 12"/>
</Container>
```

Use stacked rows when you want a section header above a row of charts inside the same container, instead of moving those elements out to the page level.

## Page-level fields: `visibility` and `backgroundImage`

Besides `id` and `name`, a page (metadata-only now — no `elements`) supports two optional fields:

- **`visibility`** — set to `hidden` to hide the page from end users. Omit for a visible page.
- **`backgroundImage`** — a page-wide background image, same shape as a container's `backgroundImage`: a required `url` plus an optional `style` block (`fit`, `horizontalAlign`, `verticalAlign`, `tiling`). `url` supports `{{formula}}` references.

```yaml
document:
  elements: [...]
  pages:
    - id: overview
      name: Overview
      visibility: hidden
      backgroundImage:
        url: https://cdn.example.com/bg.jpg
        style:
          fit: cover
          tiling: none
```

## Layout `elementId` references

Each layout `elementId` must match an `id` in `document.elements` exactly (case-sensitive) — there's no independent per-page element list to cross-check against, since the layout placement itself is what assigns the element to a page. IDs are preserved verbatim on create, so the IDs in your saved spec stay valid for follow-up `PUT`s. An element with no placement anywhere in `layout` is rejected outright (`element '<id>' is not placed in layout`), not silently dropped.

The OpenAPI doesn't model the `layout` XML string, so the grammar and examples in this file are your primary source for grid-container idioms. If you're genuinely stuck after following them, fetching an existing multi-page workbook's spec (`GET /v2/workbooks/{id}/spec`, see the recovery-move callout in SKILL.md's workflow) shows real production layout — a fallback for when stuck, not a default first move.
