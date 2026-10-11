-- Additive migration. Existing families remain on legacy balances until explicit activation.
alter table public.child_runtime_state add column if not exists budget_protocol integer;
alter table public.child_runtime_state add column if not exists budget_timezone text;
alter table public.child_runtime_state add column if not exists budget_snapshot jsonb;

create table public.family_daily_policy (
  family_id uuid primary key references public.families(id) on delete cascade,
  limit_seconds integer not null check (limit_seconds between 0 and 86400),
  revision bigint not null default 1 check (revision > 0)
);
create table public.family_budget_operations (
  id uuid primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  day date not null,
  kind text not null check (kind in ('limit','adjustment','reward')),
  seconds integer not null check (seconds between -86400 and 86400),
  created_at timestamptz not null default now()
);
create index family_budget_operations_day on public.family_budget_operations(family_id,day);
alter table public.family_daily_policy enable row level security;
alter table public.family_budget_operations enable row level security;
revoke all on public.family_daily_policy, public.family_budget_operations from anon, authenticated;
grant all on public.family_daily_policy, public.family_budget_operations to service_role;
create policy service_role_all on public.family_daily_policy for all to service_role using (true) with check (true);
create policy service_role_all on public.family_budget_operations for all to service_role using (true) with check (true);

create function public.pc_daily_budget_snapshot(p_device uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.devices; r public.child_runtime_state; p public.family_daily_policy; today date; extra integer;
begin
  select * into d from public.devices where id=p_device;
  if d.family_id is null or d.role not in ('parent','child') then raise exception 'Paired device required'; end if;
  select * into r from public.child_runtime_state where family_id=d.family_id;
  today := (now() at time zone coalesce(r.budget_timezone,'UTC'))::date;
  select * into p from public.family_daily_policy where family_id=d.family_id;
  select coalesce(sum(seconds),0)::integer into extra from public.family_budget_operations
    where family_id=d.family_id and day=today and kind in ('adjustment','reward');
  return jsonb_build_object(
    'policy',case when p.family_id is null then null else jsonb_build_object(
      'familyID',p.family_id,'limitSeconds',p.limit_seconds,'revision',p.revision,
      'extraDay',today::text,'extraSeconds',extra) end,
    'childReady',coalesce(r.budget_protocol=1,false),
    'appliedRevision',coalesce((r.budget_snapshot->'policy'->>'revision')::bigint,0),
    'state',r.budget_snapshot);
end $$;

create function public.pc_change_daily_budget(p_device uuid, p_kind text, p_seconds integer,
  p_intent uuid, p_expected_revision bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.devices; r public.child_runtime_state; p public.family_daily_policy; today date; extra bigint;
begin
  select * into d from public.devices where id=p_device;
  if d.role <> 'parent' or d.family_id is null then raise exception 'Paired parent required'; end if;
  -- Serializes activation, edits, adjustments and task approvals for this family.
  perform 1 from public.families where id=d.family_id for update;
  if exists(select 1 from public.family_budget_operations where id=p_intent and family_id=d.family_id) then
    return public.pc_daily_budget_snapshot(p_device);
  end if;
  if p_intent is null or p_seconds is null or p_kind not in ('limit','adjustment') then raise exception 'Invalid request'; end if;
  select * into r from public.child_runtime_state where family_id=d.family_id;
  if r.budget_protocol is distinct from 1 or r.budget_timezone is null then raise exception 'child_update_required'; end if;
  today := (now() at time zone r.budget_timezone)::date;
  select * into p from public.family_daily_policy where family_id=d.family_id;
  if coalesce(p.revision,0) <> p_expected_revision then raise exception 'budget_changed_refresh'; end if;
  if p_kind='limit' then
    if p_seconds < 0 or p_seconds > 86400 then raise exception 'Invalid limit'; end if;
    insert into public.family_daily_policy(family_id,limit_seconds) values(d.family_id,p_seconds)
      on conflict(family_id) do update set limit_seconds=excluded.limit_seconds,revision=public.family_daily_policy.revision+1;
    -- An old balance command must not add legacy earnings on top of the new allowance.
    update public.focus_commands set status='failed',error_message='replaced_by_daily_budget',updated_at=now()
      where family_id=d.family_id and status in ('queued','sent','delivered')
      and command_type in ('add_earned_seconds','subtract_earned_seconds','reset_earned_balance');
  else
    if p.family_id is null then raise exception 'daily_limit_required'; end if;
    if abs(p_seconds::bigint)>86400 then raise exception 'Invalid adjustment'; end if;
    select coalesce(sum(seconds),0) into extra from public.family_budget_operations
      where family_id=d.family_id and day=today and kind in ('adjustment','reward');
    if abs(extra+p_seconds)>604800 then raise exception 'Daily adjustment too large'; end if;
    update public.family_daily_policy set revision=revision+1 where family_id=d.family_id;
  end if;
  insert into public.family_budget_operations(id,family_id,day,kind,seconds)
    values(p_intent,d.family_id,today,p_kind,p_seconds);
  return public.pc_daily_budget_snapshot(p_device);
end $$;

-- Approval and today's bonus are a single transaction: no lost or double rewards.
create function public.pc_approve_task_daily_budget(p_device uuid,p_task uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.devices; r public.child_runtime_state; t public.family_child_tasks; today date; extra bigint;
begin
  select * into d from public.devices where id=p_device;
  if d.role <> 'parent' or d.family_id is null then raise exception 'Paired parent required'; end if;
  perform 1 from public.families where id=d.family_id for update;
  if not exists(select 1 from public.family_daily_policy where family_id=d.family_id) then
    return jsonb_build_object('legacy',true);
  end if;
  select * into t from public.family_child_tasks where id=p_task and family_id=d.family_id for update;
  if t.id is null or t.status<>'submitted' or t.deleted_at is not null then
    return jsonb_build_object('legacy',false,'credited',false);
  end if;
  select * into r from public.child_runtime_state where family_id=d.family_id;
  today := (now() at time zone coalesce(r.budget_timezone,'UTC'))::date;
  select coalesce(sum(seconds),0) into extra from public.family_budget_operations
    where family_id=d.family_id and day=today and kind in ('adjustment','reward');
  if extra+t.reward_seconds>604800 then raise exception 'Daily adjustment too large'; end if;
  insert into public.family_budget_operations(id,family_id,day,kind,seconds)
    values(t.id,d.family_id,today,'reward',t.reward_seconds);
  update public.family_child_tasks set status='approved',approved_at=now(),updated_at=now() where id=t.id;
  update public.family_daily_policy set revision=revision+1 where family_id=d.family_id;
  return jsonb_build_object('legacy',false,'credited',t.reward_seconds>0);
end $$;

revoke all on function public.pc_daily_budget_snapshot(uuid) from public,anon,authenticated;
revoke all on function public.pc_change_daily_budget(uuid,text,integer,uuid,bigint) from public,anon,authenticated;
revoke all on function public.pc_approve_task_daily_budget(uuid,uuid) from public,anon,authenticated;
grant execute on function public.pc_daily_budget_snapshot(uuid) to service_role;
grant execute on function public.pc_change_daily_budget(uuid,text,integer,uuid,bigint) to service_role;
grant execute on function public.pc_approve_task_daily_budget(uuid,uuid) to service_role;

create function public.pc_sync_budget_history(p_device uuid,p_history jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.devices; entry jsonb; start_at timestamptz; spent integer; allocated integer;
begin
  select * into d from public.devices where id=p_device;
  if d.role <> 'child' or d.family_id is null then raise exception 'Paired child required'; end if;
  if jsonb_typeof(p_history)<>'array' or jsonb_array_length(p_history)>30 then raise exception 'Invalid history'; end if;
  for entry in select value from jsonb_array_elements(p_history) loop
    if (entry->'policy'->>'familyID')::uuid <> d.family_id then raise exception 'Wrong family'; end if;
    start_at := (entry->>'dayStartISO')::timestamptz;
    if start_at < now()-interval '90 days' then continue; end if;
    if start_at > now() then raise exception 'Future history'; end if;
    spent := (entry->>'usedSeconds')::integer;
    allocated := greatest(0,(entry->'policy'->>'limitSeconds')::integer+(entry->>'extraSeconds')::integer);
    if spent < 0 or spent > 691200 or allocated > 691200 then raise exception 'Invalid history amount'; end if;
    insert into public.daily_stats_snapshots(family_id,child_device_id,day_start,steps,earned_seconds,spent_seconds,push_ups,squats,focus_session_total_seconds)
      values(d.family_id,d.id,start_at,0,allocated,spent,0,0,0)
      on conflict(child_device_id,day_start) do update
      set earned_seconds=excluded.earned_seconds,spent_seconds=excluded.spent_seconds;
  end loop;
end $$;
revoke all on function public.pc_sync_budget_history(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.pc_sync_budget_history(uuid,jsonb) to service_role;
