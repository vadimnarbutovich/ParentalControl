-- Presentation-only breakdown. Preserve the signed net adjustment and all operations.
-- Older clients ignore the new optional policy fields and keep the same balance.
create or replace function public.pc_daily_budget_snapshot(p_device uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d public.devices; r public.child_runtime_state; p public.family_daily_policy;
  today date; extra integer; earned integer; granted integer;
begin
  select * into d from public.devices where id=p_device;
  if d.family_id is null or d.role not in ('parent','child') then raise exception 'Paired device required'; end if;
  select * into r from public.child_runtime_state where family_id=d.family_id;
  today := (now() at time zone coalesce(r.budget_timezone,'UTC'))::date;
  select * into p from public.family_daily_policy where family_id=d.family_id;
  select coalesce(sum(seconds),0)::integer,
         coalesce(sum(seconds) filter (where kind='reward' and seconds>0),0)::integer,
         coalesce(sum(seconds) filter (where kind='adjustment' and seconds>0),0)::integer
    into extra,earned,granted
    from public.family_budget_operations
    where family_id=d.family_id and day=today and kind in ('adjustment','reward');
  return jsonb_build_object(
    'policy',case when p.family_id is null then null else jsonb_build_object(
      'familyID',p.family_id,'limitSeconds',p.limit_seconds,'revision',p.revision,
      'extraDay',today::text,'extraSeconds',extra,
      'earnedSeconds',earned,'grantedSeconds',granted) end,
    'childReady',coalesce(r.budget_protocol=1,false),
    'appliedRevision',coalesce((r.budget_snapshot->'policy'->>'revision')::bigint,0),
    'state',r.budget_snapshot);
end $$;

revoke all on function public.pc_daily_budget_snapshot(uuid) from public,anon,authenticated;
grant execute on function public.pc_daily_budget_snapshot(uuid) to service_role;
