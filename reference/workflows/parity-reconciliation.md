# Parity inventory and reconciliation

Use this whenever the workbook is being built **from a reference artifact** — an HTML
mockup, a screenshot, a PBIX/PBIR export, a Tableau workbook, or a legacy report the
customer wants reproduced.

`from-image.md` covers *interpreting* the artifact into spec intent. This covers
**proving the finished workbook still matches it** — and catching the items that quietly
fall out during later edits.

## Why this exists

An upfront inventory that lives only in the chat reply evaporates. The build then drifts,
and the drift is invisible because nothing is holding the original list.

Real failure this is written from (a customer engagement, Sept 2026): a mockup was inventoried, built,
and then restructured for better narrative flow. The restructure **silently dropped three
features that had already been built or promised** — a persistent header with page
navigation, an always-visible proactive alert banner, and period-over-period comparisons
on the KPI row. Nobody noticed until the customer said *"there's no parity here."* Each
item had been discussed; none were tracked. The fix was not more care — it was a file.

## The rule

> **Persist the inventory as a file in the project. Reconcile against it at the end of
> every build pass — not just the first.**

## Step 1 — Extract the inventory mechanically

For an **HTML mockup**, do not eyeball it. Strip the stylesheet and dump the text nodes
in document order — that gives a complete, ordered feature list in seconds:

```bash
python3 - <<'EOF'
import re
html = open('mockup.html').read()
body = html.split('</style>', 1)[1]          # drop CSS, keep structure
txt  = re.sub(r'<[^>]+>', '\n', body)
lines = [l.strip() for l in txt.split('\n') if l.strip()]
print('\n'.join(lines))
EOF
```

Also grep the structural landmarks (`<!-- SECTION -->` comments, `class="topbar|toolbar|
kpi|section-title|chatpanel"`) to recover grouping the text dump flattens.

For a **screenshot**, fall back to reading it with the Read tool per `from-image.md`. For
a **PBIR/PBIP export**, read `definition/pages/*/visuals/*/visual.json` and the
`.SemanticModel/definition/tables/*.tmdl` measures.

## Step 2 — Write it to `PARITY-<name>.md`

One row per feature, grouped by region of the artifact, with a stable reference id
(`A1`, `D3`, …) so it can be cited in conversation and in commit messages.

```markdown
Status: ✅ built · ⚠️ partial · ❌ missing · ⛔ not possible in Sigma · 🚫 deliberately not built

## D. KPI row
| # | Reference artifact | Workbook | Status |
|---|---|---|---|
| D1 | Total Open A/R + "▲ 2.4% MoM" | `comparisonColumn` → prior month | ✅ |
| D3 | Watchlist + "▲ 3 new this week" | not wired | ❌ |
| D5 | KPI sparkline | `trend` on kpi-chart | ❌ not yet |
```

**The status vocabulary matters.** Collapsing everything to done/not-done hides the
difference between *forgotten* and *decided*. `🚫` and `⛔` are legitimate end states;
`❌` is debt. Every `🚫`, `⛔`, `⚠️` needs a one-line reason in the row or a
**Remaining gaps** table at the bottom — otherwise a future pass re-litigates it or
"fixes" a deliberate choice.

## Step 3 — Reconcile at the end of every pass

Not only the first build. Restructures, styling passes and correctness fixes all drop
things. After each pass:

1. `GET /v2/workbooks/{id}/spec` and list element ids + page assignment.
2. Screenshot **every page** (`POST /v2/workbooks/{id}/export` with a `pageId`, format
   `png`) and read each one back. Do not reconcile from the spec alone — the spec can
   contain an element that renders as an empty box.
3. Walk the `PARITY-*.md` rows and update each status against what you just saw.
4. Anything that moved from ✅ to ❌ is a regression you introduced in this pass. Fix it
   before reporting done.
5. Report the counts, and list the remaining `❌` items explicitly rather than implying
   completeness.

## Step 4 — Deliberate divergence is fine; silent divergence is not

Reproducing a mockup is not the goal — a *better* workbook is. Diverge freely, but record
it as `🚫` with the reason. Common legitimate divergences:

- The mockup's scripted/fake chat becomes a real `chat` element (real beats scripted).
- Decorative buttons ("Copy to Deck") are dropped rather than built as non-functional
  chrome — unless the real `export` action effect is wired.
- Hardcoded opinionated copy moves into the agent's instructions
  (see the descriptive-vs-opinionated rule in `content-elements.md`).
- A mockup invents data (debtor names, tidy percentages) that the real schema lacks.

## Traps that produce false parity

- **Reconciling from the spec, not the render.** An element can exist, compile, and still
  render blank — a container child at `gridRow="1 / 2"` clips to nothing, and a `text`
  element's `style` is stripped on round-trip. Screenshot it.
- **Panels need `settings.navigation`.** A header/sidebar declared in `document.panels[]`
  with no `pageHeader: "enabled"` renders nothing at all, while the spec looks complete.
- **Blanket grid-row edits.** Shifting `gridRow` with a regex across a page also moves
  container *children*, whose rows are container-relative — collapsing them to zero
  height. Rewrite a page's layout block explicitly instead.
- **One layout placement per element.** "Show the alert on every page" is not a copy —
  it's a move into a panel. The same element id cannot appear twice in the layout.
- **Counting elements instead of features.** 51 elements compiling cleanly says nothing
  about whether the KPI deltas exist.

## Deliverable

Report parity as counts plus the explicit remaining list:

> 29 of 41 items at parity. Remaining: D3 (watchlist delta — needs the flag rules re-run
> at a prior anchor), D5 (KPI sparklines), I3 (export buttons — `export` effect is real,
> needs a recipient list). E3 is ⛔ — Sigma tables have no sparkline cell renderer.
