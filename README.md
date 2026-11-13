# sigma-workbooks skill

A Claude Code skill for building, editing, and iterating on Sigma workbook specs (`POST /v2/workbooks/spec`): pages, layout, controls, charts, KPIs, tables, formulas, and sources.

## Install

```bash
git clone https://github.com/chris7seven/sigma-workbooks-skill ~/.claude/skills/sigma-workbooks
```

## Auth

No credentials are stored here. The skill and scripts read `SIGMA_BASE_URL` and `SIGMA_API_TOKEN` from your environment (see the `sigma-api` skill for obtaining a token).
