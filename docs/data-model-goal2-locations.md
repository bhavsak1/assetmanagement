# Data model, Goal 2: locations (story 2.3)

Status: owner took every lean on 20 Oct 2026 (L1 A, L2 A, L3 A, L4 A). Built in migrations `2_3_location` and `2_3_location_closure`, tests in `supabase/tests/2_3_location.test.sql`.

Reads with: CLAUDE.md §6 to §8, `security-model.md` §6 and §7, `data-model-goal1.md` §2.10 and D7, `spike-1-7-rls-performance.md` §6. The spike stand-in (`scripts/spike-1-7/01_setup.sql`) is the starting shape.

## 1. `location` (public, 1.4 RLS pattern)

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `tenant_id` | uuid not null | FK `tenant` |
| `parent_id` | uuid null | Composite FK `(tenant_id, parent_id)` to `location (tenant_id, id)`. Null means a root (for example a city or a company) |
| `name` | text not null | "Plant 1" |
| `code` | text null | Optional short code, for imports ("PNQ-P1") |
| `location_type` | text null | **DECIDE L1** |
| `active` | boolean not null default true | **DECIDE L2** |
| std | | `created_at`, `updated_at`, `created_by`, `updated_by`, `deleted_at` |

- `unique (tenant_id, id)` (FK target).
- `unique (tenant_id, parent_id, name) nulls not distinct where deleted_at is null`. Names are unique **among siblings**: "Plant 1" can sit under Pune and under Nashik. This index also serves "children of X" (the tree) and leads with `tenant_id`, partial, per spike F2.
- `unique (tenant_id, code) where code is not null and deleted_at is null`.
- Triggers: `set_updated_at`, `check_soft_delete('location_hierarchy', 'manage')`, `audit` (`audit_row('data')`), and the closure triggers in §3.
- Address and coordinates (knowledge base B6) are not in this story. Add them as plain nullable columns when a story asks.

### Domain

The catalog already has `location_hierarchy` with operations `view` and `manage` (1.2 seed). No new domain. The 1.4 pattern maps as:

| Policy | Check |
|---|---|
| select | tenant and `view` |
| insert | tenant, `manage`, `tenant_can_write()` |
| update (includes move and deactivate) | tenant, `manage`, `tenant_can_write()` in `using` and `with check` |
| soft delete | update policy plus `check_soft_delete('location_hierarchy', 'manage')` |
| delete | none; `revoke delete, truncate` |

Starter groups already grant `location_hierarchy` (`data-model-goal1.md` §2.7a), so nothing to change there.

### DECIDE L1: location type

| Option | |
|---|---|
| A | `location_type text null`, free text. The 2.4 screen suggests values already used in the tenant |
| B | A `location_type` lookup table per tenant (code, name), FK from `location` |
| C | A fixed check list (site, building, area, ...) |

**Lean: A.** It is data, not an enum (CLAUDE.md §8), and needs no extra table, policies or screen. Nothing in Phase 1 branches on type. C is out: types differ per tenant ("Bay", "Line", "Warehouse").
**Owner: A.**
**Cost to reverse:** low to medium. A to B later is one migration that creates the table from the distinct values and swaps the column.

### DECIDE L2: deactivate versus soft delete

CLAUDE.md §8: locations are deactivated, never deleted. A merge (B12, later) repoints references and retires the merged-away row.

| Option | |
|---|---|
| A | `active` boolean for deactivate. `deleted_at` kept, used only for rows removed by a merge or entered by mistake |
| B | No `active`; `deleted_at` means deactivated |

**Lean: A.** A deactivated location is still history: assets and scope rules point at it, the tree shows it greyed out, and it can be reactivated. B would free its name (partial uniques) and hide it from every "where deleted_at is null" query, which is wrong for history. A also keeps the std columns the harness and guard expect.
Rules with A, enforced by a trigger:
- No insert or move under an inactive parent.
- No deactivating a location that has an active descendant. The user deactivates the leaves first. (Cascade is the other choice; refusing is simpler and never surprises.)
**Owner: A.**
**Cost to reverse:** medium once assets reference locations (Goal 3).

## 2. `location_closure`

One row per (ancestor, descendant) pair, **including the self pair at depth 0**. For Pune > Plant 1 > Bay 3: (Pune, Pune, 0), (Pune, Plant 1, 1), (Pune, Bay 3, 2), (Plant 1, Plant 1, 0), (Plant 1, Bay 3, 1), (Bay 3, Bay 3, 0).

| Column | Type | Notes |
|---|---|---|
| `tenant_id` | uuid not null | |
| `ancestor_id` | uuid not null | Composite FK `(tenant_id, ancestor_id)` to `location` |
| `descendant_id` | uuid not null | Composite FK `(tenant_id, descendant_id)` to `location` |
| `depth` | smallint not null | 0 for self, `check (depth >= 0)` |

- PK `(tenant_id, ancestor_id, descendant_id)`: "descendants of X", the scope query.
- Index `(tenant_id, descendant_id)`: "ancestors of X" (breadcrumbs, the move).
- No std columns: it is derived, like `user_effective_permission`. Only the triggers write it. It is not audited; the `parent_id` change on `location` is the audit record of a move.

### DECIDE L3: where the closure table lives

Users must never write the closure. A forged row would put a location inside someone's scope (6.1), which is a data leak.

| Option | |
|---|---|
| A | `private` schema, RLS on, no policies, no grants (like `user_effective_permission`). Only `security definer` triggers and the 6.1 scope helper read or write it |
| B | `public`, RLS on, a select policy (tenant and `location_hierarchy.view`), no insert, update or delete grants |

**Lean: A.** Not reachable through the API at all, so nothing to get wrong. The tenancy guard already accepts private tenant tables with RLS on and no policy. The 2.4 tree builds from `parent_id` (a tenant has hundreds or a few thousand nodes) and does not need the closure. If 2.4 later wants subtree queries from the client, B is a small migration (move the table, add one policy).
Note: this departs from the brief's "1.4 pattern on both tables" and "`tests.cross_tenant` for each new tenant table". `tests.cross_tenant` cannot run on the closure in either option: it inserts the same row into two tenants, and closure rows need same-tenant locations; it also needs an `id`. With A, the tests instead prove `authenticated` has no access at all, and that closure rows never cross tenants (the composite FKs).
**Owner: A.**
**Cost to reverse:** low. Moving a derived table between schemas is one migration.

## 3. Keeping the closure correct

All closure writes are in `private` trigger functions, `security definer`, fixed `search_path = ''`. Whatever path changes `location` (UI, later the API or import), the closure follows.

| Event | Trigger | Closure change |
|---|---|---|
| Insert | after insert | Self row (depth 0), plus one row per ancestor of the parent: `(a.ancestor_id, new.id, a.depth + 1)` |
| Move (`parent_id` changes) | before update: checks. after update: rewrite | Delete the pairs that link the moved subtree to its **old** ancestors. Insert the cross join of the **new** parent's ancestors and the subtree, depth `a.depth + s.depth + 1`. Pairs inside the subtree stay as they are, so the whole subtree moves with it |
| Move to root (`parent_id` set null) | same | Delete only |
| Deactivate | before update of `active` | Checks only (§1 L2 rules). Closure unchanged: deactivated nodes stay in the tree |
| Soft delete | before update of `deleted_at` | Refused while the row has a non-deleted child. Closure unchanged (the merge story decides more) |

### DECIDE L4: move as a plain update or an action function

CLAUDE.md §7.8 says actions such as transfer are functions. A move changes who can see what (with 6.1 scope: moving Bay 3 from Pune to Nashik moves Bay 3's assets out of Pune managers' scope).

| Option | |
|---|---|
| A | A plain update of `parent_id`, allowed by `location_hierarchy.manage`. Triggers keep the closure and refuse cycles |
| B | `public.move_location(id, new_parent_id)`, `security definer`, checks `manage` (or a new `move` operation seeded in the domain). Direct updates of `parent_id` refused |

**Lean: A.** The closure is correct either way, because triggers do the work. B adds a function and a second write path with nothing extra to check: `manage` is already an admin-level grant (Tenant Admin only in the starter grid). The move is audited (`audit_log` keeps old and new `parent_id`). If the owner wants a separate right to move, B with a `move` operation is a later migration that seeds one row and adds the function.
**Owner: A.**
**Cost to reverse:** low. Adding B later only narrows who can move.

### Cycle prevention

Before a move, refuse when the new parent is the row itself or one of its descendants:
`exists (select 1 from closure where tenant_id = new.tenant_id and ancestor_id = new.id and descendant_id = new.parent_id)`. The self pair (depth 0) makes "parent = self" the same check. Error code `23514` (check violation), message "a location cannot move under itself or its own descendant".

Two moves at once (A under B in one transaction, B under A in another) could each pass that check. The move takes `pg_advisory_xact_lock` on the tenant first, so moves in one tenant run one at a time. Moves are rare, so the wait never matters. Inserts do not need the lock: a new row has no descendants.

No depth limit. Not asked for; the tree is a few levels deep in practice.

## 4. How D7 scope will use it (6.1, not this story)

Nothing in `has_permission()` or `user_effective_permission` changes in 2.3. In 6.1, per D7 option X and the spike's rule (set form, once per statement):

```sql
-- 6.1 sketch, not built here. Allowed locations for the user, or null for tenant-wide.
select case when bool_or(r.id is null) then null
            else coalesce(array_agg(distinct c.descendant_id), '{}') end
from private.user_effective_permission uep
...
left join public.scope_profile_rule r on r.tenant_id = uep.tenant_id
                                     and r.scope_profile_id = uep.scope_profile_id
                                     and r.dimension = 'location'
left join private.location_closure c on c.tenant_id = r.tenant_id and c.ancestor_id = r.location_id
```

The closure PK `(tenant_id, ancestor_id, descendant_id)` serves that join with an index-only scan. Policies then use `location_id = any ((select private.scope_location_ids(...))::uuid[])`. A move needs no permission rebuild: the next query reads the new closure.
Deactivated locations stay in the closure, so assets still sitting at them stay in scope.

## 5. Tests (pgTAP)

- Closure after insert: a three-level tree gives exactly the expected pairs and depths.
- Closure after move: moving a subtree to a new parent gives the right pairs for every node in it; moving to root.
- Cycle refused: under self, under own child, under own grandchild.
- Cross-tenant parent refused (`23503`, composite FK).
- Inactive rules: no child under an inactive parent; no deactivating a parent with an active child.
- Permission steps on `location`: no grant, view, manage, read_only tenant, soft delete needs manage.
- `tests.cross_tenant('public.location', 'location_hierarchy', '{"name":"ct-row"}')`.
- Closure is closed: `authenticated` cannot select, insert, update or delete it.
- The tenancy guard stays green. The 1.6 review-point fixture gets a location row per tenant.
- `explain` of a descendants query uses the closure PK.
