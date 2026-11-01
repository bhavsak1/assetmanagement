-- Story 6.2, R2 (data-model-goal6.md §15 G2, §16): old_data and new_data hold whole rows (money, costs,
-- every custom key), so audit_log.view alone must not read them. A column revoke does nothing under a
-- table grant, so the grant is replaced by a column list without them. Data reads go through masking
-- definer functions (asset_history); a masked tenant-wide reader comes with an audit screen.
revoke select on public.audit_log from authenticated;
grant select (id, tenant_id, occurred_at, category, actor_type, actor_user_id, action, table_name, record_id,
              reason, transaction_id)
  on public.audit_log to authenticated;
