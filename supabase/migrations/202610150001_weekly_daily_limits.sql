-- Additive weekly limits. No existing balance, history or policy is rewritten.
alter table public.family_daily_policy add column weekly_limits_seconds integer[];
alter table public.family_budget_operations add column previous_day_limit_seconds integer
  check (previous_day_limit_seconds between 0 and 86400);
alter table public.child_runtime_state add column weekly_budget_ready boolean not null default false;

create function public.pc_valid_weekly_limits(p_limits integer[]) returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select p_limits is null or coalesce(
    array_ndims(p_limits)=1 and array_lower(p_limits,1)=1 and array_length(p_limits,1)=7
    and not exists(select 1 from unnest(p_limits) v where v is null or v<0 or v>86400),false);
$$;
revoke all on function public.pc_valid_weekly_limits(integer[]) from public,anon,authenticated;
grant execute on function public.pc_valid_weekly_limits(integer[]) to service_role;
alter table public.family_daily_policy add constraint family_daily_policy_weekly_valid
  check(public.pc_valid_weekly_limits(weekly_limits_seconds));

create or replace function public.pc_daily_budget_snapshot(p_device uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d public.devices; r public.child_runtime_state; p public.family_daily_policy;
  today date; extra integer; earned integer; granted integer; start_limit integer;
  day_limit integer; operations jsonb;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null or d.family_id is null or d.role not in ('parent','child') then raise exception 'Paired device required'; end if;
  select * into r from public.child_runtime_state where family_id=d.family_id;
  today := (now() at time zone coalesce(r.budget_timezone,'UTC'))::date;
  select * into p from public.family_daily_policy where family_id=d.family_id;
  day_limit := coalesce(p.weekly_limits_seconds[extract(isodow from today)::integer],p.limit_seconds);
  select coalesce(sum(seconds),0)::integer,
         coalesce(sum(seconds) filter (where kind='reward' and seconds>0),0)::integer,
         coalesce(sum(seconds) filter (where kind='adjustment' and seconds>0),0)::integer
    into extra,earned,granted from public.family_budget_operations
    where family_id=d.family_id and day=today and kind in ('adjustment','reward');

  -- The first edit today remembers the limit that applied before that edit.
  -- A different weekday is not an edit and never needs a server-side "grant".
  select previous_day_limit_seconds into start_limit from public.family_budget_operations
    where family_id=d.family_id and kind='limit' and day=today order by revision limit 1;
  if start_limit is null and exists(select 1 from public.family_budget_operations
      where family_id=d.family_id and kind='limit' and day=today) then
    -- Compatibility with limit operations recorded before this migration.
    select seconds into start_limit from public.family_budget_operations
      where family_id=d.family_id and kind='limit' and day<today order by revision desc limit 1;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('revision',revision,'kind',kind,'seconds',seconds)
    order by revision),'[]'::jsonb) into operations from public.family_budget_operations
    where family_id=d.family_id and day=today;
  return jsonb_build_object(
    'policy',case when p.family_id is null then null else jsonb_build_object(
      'familyID',p.family_id,'limitSeconds',day_limit,'weeklyLimitsSeconds',p.weekly_limits_seconds,
      'revision',p.revision,'extraDay',today::text,'extraSeconds',extra,
      'earnedSeconds',earned,'grantedSeconds',granted,
      'dayStartLimitSeconds',coalesce(start_limit,day_limit),'operations',operations) end,
    'childReady',coalesce(r.budget_protocol=1,false),
    'weeklyChildReady',coalesce(r.budget_protocol=1 and r.weekly_budget_ready,false),
    'childTimeZone',coalesce(r.budget_timezone,'UTC'),
    'appliedRevision',coalesce((r.budget_snapshot->'policy'->>'revision')::bigint,0),
    'state',r.budget_snapshot);
end $$;

create function public.pc_change_weekly_daily_budget(p_device uuid, p_kind text, p_seconds integer,
  p_intent uuid, p_expected_revision bigint, p_weekly_limits integer[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.devices; r public.child_runtime_state; p public.family_daily_policy;
  today date; extra bigint; day_limit integer; previous_limit integer;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null or d.role <> 'parent' or d.family_id is null then raise exception 'Paired parent required'; end if;
  perform 1 from public.families where id=d.family_id for update;
  if exists(select 1 from public.family_budget_operations where id=p_intent and family_id=d.family_id) then
    return public.pc_daily_budget_snapshot(p_device);
  end if;
  if p_intent is null or p_seconds is null or p_kind is null or p_kind not in ('limit','adjustment')
     or not public.pc_valid_weekly_limits(p_weekly_limits)
     or (p_kind<>'limit' and p_weekly_limits is not null) then raise exception 'Invalid request'; end if;
  select * into r from public.child_runtime_state where family_id=d.family_id;
  if r.budget_protocol is distinct from 1 or r.budget_timezone is null then raise exception 'child_update_required'; end if;
  if p_weekly_limits is not null and r.weekly_budget_ready is distinct from true then
    raise exception 'weekly_child_update_required';
  end if;
  today := (now() at time zone r.budget_timezone)::date;
  select * into p from public.family_daily_policy where family_id=d.family_id;
  if coalesce(p.revision,0) is distinct from p_expected_revision then raise exception 'budget_changed_refresh'; end if;
  day_limit := p_seconds;
  if p_kind='limit' then
    if p_seconds < 0 or p_seconds > 86400 then raise exception 'Invalid limit'; end if;
    day_limit := coalesce(p_weekly_limits[extract(isodow from today)::integer],p_seconds);
    previous_limit := coalesce(p.weekly_limits_seconds[extract(isodow from today)::integer],p.limit_seconds,day_limit);
    insert into public.family_daily_policy(family_id,limit_seconds,weekly_limits_seconds)
      values(d.family_id,p_seconds,p_weekly_limits)
      on conflict(family_id) do update set limit_seconds=excluded.limit_seconds,
        weekly_limits_seconds=excluded.weekly_limits_seconds,revision=public.family_daily_policy.revision+1;
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
  insert into public.family_budget_operations(id,family_id,day,kind,seconds,revision,previous_day_limit_seconds)
    select p_intent,d.family_id,today,p_kind,day_limit,revision,previous_limit
      from public.family_daily_policy where family_id=d.family_id;
  return public.pc_daily_budget_snapshot(p_device);
end $$;

-- Existing clients retain uniform limits and adjustments, but must not unknowingly erase a weekly plan.
create or replace function public.pc_change_daily_budget(p_device uuid, p_kind text, p_seconds integer,
  p_intent uuid, p_expected_revision bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.devices;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null or d.role <> 'parent' or d.family_id is null then raise exception 'Paired parent required'; end if;
  perform 1 from public.families where id=d.family_id for update;
  if p_kind='limit' and exists(select 1 from public.family_daily_policy
      where family_id=d.family_id and weekly_limits_seconds is not null) then
    raise exception 'weekly_parent_update_required';
  end if;
  return public.pc_change_weekly_daily_budget(p_device,p_kind,p_seconds,p_intent,p_expected_revision,null);
end;
$$;

revoke all on function public.pc_change_weekly_daily_budget(uuid,text,integer,uuid,bigint,integer[]) from public,anon,authenticated;
revoke all on function public.pc_change_daily_budget(uuid,text,integer,uuid,bigint) from public,anon,authenticated;
revoke all on function public.pc_daily_budget_snapshot(uuid) from public,anon,authenticated;
grant execute on function public.pc_change_weekly_daily_budget(uuid,text,integer,uuid,bigint,integer[]) to service_role;
grant execute on function public.pc_change_daily_budget(uuid,text,integer,uuid,bigint) to service_role;
grant execute on function public.pc_daily_budget_snapshot(uuid) to service_role;
