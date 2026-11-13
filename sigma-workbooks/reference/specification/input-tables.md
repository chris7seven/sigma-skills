# Input Tables

Recipe book for the `input-table` element — an editable, warehouse-backed grid whose cells users can type into. It shares almost all of its display surface with `table` (see `tables.md`); this file covers only what's specific to input tables.

Pull its exact shape from the spec:

```bash
jq --arg k input-table 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

## Basic shape

```yaml
id: notes-it
kind: input-table
name: Account Notes
inputMode: edit # REQUIRED: edit | explore | view
source:
  kind: empty
  connectionId: <conn-uuid>
columns:
  - { id: account, type: text }
  - { id: priority, type: number }
```

- `inputMode` is **required**. None of the three values are read-only — each opens writes to a different population, and the naming doesn't map onto Sigma's usual viewer/explorer/editor read-vs-write intuition:
  - `edit` — only a workbook **editor**, and only while actively editing the workbook (not in published view). Fits a small reference/config table the workbook's owner maintains as part of authoring it, not something end viewers ever touch.
  - `explore` — in published view, only a viewer with an **explore-or-edit grant** can write. Edits persist.
  - `view` — in published view, **any viewer with access to the workbook at all** — including one with only a view grant — can write. The most open of the three, despite the name. Edits persist.
- `source` is either an **empty** table or a **linked** table (below).

## Sources

### Empty — a fresh warehouse-backed table

```yaml
source:
  kind: empty
  connectionId: <conn-uuid>
```

Rows live in the connection's warehouse. Editable columns you declare become physical storage columns.

### Linked — rows sourced from another element

```yaml
source:
  kind: linked
  from: orders-table # elementId to link from
```

A linked table joins rows from `from` and lets users append editable columns alongside them.

> **Join key bindings are fixed once a linked table is created.** Declare the key column(s) at create time; you can't rebind them on a later PUT.

## The `columns` union

One array, mixing several column kinds:

| Column                 | Shape                  | Notes                                                                      |
| ---------------------- | ---------------------- | -------------------------------------------------------------------------- |
| **storage** (editable) | `{ id, type }`         | `type` is `text \| number \| datetime \| checkbox` — a real editable cell. |
| **formula**            | `{ id, formula }`      | Computed, read-only. Same formula rules as `table` (see `formulas.md`).    |
| **system**             | `{ id }`               | Protocol-managed column referenced by id (e.g. row id, timestamps).        |
| **key** (linked only)  | `{ id, key, hidden? }` | Join key binding the linked row. `hidden: true` keeps it out of the grid.  |

Storage-column display names round-trip: author `{ id, name, type }` and the `name` comes back on GET.

## Column validation (editable columns)

Constrain what users may enter. `values`, `valuesFrom`, and `range` **share one validation slot and are mutually exclusive** on a single column.

- **`values`** — inline single-select list, on `text` / `number` / `datetime`:
  `{ id, type: text, values: [gold, silver, bronze] }`
- **`multi-select`** — a column `type` holding several values from a set:
  `{ id, type: multi-select, values: [urgent, review] }`
- **`valuesFrom`** — source the option list from a sibling element's column:
  `{ id, type: text, valuesFrom: { element: tiers-table, column: tier } }`
- **`range`** — numeric/date bounds on `number` / `datetime` (datetime bounds are ISO-8601):
  `{ id, type: number, range: { min: 1, max: 5 } }`
- **`pills`** — render a select column as pills: `single-color` | `color-by-option`.

## File-upload columns

An editable column with `type: file` accepts file uploads.

```yaml
- id: attachment
  type: file
  maxFileNum: 3 # optional, >= 1
  maxFileSizeMb: 10 # optional, 1-200
  acceptedFileTypes: [application/pdf, image/jpeg] # optional MIME allowlist
```

> A file format is selected as a **family** — passing one MIME type of a multi-format family selects the whole family, so a round-trip may expand `acceptedFileTypes`. An absent or empty list accepts everything.

> **`multi-select` and `file` columns are variant-backed** and require a connection whose warehouse supports variant columns.

## Display fields (table parity)

Input tables accept the same display customizations as a `table` element — see `tables.md` for the shapes: `name`, `description`, `style`, `noDataText`, `tableComponents`, `conditionalFormats`, `summary`, `tableStyle`, `sort`, `filters`.

## Cross-element references

Other elements and formulas can reference an input-table column by the element's name:

```yaml
# in another element:
formula: "[Account Notes/priority]"
```

## Examples

### Linked table

```yaml
id: orders-it
kind: input-table
name: Order Follow-ups
inputMode: explore
source:
  kind: linked
  from: orders-table
columns:
  - { id: ORDER_ID, key: order_id, hidden: true } # join key (linked only)
  - { id: customer, formula: "[Orders/Customer]" } # included source column
  - { id: notes, type: text } # editable storage
  - { id: ID } # system column
```

### Empty table with validation + file column

```yaml
id: intake-it
kind: input-table
name: Intake
inputMode: edit
source:
  kind: empty
  connectionId: <conn-uuid>
columns:
  - { id: tier, type: text, values: [gold, silver, bronze], pills: color-by-option }
  - { id: tags, type: multi-select, values: [urgent, review] }
  - { id: rating, type: number, range: { min: 1, max: 5 } }
  - {
      id: attachment,
      type: file,
      maxFileNum: 3,
      maxFileSizeMb: 10,
      acceptedFileTypes: [application/pdf, image/jpeg],
    }
```
