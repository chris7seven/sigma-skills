# Submit → approve → lock (multi-level approval apps)

A complete, verified pattern for planning/budgeting/adjustment apps where someone enters numbers,
submits them, and one or more approvers sign off — with staleness detection when the numbers move
after a sign-off.

Pair with `rls-and-personas.md` (who sees what) and `../specification/input-tables.md`.

---

## Element map

```
scope      regular table   one row per <thing to approve> x approver role   "who must sign what"
log        input table     one row per decision                             append-only
subs       input table     one row per submission                           append-only
status     regular table   scope + derived state                            the state machine
inbox      table           status, filtered to "my turn"                    what an approver sees
```

Both write tables are **append-only** — never mutated. That gives a free audit trail (`CREATED_AT` /
`CREATED_BY` system columns) and makes staleness a simple timestamp comparison.

### Exploding one row into several obligations

Three approvers per item, from one assignment row (Databricks / Spark):

```sql
SELECT a.item, a.region, x.role, x.approver
FROM assignments a
LATERAL VIEW inline(array(
  named_struct('role','Owner',        'approver', a.owner),
  named_struct('role','Team Lead',    'approver', a.team_lead),
  named_struct('role','Regional Lead','approver', a.region_lead)
)) x AS role, approver
```

---

## The state machine

```yaml
- { id: s-changed, name: Last Changed,
    formula: 'Lookup(Max([Grid View/Last Edited]), [Item], [Grid View/Item])' }
- { id: s-sub, name: Submitted At,
    formula: 'Lookup(Max([Submissions/Created at]), [Scenario], [Submissions/Scenario],
                     [Item], [Submissions/Item])' }
- { id: s-decat, name: Decided At,
    formula: 'Lookup(Max([Approval Log/Created at]), [Scenario], [Approval Log/Scenario],
                     [Item], [Approval Log/Item], [Role], [Approval Log/Role])' }
- { id: s-state, name: Approval State, formula: >-
    If(IsNull([Submitted At]), "Not submitted",
    If(IsNull([Decided At]), "Pending",
    If(Not IsNull([Last Changed]) and [Last Changed] > [Decided At], "Stale — re-approve",
       [Decision]))) }
```

`Last Changed` comes off the input table's `UPDATED_AT` system column, so **any** edit after a
sign-off — typed, pasted, or made by an agent — flips the row back to `Stale`. That is what makes
the audit story honest without needing a change-capture table.

⚠️ System columns (`CREATED_AT`, `UPDATED_AT`, `CREATED_BY`, `UPDATED_BY`) appear in a GET-back with
no `name`, and their display names are `Created at` / `Last updated at` / `Created by` /
`Last updated by`. Reference those strings in formulas. **Strip `type` and `formula` from system
columns before any PUT** or the request is rejected.

### ⚠️ One label, everywhere

The single most destructive bug in this pattern is a scenario/period label that disagrees between
the scope SQL and the button that writes the submission. The Lookup joins on it, so it never
matches, `Submitted At` stays null, and **every row sits at "Not submitted" forever** — with no
error anywhere. Grep the whole spec for the literal before shipping:

```bash
grep -o "'[0-9]\{4\} [A-Za-z]*'" spec.json | sort -u     # expect exactly one
```

---

## Sequential vs parallel routing

**Parallel** — all approvers get it at once. `inbox` filters `Mine = "Yes"` and state in
`Pending, Stale`.

**Sequential (a chain)** — each level only sees it once the previous level approved. Needs a
per-role decision lookup, and **Lookup keys cannot be literals** — so give each role a constant
column to key on:

```yaml
- { id: s-r1, name: R1, formula: '"Owner"' }          # constant columns exist purely as Lookup keys
- { id: s-r2, name: R2, formula: '"Team Lead"' }
- { id: s-d1, name: Owner Decision,
    formula: 'Lookup(Max([Approval Log/Decision]), [Item], [Approval Log/Item], [R1], [Approval Log/Role])' }
- { id: s-d2, name: Team Lead Decision,
    formula: 'Lookup(Max([Approval Log/Decision]), [Item], [Approval Log/Item], [R2], [Approval Log/Role])' }
- { id: s-wait, name: Waiting On, formula: >-
    If(IsNull([Submitted At]), "Submitter",
    If([Owner Decision] != "Approved", "Owner",
    If([Team Lead Decision] != "Approved", "Team Lead", "Fully approved"))) }
- { id: s-turn, name: My Turn,
    formula: 'If([Mine] = "Yes" and [Role] = [Waiting On], "Yes", "No")' }
```

The inbox then filters on `My Turn` rather than `Mine`, so a lead's page stays empty until it
genuinely reaches them. All levels still sign; they just sign in order.

---

## Recording a decision

Row-click on the inbox captures the row into controls, opens a modal, and the modal appends:

```json
{ "id":"inbox", "kind":"table",
  "actions":[ { "id":"a-sel", "trigger":"on-select", "effects":[
    {"effect":"set-control-value","control":"ApprItem","value":{"type":"column","column":"ib-item"}},
    {"effect":"set-control-value","control":"ApprRole","value":{"type":"column","column":"ib-role"}},
    {"effect":"open-overlay","overlayId":"apprModal"} ] } ] }
```

```json
{ "effect":"insert-rows", "table":"log", "values":{
   "l-item":    {"type":"control","control":"ApprItem"},
   "l-role":    {"type":"control","control":"ApprRole"},
   "l-decision":{"type":"control","control":"ApprDecision"},
   "l-approver":{"type":"formula","formula":"CurrentUserEmail()"} } }
```

Swap `CurrentUserEmail()` for a persona Lookup while demoing with a "View as" switcher, and record
the **email**, not the display label.

---

## Locking — and what Sigma can and cannot do

**Sigma cannot make a cell read-only by formula.** Column protection is UI-only governance and is
column-level, not row-level. So "lock on submit" is enforced in three places, none of which is a
hard block on typing:

1. **A visible flag** — a `Submitted` column on the input table:
   ```yaml
   - { id: g-sub, name: Submitted, formula: >-
       If(IsNull(Lookup(Max([Submissions/Created at]), [Item], [Submissions/Item])), "No", "Yes") }
   ```
2. **The write path** — every `update-rows` predicate carries `and [Submitted] = "No"`, so agents
   and buttons refuse locked rows.
3. **Staleness** — a manual edit is not blocked, but it flips the state to `Stale — re-approve` and
   the chain restarts.

Be straight with a customer about this. Framed well it is the stronger story: the system does not
silently prevent a change, it makes the change visible and forces re-approval — which is what an
auditor actually wants.

Row shading for locked rows can be done from code: `conditionalFormats` on an input table works
since 2026-10 with the `{type: single, columnIds, condition, value, style}` shape (the older
`kind: single-color` shape is what returns the masked `Invalid kind:"input-table"`).

---

## Notifications: there is no event hook

Verified: `/v2/workbooks/{id}/alerts` returns **404**. The only mechanism is
`/v2/workbooks/{id}/schedules`, which is **cron delivery**:

```
POST /v2/workbooks/{id}/schedules
{ "schedule": { "cron": "…" },
  "target":  [ { "email": "…" } | { "slackConversationId": "…" } | { "webhookUrl": "…" } ] }
```

So "the approver gets notified when I submit" means **a scheduled conditional delivery of the
inbox page**, checked on a cron — not an instant trigger on the click. Say so up front; it is a
question that always comes up in an approvals demo.

For anything genuinely event-driven, the honest answer is a webhook target plus an external
scheduler, or the customer's own notification platform reading the write-back table.

---

## What you can and cannot verify from code

You **can** verify headlessly: the scope explodes to the right number of obligations, every row
carries the same label, the derived columns resolve without errors, the parked state is correct.

You **cannot** verify the transitions. There is no input-table row-write API (all `/rows` paths
404) and custom SQL is read-only, so no submission can be seeded from code. A REST agent run
(`POST /v2/workbooks/{id}/agents/{agentId}`) does execute an `insert-rows` tool, but on an
API-created input table it fails with "Manual commit is not enabled" until the workbook has been
published once in the UI. Assert the parked state,
then hand the click-test over with a specific list of what to try and what each step should show.
