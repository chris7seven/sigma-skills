# Chat & Agents

A `chat` element embeds an AI chat surface on a page, backed by a workbook **agent**. Agents are declared once inside the spec's **`document`** envelope (a sibling of `pages`) and referenced from a chat element by `agentId`.

## Chat element

```yaml
- id: sales-chat
  kind: chat
  agentId: sales-agent # references a top-level agent by id
```

- `kind: chat` and `id` are required; `agentId` (the agent it connects to) is optional.

## Top-level `agents`

`agents` lives inside the `document` envelope, a sibling of `pages`. Several chat elements can reference the same agent.

```yaml
document:
  kind: workbook
  schemaVersion: 1
  agents:
    - id: sales-agent
      instructions: Help the user analyze sales performance.
      name: Sales analyst
      dataSources:
        - kind: table
          elementId: orders-table
      greeting:
        mode: static
        # ...message
      tools:
        - toolId: crm
          kind: mcp-connector
          # ...
  elements:
    - { id: sales-chat, kind: chat, agentId: sales-agent }
  pages:
    - id: page1
  layout: |
    <?xml version="1.0" encoding="utf-8"?>
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page1">
      <Element elementId="sales-chat" gridColumn="1 / 25" gridRow="1 / 20"/>
    </Page>
```

Each agent:

| Field          | Required | Notes                                                                                          |
| -------------- | -------- | ---------------------------------------------------------------------------------------------- |
| `id`           | yes      | Referenced by a chat element's `agentId`.                                                      |
| `instructions` | yes      | System instructions for the agent. Supports dynamic-text `{{formula}}` references.             |
| `name`         | no       | Display name.                                                                                  |
| `description`  | no       | Description.                                                                                   |
| `greeting`     | no       | Opening message — `{ mode: static, ... }` or `{ mode: generated, ... }`. Omit for the default. |
| `dataSources`  | no       | Readable sources, each `{ kind: table, elementId }`.                                           |
| `tools`        | no       | Tools the agent can call (below).                                                              |

### `tools`

Each tool has a unique `toolId` and a `kind`:

- `mcp-connector` — an MCP connector tool.
- `warehouse-agent` — a warehouse agent, with a description of when to invoke it.
- `search-service` — a search-service tool.
- `action` — runs workbook action sequences / inline effects.

> **`agents` round-trips through the live API.** `POST` then `GET /v2/workbooks/{id}/spec` preserves the top-level `agents` array — `id`, `instructions`, `name`, `dataSources` — and the chat element's `agentId` link survives. For the exact `agents` / tool / greeting shapes, read them off a real workbook's `GET /spec` rather than the generated OpenAPI doc (which may not list `agents` yet).
