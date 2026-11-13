# Plugin Element

The `kind: plugin` element embeds a custom plugin (e.g. a D3 visualization) and wires its inputs to workbook data. Pull its exact shape from the spec:

```bash
jq --arg k plugin 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

## Shape

```yaml
id: revenue-sunburst
kind: plugin
pluginId: 3f2a9c1e-0b7d-4e2a-9f11-8c6d5b4a2e10 # the plugin's UUID (required)
displayName: D3 Sunburst # optional label
style:
  backgroundColor: "#ffffff" # optional — hex or a theme reference
config:
  # ...plugin-declared inputs, see below
```

| Field                   | Required | Notes                                         |
| ----------------------- | -------- | --------------------------------------------- |
| `id`                    | yes      | Unique on the page                            |
| `kind`                  | yes      | Always `"plugin"`                             |
| `pluginId`              | yes      | UUID of the plugin to render                  |
| `displayName`           | no       | Human-readable label                          |
| `style.backgroundColor` | no       | Hex string (`"#ffffff"`) or a theme reference |
| `config`                | no       | Map of the plugin's inputs — see below        |

> **`pluginId` is not validated on write.** A plugin element whose `pluginId` doesn't resolve to a real plugin is still accepted and round-trips intact — it just renders empty. The API won't reject an unknown plugin, so verify the id yourself.

## `config` — wiring the plugin's inputs

`config` is a map **keyed by the config names the plugin itself declares** (every plugin defines its own input names — `source`, `measures`, `dimension`, etc.). Each value is either a literal or a `kind`-tagged reference.

**Literals** — a string, boolean, or string array:

```yaml
config:
  title: Revenue by product # string
  showLegend: true # boolean
  categories: [gold, silver] # string array
```

**References** — bind to workbook data:

| Reference | Shape                                                                                | Binds                                    |
| --------- | ------------------------------------------------------------------------------------ | ---------------------------------------- |
| element   | `{ kind: element, elementId, groupingId? }`                                          | An element as a data source              |
| column    | `{ kind: column, columnId, source }` or `{ kind: column, columnIds: [...], source }` | One or more columns from a bound element |
| control   | `{ kind: control, controlId }`                                                       | A control's current value                |

Example — an element data source plus a measure column selected from it:

```yaml
config:
  source:
    kind: element
    elementId: trips-table
  measures:
    kind: column
    columnIds:
      - trips-table/DURATION
    source: source # names the `source` element-reference above
```

> **`column.source` must name an element reference in the same `config`.** A `kind: column` value points at another `config` entry (by its key) that is a `kind: element` reference — here `source: source`. Point it at an element reference that exists and columns that resolve; an unresolved reference binds to nothing (it renders empty) rather than being caught for you.

> **The `config` shape is intrinsic to the plugin — you must discover it from the plugin itself, not from this spec.** A plugin is external code loaded from a URL, and it declares its own input names and the value type each expects. The workbook spec stores only the chosen values as a free-form map: it does **not** carry the plugin's config schema, does not enumerate the valid keys, and won't validate them for you. So there is no way to derive a plugin's `config` shape from the codec or this skill — get the input names from the plugin's own definition/documentation, or by inspecting (`GET /spec`) a workbook that already wires up that same `pluginId`.
