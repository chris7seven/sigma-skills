# Content Elements (text, image, divider, page-break, embed, button, navigation)

The non-data-bound elements — prose, images, rules, and embedded URLs. None take a `source`. Pull any kind's exact shape from the spec:

```bash
jq --arg k text 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
# swap k for image / divider / embed
```

These position in the page grid via `<Element>` like any other element — see `layout.md`.

## text

A Markdown block — titles, descriptions, section headers, callouts. Required `id`, `kind`, `body`; optional `verticalAlign` (`start` / `middle` / `end`) and `overflow` (`clip` / `scroll`). No `name`, no `source`.

```yaml
id: text-header
kind: text
body: |
  # Sales Overview

  A weekly view of revenue, with the regions driving the most growth.
```

(YAML's `|` block scalar keeps the body readable.)

### `body`: Markdown + inline styling

`body` is Markdown plus a small set of inline HTML for styling. Standard Markdown: paragraphs, `**bold**`, `*italic*`, headings (`#`, `##`, `###`), bullet / ordered lists, `[links](https://example.com)`, and `{{formula}}` / `{{ast | fmt}}` segments (same syntax as element titles, e.g. `{{Count() | ,.0f}}`).

**An unresolved `{{formula}}` reference fails silently, not at POST.** Unlike a column `formula:` field (rejected or flagged by `verify-workbook.sh`), a `{{…}}` segment that doesn't parse against a real source column is stored as literal text and rendered verbatim — no error, no `[FAIL]`, nothing to catch it. Verify by reading the spec back: a segment that actually resolved gets re-serialized with normalized spacing (`{{[Source/Col]|fmt}}` → `{{[Source/Col] | fmt}}` on readback); if your input echoes back byte-for-byte unchanged, it didn't bind.

**Control references now resolve inside `{{…}}` segments** (`{{[ControlId]}}`) — this used to be a silent-fail case like the above and has since been fixed. Verify the same way: an unresolved control ref echoes back unchanged on readback, a resolved one doesn't. **Exception:** in a header or sidebar *panel*'s text, `{{[ControlId]}}` still renders `Invalid Query: Unknown column` (verified 2026-10-19). Only page text can read controls.

**Not supported in `text` (verified 2026-10-19):**

- **Markdown tables.** Newlines inside the table are collapsed on save, so `| a | b |` rows render as one line of literal pipes. Use a `table` element.
- **`style` on the element.** `style: {backgroundColor: …}` passes `/spec/verify` and is then stripped on GET; nothing renders. Put the text inside a styled `container`.
- **`font-weight` in a span.** Rejected outright; use `**bold**`.

Inline styling via HTML — all round-trip through the spec and render:

- **Color / background:** `<span style="color: #8B0000">` and/or `background-color` — **hex values** (`#rgb` / `#rrggbb`).
- **Font size:** `<span style="font-size: 24px">`.
- **Font family:** `<span style="font-family: Georgia">` — a single family name that starts with a letter and contains only letters, numbers, spaces, underscores, or dashes. **No comma-separated fallback lists** — `"Georgia, serif"` is rejected.
- **Paragraph block styles:** `<p class="p-large">…</p>` and `<p class="p-small">…</p>`.
- **Alignment:** `<p style="text-align: center">…</p>` (also `left` / `right`).

A single `<span>` can combine properties (e.g. color + font-size). If a value violates its rule, the API rejects the whole `body` with a specific message naming the field — read it and fix the value.

Common pattern — bold + color (both supported):

```markdown
# **<span style="color: #8B0000">Deployments Dashboard</span>**
```

## image

Embeds an external image by URL (hosted only — no uploads). Required `id`, `kind`, `url`; `url` supports `{{formula}}` references for dynamic selection. An `alt` string and a `style` block exist too — pull the shape from the recipe. The image is also an **on-click actions host** (`actions`) — use an on-click `open-url` action for click navigation (see `actions.md`). Sizing comes from the layout grid, not the element.

```yaml
id: logo
kind: image
url: https://cdn.example.com/logo.png
```

## divider

A rule for separating sections. Required `id`, `kind`; optional `direction` (`horizontal` / `vertical`), `align`, and `style` (`color` / `width` / `strokeStyle`).

```yaml
id: section-rule
kind: divider
```

## page-break

A pagination marker — inserts a page break (used for print / PDF export layout). Minimal shape: just `id` and `kind`.

```yaml
id: pb-1
kind: page-break
```

## embed

Renders an external URL inline — a hosted report, form, video, etc. Required `id`, `kind`, `url`; `url` supports `{{formula}}` references.

```yaml
id: embed-report
kind: embed
url: https://example.com/report
```

## button

A clickable button whose purpose is to fire `on-click` actions. Required `id`, `kind`, `text`; optional appearance/layout fields — `appearance`, `align`, `size`, `borderRadius`, `fillColor`, `fontColor`, `fontWeight` — plus an `actions` array. The button does nothing on its own; wire behavior with an `on-click` action — see `actions.md` for triggers and effects.

```yaml
id: open-docs-btn
kind: button
text: Open dashboard
actions:
  - id: open-docs
    trigger: on-click
    effects:
      - effect: open-url
        url: https://example.com/docs
        openTarget: _blank
```

## navigation

A menu for moving between pages, workbooks, or URLs. Required `id`, `kind`, `mode` — a discriminated union with two branches, `manual` and `auto`.

**`mode: manual`** — a user-defined menu. Plus `options` (the menu entries, required, at least one), `showIcons` (boolean), and `style` / `optionStyle`. Each `options[]` entry is either a **link** (`{ label, destination, icon? }`) or a **submenu** (`{ label, submenu: [...], icon? }`).

**`destination` discriminates on `type`, not `kind`** — the only exception to this wire surface's usual discriminator field name, so don't assume it matches every other tagged union here. A same-workbook page link is:

```yaml
destination: { type: page, pageId: <target-page-id> }
```

For destinations other than a same-workbook page (another workbook, an external URL), pull the exact shape from the recipe below rather than guessing:

```bash
jq --arg k navigation 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

```yaml
id: nav
kind: navigation
mode: manual
showIcons: true
options:
  - label: Overview
    destination: { type: page, pageId: overview }
  - label: Reports
    submenu:
      - label: Sales
        destination: { type: page, pageId: sales-detail }
```

**`mode: auto`** — lists the workbook's own pages automatically instead of a hand-authored `options[]`; optional `pageLabels` (a map of `pageId` → override label, for pages that need a menu label different from their page name):

```yaml
id: nav
kind: navigation
mode: auto
pageLabels:
  overview: Home
```

**`auto` is the only mode that respects per-viewer conditional page visibility.** It reuses the same page-visibility resolution as Sigma's own default page-tab bar — each viewer's menu lists only the pages `visibility` actually includes them in (see `schema.md`'s page `visibility`). `manual` has no such awareness: an `options[]` entry pointing at a conditionally-visible page renders identically for every viewer regardless of whether they're on the allowlist, since it's just a fixed, hand-authored destination list. Prefer `auto` for a workbook with any conditionally-visible pages and no reason to hand-curate menu order/labels; reach for `manual` only when you need control `auto` can't give you (external links, submenus, cross-workbook links, a deliberately curated subset/order of pages).
