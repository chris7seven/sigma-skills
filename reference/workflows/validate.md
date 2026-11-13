# Workbook Spec Validation

Validation runs in two phases: **pre-submit** (this file's sections 1–3) catches what's visible in the spec text; **post-create** (section 4) catches what Sigma's compiler discovers but the spec parser tolerates. Both matter — silent compilation failures are the largest hidden failure mode.

Load this file before any POST or PUT.

## 1. Run the bundled validator

```bash
./scripts/validate-spec.sh /tmp/workbook-spec.yaml
```

The validator catches the most common failure: bare bracketed refs (`[column]` without a `/`) that don't match any column defined in the same element's `columns[]` array. Fix everything it reports before continuing. If it exits 0, proceed to the manual pass.

## 2. Manual formula pass

After the validator passes, do a final mechanical pass on every formula in the spec. **Do not skip to submission until every formula has been checked.**

For each column's `formula`:

1. **List every bracketed reference** in the formula. E.g., `Sum([Master/Sales]) - [Cost]` → refs are `Master/Sales` and `Cost`.
2. **For each reference, it must resolve to exactly one of:**
   - A **sibling** — the portion inside the brackets (no `/`) exactly matches a `name` in THIS element's `columns[]` array.
   - A **qualified ref** — contains `/`, and the prefix matches one of:
     - The last segment of the `path` array (if source is `warehouse-table`)
     - Another element's `name` (if source is `table` referencing that element)
     - A join leg's `name`, or the join's top-level `name` for `primarySource` columns (if source is `join`)
     - The literal string `Custom SQL` with a **raw** (not friendly-cased) column alias (if source is `sql`)
     - The data model element's own `name` (if source is `data-model`)
3. **If a reference doesn't match either, the formula is wrong.** The most common fix is adding the source prefix — see the wrong/right example at the top of `reference/specification/formulas.md`.

## 3. Final shape checks

Also check for these rarer issues:

- A column's `formula` references a name matching its own `name` field → circular reference.
- A formula references a column name that doesn't exist on the source (re-confirm column names with the user).
- Donut charts' `holeValue` is optional, not required — verified against the schema and live (see `specification/charts.md`).
- Layout XML: no `<Element type="grid">` with children — use `<Container>` for nesting.

## 4. Post-create verification (do not skip)

`POST /v2/workbooks/spec` is generous about *bare*, unprefixed column references (`[ColumnName]`, meaning "declared elsewhere in this same element's `columns[]`") — verified live. It accepts a spec where a bare reference doesn't actually match a declared column, and Sigma surfaces the failure *at query time* by embedding the error as a string literal in the compiled SQL:

```sql
select V_44 "Total Revenue" from (select 'Unknown column "[ORDER_TOTAL]"' V_44) Q1
select V_11 "Quarter" from (select distinct 'Circular column reference to [Quarter]' V_11 ...) Q1
```

**This leniency does not extend to *prefixed* references (`[SourceName/column]`)** — the far more common case (90%+ of formulas per `specification/formulas.md`'s "READ FIRST"). A bad prefixed reference, whether to a warehouse table's raw column or another element's column, fails immediately at `POST` with `elements[N]: Dependency not found: '<source>/<column>'` — no workbook gets created, so there's nothing here to catch after the fact. See `specification/formulas.md` for the full distinction and the probe-and-bisect pattern for getting warehouse column names right before you POST.

For the bare-reference case this section covers: the UI renders those elements as empty, and there is no way to catch it from the spec text alone — only Sigma's compiler knows whether a bare `[ColumnName]` resolves to a real declared column.

After every CREATE and after every PUT that touches columns or formulas, run:

```bash
./scripts/verify-workbook.sh <workbookId>
```

It hits `GET /v2/workbooks/<id>/elements/<eid>/query` for each element and reports any whose SQL contains the error markers above. Treat a non-zero exit the same as a failed POST — fix the spec and re-PUT.

**The script only greps for error markers — it doesn't prove the query returns the right rows, or even any rows.** When you want to confirm a `join`'s actual `ON` clause, a `sql` source's statement resolved as written, or just what an element's SQL really looks like beyond pass/fail, hit `GET /v2/workbooks/<id>/elements/<eid>/query` yourself and read the compiled SQL directly — more informative than the script's grep for genuinely understanding what got built.

The most common causes of post-create failure:

- **Bare warehouse refs.** `Sum([ORDER_TOTAL])` instead of `Sum([ORDERS/ORDER_TOTAL])`. The single biggest trap; see `reference/specification/formulas.md`.
- **Friendly-name mismatch.** The columns endpoint returns raw warehouse names (`V userId`, `UNIT PRICE`); formulas need Sigma's normalized friendly names (`V User Id`, `Unit Price`). Sigma is permissive at POST and normalizes casing for many simple cases, but won't rescue all of them. When in doubt, GET the spec back after a successful create — Sigma's readback shows the canonical names — and use those for any subsequent PUT.
- **Circular reference.** A column named `Quarter` with formula `[Quarter]` — easy to write when copying warehouse column names verbatim into a sibling-reference position. Rename one side.

## Decoding Cryptic Validation Errors

Server-side validation errors point at a JSON path but don't say what shape was expected. Use the path as the root-cause hint, then check the spec reference file for that feature to compare shapes.

| Error pattern | Most likely cause | Where to look |
|---------------|-------------------|---------------|
| `Invalid kind: document.elements[N], got "..."` | Almost always the element's **inner shape** is wrong for the `controlType`/`kind` it claims, **not** that the kind is unsupported. Sigma's parser picks a schema by `kind` + `controlType` and reports the parent path when the inner match fails. | `reference/specification/controls.md` (slider is the most common trap), or the relevant element file (`charts.md`, `kpis.md`, `tables.md`). |
| `Invalid value: document.elements[N].filters[M], got object` | The field is typed as an array of a specific shape and you sent something that doesn't match. | A working reference workbook (`GET` an existing workbook) for that exact field. |
| `Invalid kind: document.elements[N].columns[M]` | Usually missing `id`, `name`, or `formula`, or `format.kind` mismatched. | `reference/specification/formatting.md`. |
| `document.pages[].elements is no longer supported. Move elements to document.elements instead.` | Elements are a flat top-level array now, not nested under `pages`. | `reference/specification/schema.md`. |
| `element '<id>' is not placed in layout` | Every entry in `document.elements` must have a `<Element>` placement in `layout` — `layout` is nominally optional but effectively required once `elements` is non-empty. | `reference/specification/layout.md`. |
| **Silent bad data** — no error, but the value/element is missing or `null` on readback | (a) A boolean-operator formula written as a function call (`Not(...)` instead of `Not ...`) — parses successfully but evaluates to `null` per row; (b) layout XML naming an `elementId` that doesn't exist in `document.elements` (typo or wrong id). | `formulas.md` for (a), `layout.md` for (b). All under `reference/specification/`. |

**General strategy:** the error path names the offending field; the spec reference file for that feature shows the shape. If after checking both you still can't see the mismatch, fetch a known-good reference workbook via `GET /v2/workbooks/<id>/spec` (with `Accept: application/json`) and diff your shape against it.
