-- A retained demo can be attached to a new pair with next_maintenance_at=now().
-- An inconclusive purchase check does not fire the owner's change trigger, so
-- the old finish function left this pair waking every 15 minutes until expiry.
-- After its normal wake/notification, park a non-paid demo at its EXACT deadline.
-- Keep active/previously-paid verification retries, notifications and all TTLs.
create or replace function public.pc_access_finish_maintenance(p_owner uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.pc_access_owners; due timestamptz;
begin
  -- Serialize with purchase verification: a concurrent purchase must either be
  -- seen here or reschedule the pair via its trigger after this transaction.
  -- This uses the same owner -> pair lock order as the purchase update trigger.
  select * into o from public.pc_access_owners where device_id=p_owner for update;
  if o.device_id is null or o.purchase_state='active' then return; end if;
  due:=case when o.trial_started_at+interval '24 hours'>now()
    then o.trial_started_at+interval '24 hours' else 'infinity'::timestamptz end;
  update public.pc_access_pairs set next_maintenance_at=due
  where parent_id=p_owner and next_maintenance_at is distinct from due;
end $$;
revoke all on function public.pc_access_finish_maintenance(uuid) from public,anon,authenticated;
grant execute on function public.pc_access_finish_maintenance(uuid) to service_role;
