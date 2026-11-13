# Workbook Spec — Top-Level Schema

Recipe + reference for the overall shape of the top-level workbook spec object. The full schema lives in the OpenAPI:

```bash
jq '.components.schemas.CreateWorkbookSpec' /tmp/sigma-api.json
```

This file covers what the OpenAPI alone won't tell you: the `document` envelope, which fields are response-only (ignored on write), the page and ID rules, and a minimal working example. See the per-element and per-source reference files for the shape of an individual entry in `document.elements[]`.

## Top-Level Object

The object passed to `POST /v2/workbooks/spec`. The spec content lives under a **`document`** envelope — a sibling of the workbook metadata (`name`, `folderId`, `description`):

```yaml
name: My Workbook
folderId: <folder-uuid>
description: Optional description
document:
  kind: workbook # document kind discriminant
  schemaVersion: 1
  elements: [...] # flat array of literal element definitions
  pages: [...] # page METADATA only -- no elements here, see "Pages" below
  overlays: [...] # optional -- modal/drawer definitions (see actions.md)
  layout: | # grid layout XML -- effectively required once there are elements, see below
    <?xml ...?>...
  themeName: Dark # optional workbook theme
  themeOverrides: { ... } # optional partial theme customizations
  agents: [...] # optional workbook-level agents (see chat.md)
```

**Required:** `name`, `folderId`, `document` (with `kind: workbook`, `schemaVersion`, `elements`, and `pages`).
**Optional (top level):** `description`. **Optional (inside `document`):** `overlays`, `themeName`, `themeOverrides`, `agents`. `layout` is nominally optional in the schema, but every element in `elements` must be placed somewhere in it — a spec with any element and no layout placement for it is **rejected** (`element '<id>' is not placed in layout`). In practice, write `layout` whenever `elements` is non-empty.

> **Elements are a flat, top-level array — not nested inside `pages`.** This is a recent breaking change: `document.pages[].elements` is rejected outright (`document.pages[].elements is no longer supported. Move elements to document.elements instead.`). An element's page (or panel, or modal/drawer overlay) is now determined entirely by **where its `elementId` is placed in `layout`** — see `layout.md` and "Pages" below. `document.kind` is always `workbook` here; reports reuse the same `elements`/`pages`/`layout` pattern with a different `kind` (see `sigma-reports`, out of scope for this skill).

### Theming (inside `document`)

- `themeName` selects a built-in theme (`Light` | `Dark` | `Surface`) or an org theme by UUID.
- `themeOverrides` layers partial customizations on top (color scheme, fonts, layout style, table styles). Read emits only values explicitly stored, so a round-tripped `themeOverrides` shows just what was set. Inspect the spec for its full shape:

  ```bash
  jq '.components.schemas.CreateWorkbookSpec | .. | objects | select(has("themeOverrides")) | .properties.themeOverrides' /tmp/sigma-api.json
  ```

Use the `schemaVersion` returned by `GET /v2/workbooks/<reference-workbook-id>/spec` in Step 2 of the workflow — don't hardcode it. The server will reject a spec whose `document.schemaVersion` doesn't match what the API expects.

## Response-Only Fields

`GET /v2/workbooks/<id>/spec` returns these server-managed fields at the **top level** (alongside `name`, `description`, `document`). They're **ignored** on write (POST/PUT), so you don't have to strip them before re-submitting a GET response — though it's cleaner to:

- `workbookId`
- `url`
- `documentVersion`
- `latestDocumentVersion`
- `ownerId`
- `createdBy`
- `updatedBy`
- `createdAt`
- `updatedAt`

## Pages

`document.pages` holds page **metadata only** — no `elements` array:

```yaml
id: page-1
name: Overview
visibility: shown # optional: "shown" (default) | "hidden"
```

Which elements appear on a page is determined entirely by `layout` — see `layout.md` for the placement grammar. A page with no elements placed on it is valid (an empty page).

Modal and drawer pages are **not** defined here anymore — they moved to their own top-level `document.overlays` array. See `actions.md` for how overlays open/close and how their content is placed.

`visibility: hidden` keeps the page in the workbook (so other elements can `source` from its tables via `elementId`) but excludes it from the viewer. See `reference/workflows/composition.md` for when to reach for this.

A page can also be **restricted to specific users and teams** via an object form instead of the simple shown/hidden:

```yaml
visibility:
  kind: specific-users-and-teams
  assignments:
    users: [<userId>] # optional
    teams: [<teamId>] # optional
```

Both `users` and `teams` are optional, and an empty allowlist is permitted.

Don't confuse the object form's `specific-users-and-teams` discriminator with the *column-level-security* rule's criteria of the same name (`sigma-data-models`'s `column-level-security.md`), which is a differently-shaped **array** of `{ type: "user"|"team", userId|teamId }` entries for a completely different feature — the two share a discriminator string but nothing else, and guessing the array form here fails.

## ID Rules

- Element IDs and column IDs must be unique within their scope.
- Use descriptive kebab-case or short random-looking IDs — both are fine. IDs are internal identifiers, not displayed to users.
- IDs you submit are **preserved verbatim** on `POST` — pages, elements, and columns keep the `id` values you sent, and layout `elementId` references stay valid. You can edit your saved spec and `PUT` it back directly. Every `elementId` referenced in `layout` must match an `id` in `document.elements` exactly (case-sensitive) — that match is what assigns the element to a page in the first place, not the other way around.

## Minimal Working Example

The smallest spec that creates a workable workbook — note the `document` wrapper, the flat top-level `elements`, the metadata-only `pages` entry, and that `layout` is where `sales-table` actually gets attached to `page-1`:

```yaml
name: Sales Dashboard
folderId: <folder-uuid>
document:
  kind: workbook
  schemaVersion: 1
  elements:
    - id: sales-table
      kind: table
      name: Sales Data
      source:
        kind: warehouse-table
        connectionId: <conn-uuid>
        path: [SALES_DB, PUBLIC, ORDERS]
      columns:
        - id: col-order-id
          name: Order ID
          formula: "[ORDERS/order_id]"
        - id: col-amount
          name: Amount
          formula: "[ORDERS/amount]"
        - id: col-revenue
          name: Revenue
          formula: "[ORDERS/revenue]"
        - id: col-total
          name: Total Amount
          formula: Sum([Amount])
        - id: col-profit
          name: Profit
          formula: "[Revenue] - [Cost]"
  pages:
    - id: page-1
      name: Overview
  layout: |
    <?xml version="1.0" encoding="utf-8"?>
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-1">
      <Element elementId="sales-table" gridColumn="1 / 25" gridRow="1 / 20"/>
    </Page>
```

Note how:

- `[ORDERS/order_id]` references a warehouse column (table prefix required).
- `Sum([Amount])` references the "Amount" column defined in the same element (no prefix).
- `[Revenue] - [Cost]` references two other columns in the same element by their `name` field.
- `sales-table` is on `page-1` because `layout` places it there — nothing in `elements` or `pages` says so directly.

For how much to build for a given request, see `reference/workflows/composition.md`. If you're genuinely stuck on a multi-page, multi-element spec after following this skill's recipes, `GET /v2/workbooks/{id}/spec` on an existing workbook shows a real, current example (see the recovery-move callout in SKILL.md's workflow) — that's a fallback for when you're stuck, not the default way to see realistic structure.
