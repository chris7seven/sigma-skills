# Actions

The **actions framework** — how an element responds to a user gesture (a button click, a viz selection, a modal CTA) by running an ordered list of effects. Actions attach to element variants (buttons, viz/data elements, images); for the full nested shape of any effect, use the enumeration recipe under **Effects** below.

## Model

Each action-hosting element carries an `actions` array. Every entry is a **sequence**: an `id`, a `trigger`, and an ordered `effects` array. On the wire, actions are stored at the workbook level but read and written **projected onto their host element**, so you author them inline on the element. Effects this Sigma version doesn't model are dropped-with-a-warning on read — a read never fails on an unknown effect.

> **Every sequence requires a stable `id`** (unique across the workbook's actions), preserved verbatim across read and write. When editing a spec you `GET`, keep the ids you read back. `id`, `trigger`, and `effects` are all required.

```yaml
actions:
  - id: open-docs # required, workbook-unique
    trigger: on-click # must match the host (see below)
    effects:
      - effect: open-url # discriminator is `effect`
        url: https://example.com/docs
        openTarget: _blank
```

## Hosts and triggers

`trigger` is one of `on-click`, `on-select`, `on-primary-cta-click`, `on-secondary-cta-click`, `on-close` (current set — enumerate the live list from the codec, see **Effects**). A host rejects a trigger that doesn't match its kind.

| Host                                                                      | Trigger                                                      |
| ------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `button` element                                                          | `on-click`                                                   |
| `image` element                                                           | `on-click`                                                   |
| Any viz / data element — `table`, `pivot-table`, every chart and map kind | `on-select`                                                  |
| Modal page                                                                | `on-primary-cta-click`, `on-secondary-cta-click`, `on-close` |

### `button` element

The canonical actions host. Shape: `kind: button`, `id`, `name`, `text`, plus styling (`appearance`, `align`, `size`, `borderRadius`, `fillColor`, `fontColor`, `fontWeight`).

```yaml
- id: submit-btn
  kind: button
  name: Open dashboard
  text: Open dashboard
  actions:
    - id: btn-open-docs
      trigger: on-click
      effects:
        - effect: open-url
          url: https://example.com/docs
          openTarget: _blank
```

### `image` element

Also an `on-click` host — configure image click navigation with an on-click `open-url` effect (see `content-elements.md` for the image element shape).

### viz / data elements

Any table, pivot, chart, or map fires `on-select` when the user selects a mark or row. Selection-scoped value sources are available here (see **Selection scope**).

## Effects

Each effect is `{ effect: <kind>, ... }` — the discriminator field is **`effect`** (not `type`). The table below is the **current** set — new effect kinds are added over time. Enumerate the live set (and the live trigger set) from the codec rather than assuming this table is exhaustive:

```bash
# all effect kinds currently modeled:
jq -c '[.. | objects | select(.properties?.effect?.enum?) | .properties.effect.enum[0]] | unique' /tmp/sigma-api.json
# all triggers currently modeled:
jq -c '[.. | objects | select(.properties?.trigger?.oneOf?) | .properties.trigger.oneOf[].enum[0]] | unique' /tmp/sigma-api.json
# then read one effect's required fields:
jq -c 'first(.. | objects | select(.properties?.effect?.enum? and (.properties.effect.enum[0]=="<effect>")))' /tmp/sigma-api.json
```

Required fields per kind:

| `effect`            | Required fields                  | Notes                                                                                            |
| ------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------ |
| `open-url`          | `openTarget`                     | `openTarget` is `_self` / `_blank` / `_parent`; optional `url` is the destination.               |
| `set-control-value` | `control`, `value`               | `value` is a tagged union (see below); optional `selectionMode` is `replace` / `add` / `remove`. |
| `clear-control`     | `scope`                          | `scope` selects a control, container, page, or the whole workbook; optional `usePublishedValue`. |
| `insert-rows`       | `table`, `values`                | Insert a single row into a **non-linked** input table.                                           |
| `update-rows`       | `table`, `whichRows`, `values`   | Supports a **linked** input table as its target.                                                 |
| `delete-rows`       | `table`, `whichRows`             | **Rejects a linked table.**                                                                      |
| `refresh-element`   | `target`                         | `target: { type: element, element: <id> }`.                                                      |
| `open-overlay`      | `overlayId`                      | Opens a modal page by its page id.                                                               |
| `close-overlay`     | —                                | Closes the current modal.                                                                        |
| `select-tab`        | `tabbedContainer`, `selectedTab` | Switch the active tab of a `tabbed-container` element (see `layout.md`).                         |
| `navigate`          | `target`                         | Jump to a regular page or a specific element **within this workbook** — see below.               |
| `open-document`      | `document`, `openTarget`, `documentType` | Open a **different** workbook or report by inode id — see below.                        |

> `open-url`'s `url` supports `[Selection/<Column>]` formula references inside an `on-select` action (see **Selection scope**).

> **This table covers every effect currently reachable via the spec API** — verified against the actual accepted-effects union in the codec (`Action.ts`'s exported `EffectCodec`), not just this skill's own prior list. A few effects that sound plausible (e.g. an agent-invocation effect) have a codec file written but are not yet wired into that union, so they reject at `POST` even though they exist in code — don't assume a effect is usable just because you found a reference to it somewhere in the codebase; confirm it's actually in the accepted union or verify live.

### `navigate` — jump to a page or element in this workbook

The only effect for going to a **regular** page (as opposed to `open-overlay`'s modal pages or `select-tab`'s in-page tab switch). Put it on a button's `on-click` for a "See details →" style call-to-action that leaves the current page, as an alternative to a persistent `navigation` menu element (`content-elements.md`) when the jump is a one-off action rather than a standing nav bar.

```yaml
effect: navigate
target:
  type: page
  page: <target-page-id>
```

`target` is a tagged union: `{ type: page, page: <id> }` or `{ type: element, element: <id> }`. The element form scrolls to/focuses that element rather than changing pages — useful on a long single page. This `target` shape is specific to `navigate`; don't assume other effects with a `target` field (e.g. `refresh-element`, above) accept the same variants — `refresh-element`'s target is element-only.

### `open-document` — open a different workbook or report

`navigate`'s cross-document counterpart — opens another workbook or report by its inode id, rather than a page within this one.

```yaml
effect: open-document
document: <inode-id-of-the-other-workbook-or-report>
documentType: workbook # or report
openTarget: _blank # _self / _blank / _parent, same as open-url
```

Optional `target` (same `{ type: page, page: <id> }` / `{ type: element, element: <id> }` shape as `navigate`) opens directly to a page or element inside the *other* document — its id lives in that document, not this one, and isn't validated against anything here, so a typo produces a silent no-op rather than a spec-time error. Optional `targetControls` (a map of the target document's control names to values, same value shapes as `set-control-value`) pre-populates controls in the opened document.

### `value` sources (set-control-value, insert/update-rows)

A value is a tagged object `{ type, ... }`. `type` is one of: `constant`, `control`, `formula`, `column`, `column-range`, `formula-range`, `agent-input`, or a typed literal (`text` / `number` / `date` / `boolean` and their `-list` / `-range` variants). `column` / `column-range` and `[Selection/…]` formulas are only valid under `on-select` (see below).

### `whichRows` (update-rows / delete-rows)

A tagged object selecting target rows: `single-row` (match by `primaryKeys`), `current-row` (the row the trigger fired from — the host must sit in the target table's dataflow), `formula` (a boolean), or a column where-clause. Inspect the spec for the exact per-variant shape.

```yaml
- id: mark-reviewed
  trigger: on-select
  effects:
    - effect: update-rows
      table: orders-it
      whichRows: { type: current-row }
      values:
        status: { type: constant, value: reviewed }
```

## Modal & drawer pages

Modals and drawers are **not** part of `document.pages` anymore — they live in their own top-level `document.overlays` array, discriminated by `type: modal` | `type: drawer`. An overlay is `{ id, type, name }` plus an optional `modal` config (`width`, `header`, `footer`) or `drawer` config (`width`, `header`, `position`, `showShadow` — no `footer`), and its own `actions`. Its content elements live in the same flat `document.elements` array as everything else, placed into it via a `<Page id="<overlayId>">` block in `layout` — an overlay's `id` doubles as the layout page id for this purpose. Open and close either kind with the `open-overlay` / `close-overlay` effects; the overlay-scoped triggers (`on-primary-cta-click`, `on-secondary-cta-click`, `on-close`) fire actions defined on the overlay itself.

```yaml
document:
  elements:
    - id: open-detail
      kind: button
      text: Details
      actions:
        - id: show-detail
          trigger: on-click
          effects:
            - effect: open-overlay
              overlayId: detail-modal
    - id: modal-body-text
      kind: text
      body: Detail content goes here.
  pages:
    - id: main
      name: Overview
  overlays:
    - id: detail-modal
      type: modal
      name: Detail
      modal:
        width: medium
        header: { title: Details }
        footer: { primaryCta: { text: Done } }
      actions:
        - id: modal-close
          trigger: on-primary-cta-click
          effects:
            - effect: close-overlay
  layout: |
    <?xml version="1.0" encoding="utf-8"?>
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="main">
      <Element elementId="open-detail" gridColumn="1 / 13" gridRow="1 / 4"/>
    </Page>
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="detail-modal">
      <Element elementId="modal-body-text" gridColumn="1 / 25" gridRow="1 / 4"/>
    </Page>
```

The overlay's title (`Details`, shown in the modal header above its content) comes from `modal.header.title` / `drawer.header.title` — the overlay's own top-level `name` is an internal label, not what the viewer sees.

## Selection scope (`on-select` only)

An `on-select` action can reference the selected row: a `column` / `column-range` value source, and `[Selection/<Column>]` formula references inside a value or a URL.

```yaml
- id: drill-region
  trigger: on-select
  effects:
    - effect: set-control-value
      control: region
      value:
        type: formula
        formula: "[Selection/Region]"
```

> `[Selection/…]` binds **only** inside an `on-select` action. Elsewhere it stays unbound rather than erroring — a stray `[Selection/…]` silently resolves to nothing.

## Agent inputs

A value source of `type: agent-input` is reserved for agent-driven actions. On a regular element or modal action it is rejected.
