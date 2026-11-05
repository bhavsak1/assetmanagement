# Assetly MCP server

Connect your own AI agent (Claude, Cursor, VS Code, an agent you build with an SDK) to your Assetly asset register.
The agent gets **tools** to list, read, create and change assets and to look up categories, locations and statuses.

It is the [Assetly API](api-v1.md) in another form. The agent uses the same API key, sees exactly what that key
sees, is limited the same way, and its changes show in the audit trail with the key's integration user. Assetly does
not run a model here: your agent and your AI provider do.

## 1. Get a key

Follow [api-v1.md §1](api-v1.md#1-get-a-key). Our advice for agents:

- **One integration user per agent**, for example "Claude agent". The audit trail then tells agent changes from
  script changes.
- **Read only unless it must write.** Give it the Auditor group (or a group of your own with only view rights).
- A short expiry (90 days).

## 2. The address

```
https://<api host>/mcp
```

Transport: MCP **Streamable HTTP** (no sessions, JSON answers). Auth: `Authorization: Bearer <your key>` on every
request. A missing or wrong key gets HTTP `401`.

## 3. Connect a client

Client screens change often. The steps below are a starting point; check your client's own MCP docs.

**Claude Code**

```bash
claude mcp add --transport http assetly https://<api host>/mcp --header "Authorization: Bearer <your key>"
```

**Claude Desktop** (its Connectors screen cannot send a custom header, so use the `mcp-remote` bridge, which
needs Node.js).
In `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "assetly": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://<api host>/mcp", "--header", "Authorization:${ASSETLY_AUTH}"],
      "env": { "ASSETLY_AUTH": "Bearer <your key>" }
    }
  }
}
```

(The key goes in `env`, with no space inside the `--header` argument, which some systems split.)

**Cursor, VS Code and other clients** that take a URL and headers: URL `https://<api host>/mcp`, header
`Authorization: Bearer <your key>`.

**Your own agent** (Claude API MCP connector, OpenAI Agents SDK, the MCP SDKs): give the URL and the key as the
bearer token or `Authorization` header.

**ChatGPT and Claude.ai by URL** need OAuth sign-in, which Assetly does not offer yet.

## 4. Tools

| Tool | Does | Same as | Needs |
|---|---|---|---|
| `whoami` | The key's integration user and company | `GET /v1/me` | nothing |
| `list_assets` | Assets, paged, with filters and `include_deleted` | `GET /v1/assets` | Asset core: view |
| `get_asset` | One asset by `id` | `GET /v1/assets/{id}` | Asset core: view |
| `create_asset` | A new asset | `POST /v1/assets` | Asset core: create |
| `update_asset` | Change fields of an asset (`id` plus the fields) | `PATCH /v1/assets/{id}` | Asset core: update |
| `list_categories` | Categories | `GET /v1/categories` | Categories: view |
| `list_locations` | Locations | `GET /v1/locations` | Locations: view |
| `list_asset_statuses` | Your asset statuses | `GET /v1/asset-statuses` | Asset core: view |

Arguments and results are the API's fields ([api-v1.md §3 and §4](api-v1.md#3-resources)). Results come as
structured JSON and as text. There is no delete, transfer or status-change tool.

Every tool is listed for every key. A tool the key has no right to use answers with an error that says so.

Write tools are marked as writes, so a client that asks you before a write will ask. For `create_asset`, let the
agent pass its own new `id` (a UUID): if it retries, it gets `conflict` and no second asset.

## 5. Errors

A refused call is a tool result with an error flag. Its text is the API's problem JSON, for example:

```json
{ "type": "about:blank", "title": "Forbidden", "status": 403, "code": "forbidden", "detail": "..." }
```

The `code` values are the API's (api-v1.md §5): `forbidden`, `not_found`, `gone` (the asset was deleted),
`conflict`, `validation_failed` (with `errors`), `rate_limited` (with `retry_after` in seconds).

## 6. Limits

The key's **120 calls a minute** is shared between the API and MCP. Each MCP request counts once (a tool call, a
tool list, the start of a connection). Lists return at most 200 rows a page.

## 7. Safety

- **Treat tool results as data, not instructions.** Asset names, notes and custom fields are text your people
  typed or imported. An agent that reads them may meet text written to steer it. This is the main reason to give an
  agent a read-only key unless it must write.
- The key is a password. Keep it in your client's secret store, never in a shared file or a prompt.
- Revoke the key on **Security > Integrations** to cut the agent off at its next call.

## 8. Versions

The tools follow the API's rule (api-v1.md §7): we only add (new tools, new optional arguments, new result fields).
A breaking change gets new tool names, with the old ones kept for at least 12 months.
