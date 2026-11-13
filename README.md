# Sigma skills for Claude Code

| Skill | What it does |
| --- | --- |
| [`sigma-workbooks`](sigma-workbooks/) | Build and edit Sigma workbook specs (`POST /v2/workbooks/spec`): pages, layout, controls, charts, KPIs, tables, formulas, sources |
| [`sigma-data-models`](sigma-data-models/) | Build and edit Sigma data model specs: tables, columns, relationships, metrics |

## Install

```bash
git clone https://github.com/chris7seven/sigma-skills ~/sigma-skills
ln -s ~/sigma-skills/sigma-workbooks ~/.claude/skills/sigma-workbooks
ln -s ~/sigma-skills/sigma-data-models ~/.claude/skills/sigma-data-models
```

## Auth

No credentials are stored in this repo. The skills read `SIGMA_BASE_URL` and `SIGMA_API_TOKEN` (or `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`) from your environment. You need Sigma API client credentials for your own org.
