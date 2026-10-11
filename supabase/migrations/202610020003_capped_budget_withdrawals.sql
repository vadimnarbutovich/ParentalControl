-- Preserve all operation amounts; add an explicit order for exactly-once delivery.
lock table public.family_daily_policy, public.family_budget_operations in share row exclusive mode;
do $$
begin
  if exists(select 1 from public.family_daily_policy p where p.revision <>
    (select count(*) from public.family_budget_operations o where o.family_id=p.family_id)) then
    raise exception 'Budget history does not match policy revision; manual review required';
  end if;
end $$;
alter table public.family_budget_operations add column revision bigint;
with ordered as (
  select id,row_number() over(partition by family_id order by created_at,id) as revision
  from public.family_budget_operations
)
update public.family_budget_operations o set revision=x.revision from ordered x where o.id=x.id;
alter table public.family_budget_operations alter column revision set not null;
alter table public.family_budget_operations add constraint family_budget_operations_revision_positive check(revision>0);
create unique index family_budget_operations_revision on public.family_budget_operations(family_id,revision);

create or replace function public.pc_change_daily_budget(p_device uuid, p_kind text, p_seconds integer,
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
  insert into public.family_budget_operations(id,family_id,day,kind,seconds,revision)
    select p_intent,d.family_id,today,p_kind,p_seconds,revision
      from public.family_daily_policy where family_id=d.family_id;
  return public.pc_daily_budget_snapshot(p_device);
end $$;

-- Approval and today's bonus are a single transaction: no lost or double rewards.
create or replace function public.pc_approve_task_daily_budget(p_device uuid,p_task uuid) returns jsonb
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
  insert into public.family_budget_operations(id,family_id,day,kind,seconds,revision)
    select t.id,d.family_id,today,'reward',t.reward_seconds,revision+1
      from public.family_daily_policy where family_id=d.family_id;
  update public.family_child_tasks set status='approved',approved_at=now(),updated_at=now() where id=t.id;
  update public.family_daily_policy set revision=revision+1 where family_id=d.family_id;
  return jsonb_build_object('legacy',false,'credited',t.reward_seconds>0);
end $$;

create or replace function public.pc_daily_budget_snapshot(p_device uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d public.devices; r public.child_runtime_state; p public.family_daily_policy;
  today date; extra integer; earned integer; granted integer; start_limit integer; operations jsonb;
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
  select seconds into start_limit from public.family_budget_operations
    where family_id=d.family_id and kind='limit' and day<today order by revision desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('revision',revision,'kind',kind,'seconds',seconds)
    order by revision),'[]'::jsonb) into operations from public.family_budget_operations
    where family_id=d.family_id and day=today;
  return jsonb_build_object(
    'policy',case when p.family_id is null then null else jsonb_build_object(
      'familyID',p.family_id,'limitSeconds',p.limit_seconds,'revision',p.revision,
      'extraDay',today::text,'extraSeconds',extra,
      'earnedSeconds',earned,'grantedSeconds',granted,
      'dayStartLimitSeconds',coalesce(start_limit,p.limit_seconds),'operations',operations) end,
    'childReady',coalesce(r.budget_protocol=1,false),
    'appliedRevision',coalesce((r.budget_snapshot->'policy'->>'revision')::bigint,0),
    'state',r.budget_snapshot);
end $$;

revoke all on function public.pc_daily_budget_snapshot(uuid) from public,anon,authenticated;
grant execute on function public.pc_daily_budget_snapshot(uuid) to service_role;
