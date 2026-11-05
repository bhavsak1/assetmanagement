# Assetly API v1

The Assetly API lets your scripts and systems (an ERP, a CMMS, a BI tool) read and write your asset register.
Every call runs with the rights of an **integration user** in your company, so a key sees and changes exactly what a
person with the same groups and data scope would.

The machine-readable spec (OpenAPI 3) is at `GET /v1/openapi.json`.

To connect an AI agent (Claude, Cursor, an agent SDK) with the same key, see [mcp.md](mcp.md).

## 1. Get a key

1. A security admin (Administrator group) opens **Security > Integrations** and clicks **New integration user**,
   for example "ERP sync". It is an identity for scripts. It cannot sign in.
2. On **Security > Assignments**, give it groups, and a scope profile if it should see only some sites. Give it only
   what the script needs. For example, Auditor for read-only access.
3. Back on **Integrations**, click **New key**, name it and pick an expiry (90 days, 1 year, or a date up to 2
   years). The key is shown **once**. Copy it into your secret store. Assetly keeps only a hash of it.

Keys look like `asly_AbCdEfGhIjKl_...` (61 characters). Treat them like passwords. Never put them in a browser page or
a public repository.

**Rotate:** make a second key, switch your script to it, then **Revoke** the old one. An integration user can have up
to 5 active keys. Revoking, disabling the integration user, or expiry stops a key at its next call.

## 2. Call the API

Send the key as a bearer token:

```bash
curl -H "Authorization: Bearer $ASSETLY_KEY" https://<api host>/v1/me
```

```json
{ "user_id": "…", "name": "ERP sync", "tenant_id": "…", "tenant_name": "Acme Industries" }
```

The API is for server-to-server calls. It sends no CORS headers, so a web page cannot call it.

## 3. Resources

| Method and path | What | Needs (on the integration user's groups) |
|---|---|---|
| `GET /v1/me` | The key's integration user and company | nothing |
| `GET /v1/assets` | List assets (paged, see §4) | Asset core: view |
| `GET /v1/assets/{id}` | One asset (`410` if it was deleted) | Asset core: view |
| `POST /v1/assets` | Create an asset | Asset core: create |
| `PATCH /v1/assets/{id}` | Change an asset's fields | Asset core: update |
| `GET /v1/categories` | Categories | Categories: view |
| `GET /v1/locations` | Locations | Locations: view |
| `GET /v1/asset-statuses` | Your asset statuses | Asset core: view |

Rules that also apply in the app apply here:
- Purchase value is `null` without Asset financials: view, and can be set only with Asset financials: update.
- Custom fields (`custom_values`) hold only the fields the key may see; writing one needs that field's domain.
- Data scope: the key sees and creates assets only in its scope.
- Status and location do not change through `PATCH`. They are actions (transfer, status change) with their own
  rules, not yet in the API.
- A read-only company can read but not write.

### Asset fields

Read: `id, tag, name, category_id, location_id, status, status_id, status_reason, status_changed_at, quantity,
parent_asset_id, criticality, serial_number, manufacturer, model, purchase_date, purchase_value, purchase_currency,
in_service_date, custom_values, oem_vendor_id, om_vendor_id, coverage_state, created_at, updated_at, deleted_at`.
`deleted_at` is `null` except on a deleted asset (see §4).

Write (`POST`): `name` and `category_id` are required. Optional: `id` (a UUID you pick; a retry with the same `id`
gets `409`, never a second asset), `tag` (left out, your tag pattern makes one),
`location_id`, `status_id` (left out, the default active status), `quantity`, `parent_asset_id`, `criticality`
(`A`, `B`, `C`), `serial_number`, `manufacturer`, `model`, `purchase_date`, `in_service_date`, `purchase_value`,
`purchase_currency`, `custom_values`, `oem_vendor_id`, `om_vendor_id`. `PATCH` takes the same fields except
`id`, `location_id` and `status_id`. Unknown fields are refused.

Formats: ids are UUIDs, dates `YYYY-MM-DD`, timestamps ISO 8601 in UTC (`2026-11-05T09:30:00.123456Z`), money a
decimal string (`"125000.0000"`) with a 3-letter currency code.

```bash
curl -X POST -H "Authorization: Bearer $ASSETLY_KEY" -H "Content-Type: application/json" \
  -d '{"name":"Air compressor 3","category_id":"<category id>","location_id":"<location id>"}' \
  https://<api host>/v1/assets
```

## 4. Paging, filters, sync

`GET /v1/assets` returns `{ "data": [...], "next_cursor": "..." }`, oldest change first. Pass `cursor=<next_cursor>`
for the next page. `next_cursor` is `null` on the last page. `limit` is 1 to 200 (default 50). There is no total count.

Filters: `updated_since` (timestamp), `category_id` and `location_id` (each with everything below it), `status`
(`in_stock`, `active`, `under_maintenance`, `inactive`, `disposed`), `tag`, and `include_deleted` (`true` or
`false`, default `false`).

**To sync:** keep the largest `updated_at` you have seen. Next time, call with `updated_since=<that value>` and page
to the end. You may get the last row again; match on `id`.

**Deleted assets.** Without `include_deleted`, a deleted asset just drops out of the list. With
`include_deleted=true`, it comes in the same order as every other change, as a short row with only
`{ "id", "tag", "created_at", "updated_at", "deleted_at" }`. A sync script should pass it and remove rows whose
`deleted_at` is set. `GET /v1/assets/{id}` (and `PATCH`) of a deleted asset answers `410` with code `gone` and
`deleted_at`. `404` means it never existed or this key may not see it.

The master-data lists (`/v1/categories`, `/v1/locations`, `/v1/asset-statuses`) return everything in one page.

## 5. Errors

Errors use `application/problem+json` (RFC 9457):

```json
{ "type": "about:blank", "title": "Unprocessable Content", "status": 422, "code": "validation_failed",
  "detail": "body must have required property 'name'", "errors": [{ "field": "name", "code": "required" }] }
```

| Status | `code` | When |
|---|---|---|
| 401 | `unauthorized` | No key, or the key is unknown, expired or revoked, or its integration user is disabled |
| 403 | `forbidden` | The key may see the record but not do this |
| 404 | `not_found` | No such record, or the key may not see it (the two look the same) |
| 409 | `conflict` | A unique value (the `id` or the tag) is already used |
| 410 | `gone` | The asset was deleted. `deleted_at` says when |
| 422 | `validation_failed` | Bad input, or a business rule refused it (`detail` says which) |
| 429 | `rate_limited` | Over the rate limit. Wait `Retry-After` seconds |

Switch on `status` and `code`. `detail` is for people and may change.

## 6. Limits

- **120 calls a minute per key.** Over that, `429` with `Retry-After`. Ask us if you need more.
- Each call is logged with its key (never the key itself). Changes made with a key show in the audit trail with
  the integration user and the key.

## 7. Versions

- The version is in the path: `/v1`.
- Inside v1 we only add: new endpoints, new optional parameters, new response fields. **Ignore fields you do not
  know.**
- A breaking change gets `/v2`. `/v1` keeps working for at least 12 months after `/v2` ships, with a `Deprecation`
  header.
