---
name: sigma-workbooks
description: >-
  Build, edit, and iterate on Sigma workbook specs — the JSON definition you
  POST to /v2/workbooks/spec, covering pages, layout, controls, charts, KPIs,
  tables, formulas, and sources. The Sigma OpenAPI is the source of truth for
  every shape and field; this skill adds navigation, style guidance, and
  proven recipes for effective dashboards. Use when the user wants to
  construct a dashboard from a spec, add or modify pages / elements /
  controls / formulas, validate a spec before submission, or work through
  the workbook spec lifecycle programmatically. Requires an SIGMA_API_TOKEN
  — obtain via the sigma-api skill first.
---

# Sigma Workbooks (Spec via REST API)

This skill helps you build effective Sigma workbooks by **navigating the Sigma OpenAPI** and applying **style guidance + proven recipes** beyond what the OpenAPI alone teaches.

## Scope

The workbook **spec** — the JSON you POST to `/v2/workbooks/spec` defining pages, elements, sources, formulas, and layout. Lifecycle around the workbook (embeds, grants, materialization schedules, bookmarks, sharing) is a separate API surface and out of scope here.

## Sources of truth

1. **`POST /v2/workbooks/spec/verify`** — the *arbiter*. Validates a representation
   without creating or modifying any workbook, and its error messages are better than
   the create endpoint's:

   ```
   body  {"name": "probe", "folderId": "<uuid>", "document": {...}}
   ->    {"valid": true}
   ->    {"valid": false, "errors": [{"summary": "Layout XML: unknown element <Tab> …
                                       (expected Element, Container, or TabbedContainer)"}]}
   ```

   **Settle every "is this shape legal" question here** rather than by creating and
   deleting probe workbooks. It validates the whole create payload, so omit
   `name`/`folderId` and you get errors about those instead of about your element.

2. **Sigma workbook-spec OpenAPI** — canonical schema for every request/response shape and field. It's the generated **code-representation** OpenAPI JSON, published at:
   `https://assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json`

   Rendered, more readable versions of the same thing, worth reading directly:
   - <https://help.sigmacomputing.com/reference/create-workbook-spec> — the request schema
   - <https://help.sigmacomputing.com/docs/workbook-representation-example-library> —
     worked representations per configuration
   - <https://help.sigmacomputing.com/docs/function-index> — the arbiter for **formulas**.
     Check a function name here before using it: unknown functions are accepted at write
     and fail at render (`Divide`, `Strftime` and `TotalOverAll` do not exist).

⚠️ **Presence in the OpenAPI `kind` enum does NOT mean a *minimal* probe will build it —
and a minimal probe's rejection does NOT mean the kind is unsupported.** The enum carries
~81 values, and the rejection for a genuinely unsupported kind and for a shape that's
just missing a required nested field are the **same** masked `Invalid kind: "<what you
sent>"` message. Two kinds got wrongly declared unbuildable this way in one session —
`tabbed-container` (needs `<TabbedContainer>`/`<Tab>` layout tags, not bare `<Element>`)
and `controlType: "date"`/`"date-range"` (need `mode`: `<=`/`=`/`>=` for `date`,
`between` for `date-range` — absent from a `{kind, controlType}` probe, and their absence
produces this exact message). `navigation` was long thought absent and has been valid since
2026-10-06. The verified list of what genuinely is not supported is in
`reference/specification/unsupported.md`.

**Before concluding a kind is unsupported:** pull that schema's `oneOf`/`allOf` branches
from the OpenAPI and read every nested `required` array — don't rely on a bare-minimum
probe. Then confirm the fully-specified shape against `/spec/verify`.

Everything in this skill is commentary, style guidance, and recipes layered on top of that source. **When this skill and the OpenAPI disagree, the OpenAPI wins — and when the OpenAPI and `/spec/verify` disagree, `verify` wins.** When a feature exists in the OpenAPI but isn't covered here, fetch the OpenAPI and use what it documents. An existing workbook on the user's org (`GET /v2/workbooks/{id}/spec`) is a real, faithful shape too — reach for it as a fallback when the OpenAPI is unreachable, or as a recovery move when you're genuinely stuck (see the callout in the workflow below); it's not a primary source to consult by default.

## Consulting the OpenAPI

The OpenAPI is the source of truth. **The field lists and examples in this skill are illustrative, not exhaustive** — when you need the complete, current shape of anything, query the spec. Fetch once per session and inspect with `jq`:

```bash
curl -s "https://assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json" > /tmp/sigma-api.json

# Verify the fetch actually returned JSON — a dead URL yields an HTML error page,
# which would otherwise make every jq below fail silently and the skill guess blindly:
jq -e . /tmp/sigma-api.json >/dev/null 2>&1 \
  || echo "⚠️ spec fetch did not return JSON — check network access to assets.sigmacomputing.com, then fall back to GET /v2/workbooks/{id}/spec on a real workbook"

# The workbook write body — spec content lives under a `document` envelope:
jq '.components.schemas.CreateWorkbookSpec' /tmp/sigma-api.json
```

The top-level shape carries `name` / `folderId` / `description` and a **`document`** object (`kind: workbook`, `schemaVersion`, `elements` — a flat, literal array, not nested under `pages` — `pages` — metadata only — `overlays`, `layout`, `themeName`/`themeOverrides`, `agents`). Element, source, control, and format shapes are **inlined** and identified by their `kind` value (e.g. `bar-chart`, `kpi-chart`, `join`, `warehouse-table`), not by a top-level schema name. Navigate by the `kind` discriminator:

```bash
# List every kind the OpenAPI defines anywhere (elements, sources, controls, formats, …) — noisy, mixes in things that aren't elements:
jq -r '[.. | objects | select(.properties.kind.enum) | .properties.kind.enum[0]] | unique[]' /tmp/sigma-api.json

# List only the kinds valid in document.elements[] — an element is the one thing that requires both `id` and `kind` together, so this excludes nested source/control-value/visibility kinds that also happen to use the `kind` property:
jq -r '[.. | objects | select(((.required // []) | type == "array") and ((.required // []) | index("id")) and ((.required // []) | index("kind")) and .properties.kind.enum?) | .properties.kind.enum[0]] | unique[]' /tmp/sigma-api.json

# The full nested shape for one kind — swap bar-chart for any kind above:
jq --arg k bar-chart 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

`WebFetch` works for the JSON too. Either path is fine. If you can't fetch the OpenAPI, `GET /v2/workbooks/{id}/spec` on a real workbook is the reliable fallback — it returns the same shapes as live YAML/JSON.

For the chart kinds specifically (a subset of the elements list above), see `reference/specification/charts.md` (cartesian/pie family) and `reference/specification/maps.md` (geospatial family) — they group and document each one rather than just naming it.

**Why bother:** the API ships new fields and viz configurations regularly, and this skill covers the common surface, not every field. If you want a capability and don't see it documented here, **assume it may exist and check the spec before concluding it doesn't** — the `kind` query above answers in seconds.

## Auth

Authenticate via the `sigma-api` skill first to populate `$SIGMA_BASE_URL` and `$SIGMA_API_TOKEN`.

## Recommended Workflow

These are guidelines, not mandates — but they prevent the failure modes that show up most often when drafting from scratch.

> **Schema drift signal:** an error about request _shape_ (`invalid argument`, `unknown field`, `missing required field`, `unexpected property`) usually means this skill is stale on that detail. Fetch the OpenAPI and compare; the canonical shape is there.

### Step 0 — Authenticate, capture user identity

```bash
USER_ID=$(curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/whoami" | jq -r '.userId')

HOME_FOLDER_ID=$(curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/members/$USER_ID" | jq -r '.homeFolderId')
```

If the user provided a **target image** (a screenshot, mockup, or PDF of a dashboard they want reproduced), pause here and load `reference/workflows/from-image.md` — it adds explicit observation, description, and validation steps that have to happen _before_ normal data discovery. The standard workflow alone tends to produce workbooks with the right vibe but the wrong shape when the input is visual.

If the reference is an **HTML mockup** (or a PBIX/PBIR export, or any artifact the customer wants reproduced), also load `reference/workflows/parity-reconciliation.md` and write the inventory to a `PARITY-<name>.md` file **before building**. An inventory that lives only in a chat reply evaporates, and later restructures then drop already-built features silently. Reconcile against that file at the end of every build pass — not just the first.

> **Stuck, not just iterating?** Draft from this skill's own recipes and the OpenAPI first — that's the default path, every time, org-empty or not. Reach for an existing workbook as a reference **after** a couple of real attempts still won't validate or render the way the customer wants and this skill hasn't explained why: `GET /v2/workbooks?limit=50` to list, then `GET /v2/workbooks/{id}/spec` on one that looks similar, and study its actual structure directly. YAML is the canonical format for specs in this skill (`Accept: application/yaml` is the GET default; use `yq` on it the way you'd use `jq` on JSON) — look at source structure, column ID patterns, formula syntax, element naming, and layout idioms. Treat this as a recovery move for when you're genuinely stuck, not a starting point.

### Step 1 — Discover data sources

Load `reference/workflows/discover.md`. Quick summary:

1. `GET /v2/connections` — find the user's connection by name or type.
2. Ask the user for the table path; verify with `POST /v2/connection/<id>/lookup`.
3. Discover columns directly via `GET /v2/connections/tables/{inodeId}/columns` (full mechanics in `reference/workflows/discover.md`). Only fall back to asking the user when the endpoint doesn't return what's needed.

**Never invent column names** — only use names returned by the API or supplied by the user.

**Verify literal values before writing predicates.** If your task involves filtering on a categorical column (e.g., `CountIf([Status] = "active")`, `If([Type] = "sale", ...)`), you need to know what values that column _actually_ contains — the `/v2/connections/tables/{inodeId}/columns` endpoint gives you names and types but not values. Run a `SELECT DISTINCT <col>` via any tool that reaches the warehouse — an MCP server (warehouse or [Sigma](https://help.sigmacomputing.com/docs/use-sigma-mcp-server)), a SQL CLI, or just ask the user. Don't guess literals. See `reference/workflows/discover.md`.

### Step 2 — Identify features and load only what you need

Map the user's request to the **Reference Index** below. State the features you identified, then read the listed reference files before drafting. **Rows marked "Always" load regardless of what the request matches** — this includes `gotchas.md` and `style.md`, which is how a workbook comes out correct *and* polished without the user having to ask for either separately. **If the user asks for a feature this skill doesn't cover**, fetch the OpenAPI and inspect the relevant schema.

### Step 3 — Draft the spec to a local file

Write the spec YAML to disk (e.g., `/tmp/workbook-spec.yaml`). YAML is preferred over JSON in this skill — easier to read, diff, and comment for human review. The API accepts either; pick YAML unless something downstream specifically needs JSON. Key rules:

- Every element needs a unique `id` and a descriptive `name`.
- Every column needs a unique `id`, a `name`, and a `formula`.
- Follow the formula reference rules in `reference/specification/formulas.md` exactly — most spec errors happen here.
- **Write explicit `layout` XML for multi-element workbooks.** Auto-arrange (omitting `layout`) is acceptable only for single-element pages or a uniform stack of tables. See `reference/specification/layout.md` for the rubric.
- Start with 1–2 pages. Add more later via update.

For **create**, the file must include top-level `name` and `folderId`, plus a **`document`** object holding `kind: workbook`, `schemaVersion`, `elements` (flat, literal element definitions — not nested under `pages`), and `pages` (metadata only). `description` is optional (top level); `overlays`, `themeName`/`themeOverrides`, and `agents` are optional inside `document`. `layout` is nominally optional but effectively required — every element in `elements` needs a placement in it, or the write is rejected (`element '<id>' is not placed in layout`). `schemaVersion` is usually `1` — that's the current value; it may change in the future, so if the API rejects the spec on that field, GET an existing workbook's spec and use whatever `schemaVersion` it returns instead. Full CRUD mechanics are in `reference/workflows/crud.md`.

### Step 4 — Validate the spec

**Run the bundled validator first — do not skip.**

```bash
./scripts/validate-spec.sh /tmp/workbook-spec.yaml
```

Then do the manual formula pass and final shape checks per `reference/workflows/validate.md`. Fix everything reported before continuing.

### Step 5 — Create the workbook

```bash
curl -s -X POST -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/yaml" \
  -H "Accept: application/yaml" \
  --data-binary @/tmp/workbook-spec.yaml \
  "$SIGMA_BASE_URL/v2/workbooks/spec" > /tmp/create-response.yaml

WORKBOOK_ID=$(yq -r '.workbookId' /tmp/create-response.yaml)
cp /tmp/workbook-spec.yaml "/tmp/workbook-spec-${WORKBOOK_ID}.yaml"
```

Persist the spec after a successful create so subsequent `PUT` updates can start from it. Report **both** the workbook URL **and** the saved spec path.

If creation fails, read the error, fix the spec, re-validate, retry. See `reference/workflows/validate.md` for decoding cryptic errors.

### Step 5b — Verify the workbook actually compiles

**Do not skip.** A successful POST is necessary but not sufficient for *bare*, unprefixed column references (`[ColumnName]`) — Sigma accepts a spec where one doesn't resolve, then surfaces the failure at query time by embedding the error as a string literal in the compiled SQL (`'Unknown column "[X]"'`, `'Circular column reference to [Y]'`). Affected elements render empty in the UI. Only Sigma's compiler knows whether a bare reference actually resolves. (A bad *prefixed* reference — `[SourceName/column]`, the more common case — fails immediately at POST instead; see `reference/specification/formulas.md`.)

```bash
./scripts/verify-workbook.sh "$WORKBOOK_ID"
```

If any element reports `[FAIL]`, fix the column formulas in the spec (most often a missing source prefix, a self-referencing column, or a friendly-name mismatch with the warehouse — see `reference/specification/formulas.md`), `PUT` the corrected spec, and re-verify.

### Step 6 — Iterate

After initial creation, use `PUT /v2/workbooks/<id>/spec` to add pages or refine the workbook.

> **IDs are preserved on CREATE.** The `id` values you POST (pages, elements, columns) are kept verbatim, and `layout` `elementId` references stay valid across edits. **On a new incoming request against an existing workbook, always `GET /v2/workbooks/<id>/spec` first** — even if a saved copy from an earlier turn is on disk — and edit that fresh copy. The workbook may have changed since your last save (UI edits, another session, a teammate). Only skip the GET when you are still mid-iteration on the same edit within this turn. See `reference/workflows/crud.md`.

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Accept: application/yaml" \
  "$SIGMA_BASE_URL/v2/workbooks/<workbook-id>/spec" \
  > /tmp/current-spec.yaml

# Edit /tmp/current-spec.yaml, then:
curl -s -X PUT -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/yaml" \
  -H "Accept: application/yaml" \
  --data-binary @/tmp/current-spec.yaml \
  "$SIGMA_BASE_URL/v2/workbooks/<workbook-id>/spec" | yq .

cp /tmp/current-spec.yaml "/tmp/workbook-spec-<workbook-id>.yaml"
./scripts/verify-workbook.sh "<workbook-id>"
```

### Step 7 — Report back

**If this build came from a reference artifact, reconcile against `PARITY-<name>.md` first** (`reference/workflows/parity-reconciliation.md`): screenshot every page, update each row's status, fix anything that regressed from ✅ to ❌ in this pass, and report the counts plus the explicit remaining list. Do not imply completeness.

Report the workbook URL and the saved spec path. **Do not tack on generic "improvement ideas" or "next steps."** Match the response to what was asked.

Surface follow-up items only when they're load-bearing, and name them concretely:

- **Tradeoffs you made during the build** — dropped a chart, simplified a formula, skipped a control because the shape wasn't in your reference.
- **Obvious gaps revealed by the column list** — e.g., the user asked for "sales by region" and the table has a `region_tier` column that would make the breakdown richer. One sentence, named.

If none apply, just report the URL + spec path and stop.

## Reference Index

The reference is feature-sliced — don't read every file up-front. The index has three sections: **elements** (the visual / interactive pieces), **sources** (where each element gets its data), and **cross-cutting** (formulas, layout, formatting, validation, CRUD).

Element, source, and formula reference files in this skill also apply to **report specs** (`sigma-reports` skill) — reports share the same common element kinds; only layout and page structure differ.

### Elements

| File                                          | When to load                                                                                                                                                                                                                                                                                                    |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reference/specification/tables.md`           | Table element, tabular data, data grid, spreadsheet-style list. Also element-level filters (top N, limit, rank), groupings (pivot, group by), the `pivot-table` element kind, frozen columns, column images, and `conditionalFormats` (threshold-based cell coloring). Editable `input-table` has its own file. |
| `reference/specification/charts.md`           | Chart, graph, visualization, line / bar / column / stacked / grouped / combo / donut / pie / scatter / waterfall / share-of / breakdown. Cartesian axes, color channel, trellis, trendlines, reference marks. Also the `progress` gauge element.                                                                 |
| `reference/specification/maps.md`             | Map visualizations — `geography-map` (GeoJSON shapes), `point-map` (lat/long bubbles), `region-map` (states / counties / countries).                                                                                                                                                                            |
| `reference/specification/kpis.md`             | KPI, stat, big number, single value, metric card — including period-over-period comparison and trend sparkline.                                                                                                                                                                                                 |
| `reference/specification/controls.md`         | Filter, dropdown, picker, multi-select, date range, date picker, text filter, number range, slider, segmented, hierarchy.                                                                                                                                                                                       |
| `reference/specification/content-elements.md` | The non-data elements — `text` (Markdown + inline styling), `image`, `divider`, `page-break`, `embed` (external URLs), `button`, `navigation`. Titles, callouts, logos, rules, page breaks, embedded content, action buttons, nav menus.                                                                                                    |
| `reference/specification/input-tables.md`     | Input table — editable, warehouse-backed grid. Input modes, column kinds (storage / formula / system / key), validation (select / range / pills / file upload), empty vs linked sources.                                                                                                                        |
| `reference/specification/plugin.md`           | Plugin element — embed a custom plugin (e.g. D3 viz) and wire its inputs via `config`.                                                                                                                                                                                                                          |
| `reference/specification/chat.md`             | Chat element + top-level `agents` (instructions, data sources, tools, greeting); a chat binds to an agent by `agentId`.                                                                                                                                                                                         |

### Sources

| File                                           | When to load                                                                                                                                                          |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reference/specification/sources-warehouse.md` | Always — load before drafting any spec. Warehouse-table source (Snowflake, BigQuery, Databricks, Redshift, Postgres/MySQL).                                           |
| `reference/specification/sources.md`           | Reference another chart/table/element, derive from existing element, join, combine tables, data model / semantic-layer source, custom SQL, union, transpose, unpivot. |

### Cross-cutting

| File                                    | When to load                                                                                                                                                                                                                      |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reference/specification/schema.md`     | Always — load before drafting any spec. Top-level shape, required fields, response-only fields to strip.                                                                                                                          |
| `reference/specification/formulas.md`   | Always — load before drafting any spec. Formula syntax, qualification, special characters, the #1 mistake.                                                                                                                        |
| `reference/specification/formatting.md` | Format, currency, percentage, date format, decimals — column formatting.                                                                                                                                                          |
| `reference/specification/layout.md`     | **Always load for multi-element workbooks.** `document.layout` XML, Container/Element, container / tabbed-container / repeated-container elements, page visibility / background, auto-arrange fallback rules, when to write explicit layout vs. omit. |
| `reference/specification/actions.md`    | Interactivity — buttons, on-click / on-select triggers, effects (open URL, set / clear control, insert / update / delete rows, refresh, open / close modal overlays), modal pages, selection scope.                               |
| `reference/specification/gotchas.md`    | **Always — load before drafting any spec.** 19 failure modes that return HTTP 200 and then a wrong or blank number — things the OpenAPI cannot tell you (`Divide()` doesn't exist, a grouped-table `Sum()` multiplies, `Text()` strips formats, the masked `Invalid kind` error, and more). Read once per session; recognise the rest as they bite. |
| `reference/specification/unsupported.md` | The user asks for something that may not be buildable, or you're about to tell a customer "the API can't do X". The verified list of unsupported capabilities, each with the workaround, plus what has been fixed since earlier versions of this skill. Re-probe any row before designing around it. |
| `reference/specification/style.md`      | **Always — load before drafting any spec.** Why a generated workbook looks assembled rather than deliberate: a brand kit before any element, every chart/table in a styled container, the eyebrow/headline/body text pattern, honest KPI comparisons, number formats defined once. This is capability the API has and won't apply on its own. |

### Workflows

| File                                 | When to load                                                                                                                                                                                                                                                                                                                            |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reference/workflows/discover.md`    | Finding connections, tables, and column names. Load before composing a new spec.                                                                                                                                                                                                                                                        |
| `reference/workflows/composition.md` | Open-ended design decisions — calibrating workbook complexity to the request, when to ask the user, what to ask, surfacing structural choices in the final summary, and a few safe defaults (hidden source pages, ranked-table sort direction). Load before drafting anything when the prompt leaves significant design choices unmade. |
| `reference/workflows/crud.md`        | POST / GET / PUT against the workbook spec endpoints. Load when creating, retrieving, or updating a workbook.                                                                                                                                                                                                                           |
| `reference/workflows/validate.md`    | Pre-submit + post-create validation. Load before any POST or PUT.                                                                                                                                                                                                                                                                       |
| `reference/workflows/from-image.md`  | The user supplied a target image (screenshot, mockup, BI-tool export) to reproduce. Load _before_ discovery — it adds explicit observation and validation steps.                                                                                                                                                                        |
| `reference/workflows/parity-reconciliation.md` | Building from ANY reference artifact (HTML mockup, screenshot, PBIX/PBIR, Tableau). Persist a `PARITY-*.md` inventory and reconcile against it at the end of **every** build pass. Load alongside `from-image.md`, and again before reporting any build done.                     |

### Patterns

End-to-end recipes that compose several features. Load when the request matches the whole pattern, not just one element kind.

| File                                        | When to load                                                                                                                                                                                            |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reference/patterns/rls-and-personas.md`     | "Each rep should only see their own rows", "can I demo this as someone else", row-level security, a View-as / impersonation switcher. Includes the input-table RLS case, which needs a helper element. |
| `reference/patterns/ai-insight-text.md`      | "Add a summary/insight next to this chart", "explain what changed and why", automated commentary, AI summaries. The hidden-helper + `MaxIf` argmax idiom for a templated sentence; the `CallText`/Cortex version for model-generated narrative, including the one-row Close Facts pattern for multi-source prompts, model probing, and the prompt rules that stop the model misreading numbers. |
| `reference/patterns/forecast-narrative.md`   | "Add a forecast narrative", "tell me what we expect next month and why". Pairs with `charts.md`'s trend/projection guidance; the honest-caveat text pattern that keeps an extrapolation from being read as a model. |
| `reference/patterns/drilldown-columns.md`    | Every chart, KPI, and summary table by default, not just on request. Right-click drill-down only works on columns the element carries; charts carry **every** source column (the `carry_all_columns` loop), plus the unreferenceable-name and Lookup-target gotchas. |
| `reference/patterns/approval-workflow.md`    | Submit → approve → lock. Multi-level sign-off, approval inboxes, staleness after an edit, audit trail, and the honest answer on locking and notifications.                                              |
| `reference/patterns/example-data-app.yaml`   | A complete, round-tripped reference spec for a write-back app — input table + Row Context + RLS + agent tool + append-only approval tables + layout. Copy shapes from this when building any data app. |
| `reference/specification/example-full.yaml`  | A real multi-page reference spec (KPIs, charts, joins, controls, layout) — copy shapes from when in doubt.                                                                                               |
| `reference/specification/skeleton.yaml`      | Starting a fresh spec — minimal structural template (source table, KPI, bar chart, filter, layout) with no use-case opinion.                                                                            |

### What is possible in a write-back data app

Verified capabilities, so you don't have to rediscover the boundary:

**Can do from the spec API** — input tables (empty and linked); computed and control-driven formula
columns on input tables; buttons, modals and row-click actions; `insert-rows`; `update-rows` for a
single row *or* a formula predicate matching many; embedded AI agents with action tools that write
data; element-level filters for row-level scoping; persona impersonation; derived approval state
machines with audit trails.

**Cannot do from the spec API** (re-verified 2026-10-19) — seed input-table rows (no row-write
endpoint; all `/rows` paths 404); make a cell read-only by formula (no protect field); order
columns on an input table (storage columns are always placed before formula columns); fire an
event-driven notification (`/alerts` 404s — `/schedules` is cron delivery only); let an agent
write to an API-created input table before one UI publish ("Manual commit is not enabled").

Design around those rather than fighting them — `reference/patterns/approval-workflow.md`
shows the substitutions that hold up in front of a customer. The full list across every
feature area is `reference/specification/unsupported.md`.

## Quick Formula Rules

The single most common spec error is bare `[column_name]` references to warehouse columns. Full rules in `reference/specification/formulas.md`. Skeleton:

**Outside the element** — use `[SourceName/column_name]`:

- Warehouse-table source: `SourceName` = last segment of the `path` array (e.g., `[ORDERS/Revenue]`)
- Another element: `SourceName` = that element's `name`
- Join legs: prefix by the leg's `name`, or by the join's top-level `name` for `primarySource` columns
- `sql` source: `SourceName` is always the literal `Custom SQL`, and the column name is the **raw** SQL alias — not friendly-cased, the one exception to the casing rule below
- `data-model` source: `SourceName` = the data model element's own `name`

**Inside the same element** — use `[column_name]` (no prefix):

- References a column defined in this element by its `name` field.
- A column cannot reference itself (circular reference error).

## Troubleshooting

### "I don't see this field in the skill"

Fetch the OpenAPI. The skill documents stable, common surface area; the API has more. See **Consulting the OpenAPI** above.

### API schema mismatch (skill is stale)

A 400 about request _shape_ — `invalid argument`, `unknown field`, `unexpected property`, `missing required field` — usually means the API moved past the skill. Fetch the OpenAPI (see **Consulting the OpenAPI**), diff the live shape for that `kind`, and retry **once** with the correction. Tell the user it looks like the skill is out of date and worth updating through whatever channel they installed it from; don't loop on retries.

### 401 Unauthorized

Token missing or expired. Re-authenticate via `sigma-api`. If still failing, verify credentials and base URL.

### 403 Forbidden on workbook create

The credentials authenticated but aren't permitted to create workbooks here. Ask the user's Sigma admin to confirm the credential's permissions and folder access.

### "Invalid column reference" or formula errors on creation

The most common spec issue. A bare `[column_name]` was used where `[TABLE/column_name]` is needed. See `reference/specification/formulas.md` for the full rules and `reference/workflows/validate.md` for the manual checklist.

### "Unknown column" errors

The column name in the formula doesn't match what the warehouse actually has. Re-confirm the column names via `GET /v2/connections/tables/{inodeId}/columns` (raw warehouse names) and the readback (`GET /v2/workbooks/<id>/spec`, which shows Sigma's normalized friendly names). Use those names verbatim.

### `jq` or `yq` not installed

`jq` is used for OpenAPI inspection (the OpenAPI is JSON). `yq` is used for workbook-spec inspection (specs are YAML).

- `jq`: `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu).
- `yq`: **two different tools share this name** — the Go **mikefarah/yq** (`brew install yq`) and the Python **`pip install yq`** wrapper around jq. _Reading_ works the same in both (`yq -r '.workbookId' f.yaml`), but _in-place editing differs_: mikefarah uses `yq -i '…' f.yaml`, while the Python wrapper needs `yq -y -i '…' f.yaml`. Run `yq --help` to see which you have and adapt.

### Cryptic validation errors / silent bad data

See `reference/workflows/validate.md` for the full triage table (mapping `Invalid kind: document.elements[N]...` style errors to the right spec file).
