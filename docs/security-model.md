# Asset Management Platform: Security Model

**Purpose:** shared security design context for all work on this project. Read together with the product Knowledge Base and `technical-architecture.md`. Treat "Decided" as settled unless the product owner changes it. Treat "Proposed" and "Open" as working assumptions.

**Last updated:** 10 Oct 2026
**Status:** Model agreed at design level. Next: M1 SQL schema, default domain catalog, starter security groups.

---

## 1. Requirement

Robust, enterprise-grade security **similar to Workday and Oracle**: a security policy (domain) for each entity, managed through roles, so only allowed roles can view or change related data. The aim is the same conceptual architecture on Postgres RLS, not feature parity with decades of Workday depth.

## 2. Principles (Decided)

1. **Default deny.** No policy means no access.
2. **Additive grants.** Access is the union across a user's groups. No deny rules.
3. **Enforced in the database,** not only in the UI. A bug in a screen, the API or the AI assistant cannot show data the user may not see.
4. **One engine for everything:** UI, public API, integration users, exports and the AI assistant.
5. **Domains are data, not code.** Tenants manage groups and policies without code changes.
6. **Staged change control.** Policy edits are drafted, reviewed and activated together, with full audit.

---

## 3. Concept mapping

| Concept | Workday | Oracle Fusion | This platform |
|---|---|---|---|
| Securable unit | Security domain | Privilege (grouped into duty roles) | **Security domain** |
| Permission on a unit | Domain security policy (View, Modify, Get, Put) | Duty role to privilege | **Domain policy** (view, create, update, delete, plus custom actions) |
| Who gets it | Security group | Job role / abstract role | **Security group** (role) |
| Data scope | Constrained role-based group (by organisation) | Data role plus security profile | **Scope profile** (locations, categories, vendors, criticality) |
| Integration user | ISU plus ISSG | Integration user plus role | **Integration user** assigned to security groups |
| Staged changes | Activate pending security policy changes | Role and policy deployment | **Draft, review, activate** with version history |
| Access diagnostics | View security for securable item | Security console analysis | **"Why can this user see this?"** explainer |

---

## 4. Security domains

A domain is a named, securable slice of the product. Splitting an entity into several domains lets different roles have different depth. Each domain defines its valid operations.

| Entity | Example domains | Operations |
|---|---|---|
| Asset | Asset core; Asset financials (purchase value); Asset lifecycle actions (transfer, retire) | view, create, update, delete / view, update / execute |
| Vendor | Vendor core; Vendor tax and statutory IDs (GSTIN, PAN) | view, create, update, delete / view, update |
| Coverage | Warranty and AMC contracts; Contract values | view, create, update, delete / view, update |
| Obligation and service | Obligations; Service records | view, create, update, complete |
| Location and category | Location hierarchy; Category and field configuration | view, manage |
| Import | Excel import; Import undo | run, review, commit, undo |
| Platform | Users and security; API keys; Audit log; Tenant settings; AI usage and add-on | view, manage |
| Insights | Query-based insights; Saved widgets | ask, save, share |

**Custom fields:** each tenant-defined field definition is assigned to a domain (default: the entity's core domain). A sensitive custom field, such as a contract rate, can sit behind a restricted domain.

---

## 5. Security groups and assignment

- **Role-based groups** assigned to users, for example Tenant Admin, Plant Manager, Maintenance Planner, Technician, Auditor (read-only), Finance Viewer, Vendor Coordinator.
- **System groups** that tenants cannot edit (owner, billing).
- **Integration groups** for API keys and integration users.
- **Templates:** default groups and policies shipped per industry (aligned with the onboarding wizard). Tenants clone and edit them. They are starting points, not locks.
- **Assignment** carries a scope profile and effective dates, for example "Plant Manager, scope = Pune plant and descendants, from 1 Nov, open-ended". Temporary delegation uses the same structure.

## 6. Data scope (constrained access)

A scope profile restricts rows along dimensions: locations (including descendants), categories, vendors, criticality (A/B/C). The same group can be assigned with different scopes to different people. With no scope profile, access is tenant-wide.

---

## 7. Data model (Phase 1)

| Table | Purpose |
|---|---|
| `security_domain` | Code, entity, description, kind (entity, field, action, platform), system flag |
| `domain_operation` | Valid operations per domain |
| `security_group` | Tenant, name, type, template origin |
| `group_domain_policy` | Group, domain, operations, status (draft, active), version |
| `scope_profile` and rules | Dimensions and values per profile |
| `user_group_assignment` | User, group, scope profile, effective from and to |
| `policy_change_set` | Draft changes, submitter, approver, activated at |
| `user_effective_permission` | **Derived** (user, domain, operation, scope). Rebuilt on policy activation or assignment change |
| `sod_rule` | Segregation-of-duties conflicts between domains (later phase) |
| `security_audit_log` | Policy changes, assignments, reads of restricted domains |
| Location closure table | Ancestor and descendant pairs for fast hierarchy scope checks |

---

## 8. Enforcement in Postgres and Supabase

1. **Table access.** Base tables are not exposed directly. RLS on every table checks tenant plus `has_permission(domain, operation)`. Insert, update and delete get separate policies with `WITH CHECK`.
2. **Row scope.** A function checks the row's location, category or vendor against the user's scope, using the location closure table.
3. **Columns and sensitive fields.** RLS cannot hide columns. Expose secure views that return a value only if the user holds the field's domain, otherwise null. Custom-field JSONB is filtered per key by each field definition's domain.
4. **Actions.** Transfer, retire, import commit and similar are database functions that check their action domain, not open table writes.
5. **Performance.** Policies read the precomputed `user_effective_permission` table, not the raw policy graph. Use the `(select auth.uid())` pattern so Postgres evaluates it once per query, and `STABLE` helper functions in a private schema with a fixed search path.
6. **JWT contents.** The token carries only `tenant_id` and a permission-version number, not the full permission list. A version mismatch forces a refresh.
7. **Same engine everywhere.** The public API, integration users, exports and AI assistant resolve to a user or integration identity and hit the same checks. The AI semantic layer is built per user, so fields in domains they cannot view are never offered to the model.
8. **Service-role key.** The custom service must not use it for user-driven work, because it bypasses RLS. Reserve it for system jobs.

---

## 9. Governance features

- **Draft, review, activate:** staged policy edits applied together, with a diff and approver.
- **Security explainer:** shows the group, domain policy and scope that grant or block access for a user and record.
- **Access review report:** who holds which groups and scopes, filterable by sensitive domains, exportable.
- **Segregation of duties** (later): block or warn on conflicting domains, such as managing users and approving imports.
- **Audit:** every policy change, assignment and read of restricted domains.
- **Platform support access:** staff access to tenant data is time-boxed, logged and visible to the tenant admin.

---

## 10. Build phasing

| Milestone | Security scope |
|---|---|
| M1 Foundation | Domains, groups, policies, assignments, derived permissions, RLS helpers, staged activation, audit, cross-tenant and role tests |
| M2 Working register | Scope profiles (location and category), field-level security via secure views, default templates, security explainer |
| M3 Data in, value out | Integration users and API-key scopes on the same engine, access review report |
| Later | SoD rules, delegation workflows, periodic access certification, vendor-portal groups, condition-based rules |

---

## 11. Testing requirements

- Permission test matrix (role by domain by operation), generated and run in CI.
- Scenario tests, for example "Auditor cannot update", "Pune manager cannot see Mumbai assets".
- Cross-tenant isolation tests on every table.
- Load tests of scope checks on large tenants (multi-million assets) before M2 closes.
- Owner personally reviews generated policies. Consider an external security review before paying customers.

---

## 12. Risks and cautions

- **Complexity versus solo capacity.** This is the most intricate part of the platform. Keep M1 strictly to core tables and enforcement. Scope profiles and field-level security are M2.
- **Performance.** Scope checks at scale need index design and load testing early.
- **Permission freshness.** Derived permissions refresh on activation, and token claims lag until refresh. Apply changes within seconds and use the permission-version check. Check the database directly for sensitive actions such as role administration.
- **Policy mistakes are data leaks.** Tests and personal review are mandatory.
- **Do not clone Workday wholesale.** Skip business-process security policies until Phase 2 workflows (incidents, work orders) exist.
- **SSO and compliance** (SAML, SOC 2 evidence) depend on the platform plan tier, not on the role model.

## 13. Open items

- Default domain catalog and operation lists per entity.
- Starter security groups and policies per launch industry template.
- Whether scope dimensions beyond location, category, vendor and criticality are needed for pilots.
- Policy activation approval rules (single approver, or separate security administrator role).
- Token lifetime and permission-version refresh behaviour.

## 14. Next steps

1. M1 security schema in SQL: tables, helper functions, first RLS policies, permission test matrix.
2. Default domain catalog and starter security groups.
3. Security rules section in the starter `CLAUDE.md`.
