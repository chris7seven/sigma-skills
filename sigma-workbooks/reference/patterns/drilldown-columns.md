# Drill-down columns on every chart

Right-click drill-down can only break out by columns the **element carries**. A chart
plotting month and amount can be drilled by month and amount, and by nothing else —
which is the single most common "why can't I break this out by debtor" complaint.

The fix costs nothing visually:

```python
for c in ["Debtor Name", "Debtor Type", "Industry", "Status",
          "Aging Bucket", "Client Name", "Department"]:
    el["columns"].append({"id": slug(c), "name": c,
                          "formula": f"[{SRC}/{c}]", "hidden": True})
```

Add the full descriptive set — entity, type, industry, status, bucket, owner — to every
chart, KPI and summary table. It is the difference between a picture and something a user
can interrogate live, and it is the pattern to apply by default.

**Display tables are the exception.** There, show only what you mean to show.

Two constraints: a `/` in a column *name* breaks `[Element/Column]` references to it
(`gotchas.md` #10 — rename `Open A/R` to `Open AR`), and on a **grouped** element these
extra columns must go in the grouping's `calculations` or they resolve at the ungrouped
child grain and multiply (`gotchas.md` #6).

## Default: bring in every column the chart's source has (verified 2026-09-22)

Don't curate a descriptive set; carry **all** of them. Loop over the source element's columns and
append each one to the chart that isn't already there. They aren't on an axis, so they aren't
plotted, but every one becomes available to drill down and filter on.

```python
def carry_all_columns(chart, src_el):
    name = src_el["name"]                       # refs go by ELEMENT NAME, not id
    have = {c["formula"] for c in chart["columns"]}
    for sc in src_el["columns"]:
        f = f"[{name}/{sc['name']}]"
        if f in have:
            continue
        col = {"id": f"{chart['id']}-x-{sc['id']}", "name": sc["name"], "formula": f}
        if sc.get("format"):
            col["format"] = sc["format"]        # keep $ / % formatting in the drill view
        chart["columns"].append(col)
```

On D&C this took the three charts to 10, 12 and 33 columns. All compiled, and none changed what
was plotted.

**Columns you can't reference by name.** A source column whose name contains `\n` (used to
reproduce two-row Excel headers, e.g. `"Live\nTotal Net Assets"`) or a `/` can't be written as
`[Element/Column]`. Bring those in through the plain-named helper column that computes the same
value, under a readable name (`"Live Total Net Assets"` → `[Analysis/hM]`). Skip columns that are
null on every row; they only add noise to the drill menu.

**Give new charts their own base element when the source is a Lookup target.** Adding a chart
(or any child) to an element that another table `Lookup()`s into made the workbook PUT fail with
`Dependency not found: '<element>/<column>'` on the *looking-up* table. `/spec/verify` still
passed. The fix is a dedicated base element for the new visuals, sourced from the same data-model
element. To find the culprit, bisect by POSTing scratch copies with elements removed; `verify`
won't show it.
