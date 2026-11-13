# What the spec API cannot do (verified 2026-10-19)

Each row was re-tested against a Sigma staging environment on 2026-10-19 with `/spec/verify`, a
real create, a GET read-back, the element's compiled SQL, and a PNG render. Treat this as
a point-in-time snapshot: the API ships monthly. Before you build a workaround for any row,
re-probe it (`gotchas.md` #15 has the method). A rejected minimal probe is not proof.

Bugs (accepted but silently wrong) live in `gotchas.md`. This file covers capabilities the
API does not offer at all, and what to do instead.

## Data and write-back

| Not supported | Evidence | Do this instead |
|---|---|---|
| Writing or seeding input-table rows | every `/rows` path returns 404; no row endpoint in the OpenAPI | a button with `insert-rows` / `update-rows` the user clicks once (`approval-workflow.md`) |
| Uploading a CSV | no upload endpoint; `/v2/organizations/settings/csvUpload` is only the org on/off switch | upload in the UI, then reference it as `csv-table` by `inodeId` |
| Uploading an image | the `upload` image source says "New images cannot be uploaded via this endpoint" | host the image at a URL, or use a data-URI SVG |
| Read-only cells by formula | no protect/readOnly field on input-table columns (`readOnly` exists only on `Form` field rules) | derive a `Locked` flag and gate the write buttons on it |
| Input-table column order | GET returns every storage column first, then every formula column, whatever order you send | accept it, or show the values through a separate read-only table |
| Input tables in a data model | `Invalid kind: "input-table"` on `POST /v2/dataModels/spec` | keep input tables in the workbook |
| Agent writes to an API-created input table | the agent's `insert-rows` tool returns "Manual commit is not enabled for this input table" | open the workbook in the UI and publish once; the flag syncs then |

## Automation and events

| Not supported | Evidence | Do this instead |
|---|---|---|
| Event-driven alerts | `/v2/alerts` and `/v2/workbooks/{id}/alerts` return 404 | `/v2/workbooks/{id}/schedules` (cron delivery with a condition), or a webhook target |
| Page-load / on-open actions | the trigger enum is `on-click`, `on-select`, `on-change`, `on-submit`, `on-close`, `on-reset`, `on-context-menu-click`, CTA clicks. Pages have no `actions` field | a button, or a control default value |
| Page-level "Call agent → Notify and export" sequences | UI-only; dropped on write | build the schedule in the UI |
| Agent tools that set a range control | verify: "range controls are not supported" | one list or segmented control per bound |
| Typed or optional agent-tool inputs | `agent-input` is only `{type, inputName}`; a blank input errors the step | one tool per control, plus a clear tool |
| Running UI-state agent tools over REST | `POST /v2/workbooks/{id}/agents/{agentId}` runs data-write tools (`insert-rows`) but does not offer `set-control-value` / `navigate` tools at all | test those in the UI or the embed |
| Static greeting `suggestions` | accepted and silently dropped on GET | put the suggested questions in the greeting `message` |

## Layout and content

| Not supported | Evidence | Do this instead |
|---|---|---|
| Per-card data binding in a repeated container | the repeater has no `name` field; `{{[<repeater> repeated container/col]}}` (the form UI GET-backs show) and `{{[Repeated container/col]}}` are both rejected with `Dependency not found`; `{{[Source/col]}}` passes but every card renders "Multiple values" | bind per-card text in the UI, or use a grouped table with conditional formats |
| Data elements inside a repeated container | `element kind '<kind>' cannot be placed inside a repeated container` (tables, KPIs, charts, controls, chat) | text + `{{formula}}` only (and per-card binding is UI-only, above) |
| Transpose / unpivot in a workbook element | `source.kind: transpose` on a `table` now verifies, saves and round-trips, but the element query fails ("Could not get query") and renders 0 rows / 0 columns | unpivot in the data model or in custom SQL (`UNPIVOT` / `UNION ALL`) |
| Styling a text element's box | `style` on `text` passes verify, then is stripped on GET (no background renders) | put the text in a styled `container` |
| Markdown tables in text | newlines are collapsed on save, so the table renders as literal pipes | a `table` element, or an HTML-free list |
| `font-weight` in text spans | rejected: spans allow only `color`, `background-color`, `font-size`, `font-family` | markdown `**bold**` |
| Gradients in `backgroundColor` | rejected (with a misleading `style.padding` error) | a data-URI SVG `backgroundImage` |
| Panels other than header and sidebar | `type: drawer / left / right / filter` rejected | drawers are overlays (`overlays[]`) |
| Page controls in header/sidebar panel text | `{{[Control]}}` in a panel renders "Invalid Query: Unknown column"; the same text on the page works | echo the control into a one-row helper table and reference that |
| Column widths on a regular table | no width field on `table` columns (only on `pivot-table` via `display.headerWidths` / `bodyWidths`) | let it auto-size, or use a pivot table |
| Status pills in table cells | no cell-shape option; `conditionalFormats` colours the cell only | conditional formats, or glyph text (`●`, `▲`) |
| `direction` on a stack `<Container>` | `unsupported stack Container attribute "direction"` on write, even though GET shows `<Style><Desktop direction="row"/>` | omit it (default is row), or use a grid container |

## Charts

| Not supported | Evidence | Do this instead |
|---|---|---|
| More than one bar series in a combo chart | `[bar, bar, line]` comes back `[bar, line, line]` | a plain `bar-chart` for grouped bars, with the line as a separate chart or a reference mark |
| Stacking in a combo chart | `stacking` is dropped on GET | a stacked `bar-chart` |

## Formulas and data models

| Not supported | Evidence | Do this instead |
|---|---|---|
| A `Path()` hierarchy function (Power BI `PATH`) | compiles to `'Unknown function Path'` | a recursive SQL bridge table |
| A data-model metric referencing another metric | the model accepts it; workbook KPI compiles to `Reference to errored column "[Metrics/…]"` | repeat the base aggregate inside each metric |
| A metric traversing a relationship | compiles to a keyless `CROSS JOIN`; `CountDistinct([Dim/Manager])` returned 0 against a truth of 2 | `Lookup()` the value onto the fact first (`gotchas.md` #4) |
| A metric reading a workbook control | compiles to `Reference to errored column` | a workbook-level formula over the data-model element |
| A grouped table as a new grain for children | children query the ungrouped rows (`gotchas.md` #6); `Sum` of a per-group total returned 2,000 against 1,000 | publish allocation columns, or a separate pre-aggregated element |

## Fixed since earlier versions of this skill — do not design around these

Verified working on 2026-10-19:

- `navigation` element kind (since 2026-10-06).
- `conditionalFormats` on `table` **and** `input-table` (`{type: single, columnIds, condition, value, style}`).
- `tabBar.alignment` (`left` / `center` / `right` / `justify` — not `start` / `end`).
- `legend.visibility: shown`.
- Stack-container children appear in the layout GET-back.
- A linked input table's formula can reference its link source (`[Source/col]`), compiled as a per-key lookup.
- `/spec/verify` catches stale control-filter targets and agent `dataSources`.
- PNG export renders header panels.
- Workbook control filters on a data-model relationship-key column apply.
- Pivot custom grand totals: `axisTotals: [{axisId: grand-column-total, calculations: [{columnId, formula}]}]`, which fixes the summed-stock-measure total.
- REST agent runs execute data-write action tools (not control/navigation tools).
- `/mcp/v2` accepts a client-credentials token on a Sigma staging environment.
- API-authored `**bold**` text survives GET→PUT (loss seen earlier may be UI-authored text only).
