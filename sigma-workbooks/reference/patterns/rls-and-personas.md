# Row-level security & persona switching

How to make a workbook show each person only their own rows — and how to demo that convincingly
by impersonating someone else. Verified by round-trip and by live export on Azure-US / Databricks.

This is spec-level scoping, not warehouse RLS. It is the right tool for a POV, a prototype, or an
app whose ownership model lives in the workbook. For production-grade enforcement, back it with
warehouse row access policies or Sigma user attributes as well — a determined user can still reach
the underlying element.

---

## The shape

Three pieces:

```
personas   a tiny table of who can be impersonated (email, display name, is_admin)
myscope    one row per <scope key> x person, answering "is this mine?"
<element>  a `Visible To Me` column + an element-level filter on it
```

### 1. Personas (custom SQL, or an input table so the customer can edit it)

```sql
SELECT * FROM (VALUES
  ('rep@example.com',   'Dana Reyes — Account Manager',  'Account Manager', 'No'),
  ('lead@example.com',  'Sam Okafor — Segment Lead',     'Segment Lead',    'No'),
  ('admin@example.com', 'Admin — sees everything',       'Admin',           'Yes')
) AS t(email, display_name, role_hint, is_admin)
```

Include **the person actually logged in** during a demo, or the picker will not contain them.

### 2. The "View as" control

A single-select list sourced from `display_name`, so the picker reads like people rather than
email addresses:

```yaml
- kind: control
  id: ctrl-viewas
  controlId: ViewAs
  name: View as
  controlType: list
  mode: include
  selectionMode: single
  value: "Dana Reyes — Account Manager"     # default persona
  source:
    kind: source
    source: { kind: table, elementId: personas }
    columnId: personas-display_name
```

Mirror it onto other pages with a **synced** control — the master lives on one page only:

```yaml
- { kind: control, id: h-viewas, controlId: ViewAs, controlType: synced }
```

⚠️ `values: []` is stripped on single-select controls; `value` (a string) persists. If a persona
column comes back blank everywhere, this is usually why — not a binding failure.

⚠️ Never set `value: ""`. An empty string is an active filter for a literal blank and removes every
row from the page. Omit `value` entirely for "show all".

### 3. Resolve the label back to an identity

Do the role comparison on **email**, never on the display label — email is what survives the
eventual switch to real RLS, where `[ViewAs]` becomes `CurrentUserEmail()`.

```yaml
- { id: v-viewas,  name: Viewing As,       formula: "[ViewAs]" }
- { id: v-email,   name: Viewing As Email,
    formula: 'Lookup(Max([Personas/email]), [Viewing As], [Personas/display_name])' }
- { id: v-admin,   name: Is Admin,
    formula: 'Lookup(Max([Personas/is_admin]), [Viewing As], [Personas/display_name])' }
- { id: v-role,    name: My Role,
    formula: >-
      If([Owner] = [Viewing As Email], "Owner",
      If([Approver] = [Viewing As Email], "Approver", "—"))' }
- { id: v-visible, name: Visible To Me,
    formula: 'If([Is Admin] = "Yes", "Yes", If([My Role] != "—", "Yes", "No"))' }
```

Then filter the element:

```yaml
filters:
  - { id: f-vis, columnId: v-visible, kind: list, mode: include, values: ["Yes"] }
```

**Every element needs its own copy of `Viewing As`.** A downstream element that inherits only
`Viewing As Email` without the `[ViewAs]` column underneath it fails with
`Unknown column "[Viewing As]"`, and anything filtering on the result errors out with it —
a table whose filter column is errored returns **HTTP 500 on export and does not render at all**.

---

## Filtering an INPUT table (the hard case)

An input table cannot reach its own link source (`input-tables.md` 7b), so it cannot compute
ownership from the source it was linked from. It also must not Lookup into a downstream view that
already Lookups back into it — that is a cycle.

Use a **small scope table** keyed on something the input table already carries:

```yaml
# myscope — one row per customer x region, off the assignment map
- id: myscope
  kind: table
  name: My Scope
  source: { kind: table, elementId: assignments }
  columns:
    - { id: ms-cust,  name: Customer, formula: "[Assignments/customer]" }
    - { id: ms-viewas, name: Viewing As, formula: "[ViewAs]" }
    - { id: ms-email, name: Viewing As Email,
        formula: 'Lookup(Max([Personas/email]), [Viewing As], [Personas/display_name])' }
    - { id: ms-mine,  name: Mine, formula: >-
        If([Assignments/owner] = [Viewing As Email]
           or [Assignments/approver] = [Viewing As Email], "Yes", "No") }
```

```yaml
# on the input table
- { id: g-admin, name: Is Admin,
    formula: 'Lookup(Max([Personas/is_admin]), [ViewAs], [Personas/display_name])' }
- { id: g-vis, name: Visible To Me, formula: >-
    If([Is Admin] = "Yes", "Yes",
       If(Lookup(Max([My Scope/Mine]), [Customer], [My Scope/Customer]) = "Yes", "Yes", "No")) }
filters:
  - { id: g-fv, columnId: g-vis, kind: list, mode: include, values: ["Yes"] }
```

Two details doing real work:

- **`Max()` over `"Yes"`/`"No"` is a deliberate OR.** When a key maps to several scope rows (one
  customer across three regions), `Max()` returns `"Yes"` if *any* of them is yours, because `"Yes"`
  sorts above `"No"`. That is usually the behaviour you want and it costs one join instead of three.
- **The admin override catches orphans.** A key absent from the scope table Lookups to blank, and
  `mode: include, values: ["Yes"]` excludes blanks — so those rows become invisible to *everyone*.
  Checking `Is Admin` first keeps them reachable.

### Verify it actually filtered

The failure mode is a filter that passes 100% of rows, which looks identical to no filter. Export
the element and count (see `../workflows/verify.md`):

```
before   577,200 rows   2,148 customers
after    352,632 rows     634 customers
```

If the "after" count equals the "before" count, the visibility column is not resolving — check for
a link-source reference.

---

## Guard the write path too

An element filter controls what a person can **see**. It does not control what an action can
**reach**. Any `update-rows` predicate must carry the same guard explicitly:

```
… and [Visible To Me] = "Yes"
```

Without it, an agent tool or a button can rewrite rows the user cannot even see.
