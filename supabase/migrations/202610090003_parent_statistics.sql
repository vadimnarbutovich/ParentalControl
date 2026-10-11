-- Keep existing usage history; NULL means an unknown historical breakdown, not zero.
alter table public.daily_stats_snapshots
  add column limit_seconds integer check (limit_seconds between 0 and 86400),
  add column reward_seconds integer check (reward_seconds between 0 and 691200),
  add column granted_seconds integer check (granted_seconds between 0 and 691200),
  add column approved_tasks integer check (approved_tasks >= 0),
  add column budget_revision bigint,
  add column calendar_version integer not null default 0;

-- Both the current state and the offline archive use this same bounded batch write.
-- A literal child day is essential: day_start is DATE, not TIMESTAMPTZ.
create or replace function public.pc_sync_budget_history(p_device uuid,p_history jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.devices; entry jsonb; policy jsonb; child_day date; start_at timestamptz;
  spent integer; allocated integer; lim integer; rewards integer; granted integer; tasks integer; rev bigint;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null or d.role <> 'child' or d.family_id is null then raise exception 'Paired child required'; end if;
  if jsonb_typeof(p_history) is distinct from 'array' or jsonb_array_length(p_history)>31 then raise exception 'Invalid history'; end if;
  for entry in select value from jsonb_array_elements(p_history) loop
    policy := entry->'policy';
    if (policy->>'familyID')::uuid is distinct from d.family_id then raise exception 'Wrong family'; end if;
    child_day := (entry->>'day')::date;
    start_at := (entry->>'dayStartISO')::timestamptz;
    if child_day is null or start_at is null then raise exception 'Missing day'; end if;
    if child_day < current_date-90 then continue; end if;
    if child_day > current_date+1 or start_at > now()+interval '5 minutes' then raise exception 'Future history'; end if;
    spent := (entry->>'usedSeconds')::integer;
    lim := (policy->>'limitSeconds')::integer;
    rev := (policy->>'revision')::bigint;
    allocated := greatest(0,lim+(entry->>'extraSeconds')::integer);
    if spent is null or lim is null or rev is null or spent not between 0 and 691200
       or lim not between 0 and 86400 or allocated > 691200 or rev < 1 then raise exception 'Invalid history amount'; end if;
    rewards := null; granted := null; tasks := null;
    if policy->>'extraDay' = entry->>'day' then
      rewards := (policy->>'earnedSeconds')::integer;
      granted := (policy->>'grantedSeconds')::integer;
      if jsonb_typeof(policy->'operations')='array' then
        select count(*)::integer into tasks from jsonb_array_elements(policy->'operations') o where o->>'kind'='reward';
      end if;
    else
      rewards := 0; granted := 0; tasks := 0;
    end if;
    insert into public.daily_stats_snapshots as saved
      (family_id,child_device_id,day_start,earned_seconds,spent_seconds,limit_seconds,reward_seconds,granted_seconds,approved_tasks,budget_revision,calendar_version)
    values(d.family_id,d.id,child_day,allocated,spent,lim,rewards,granted,tasks,rev,1)
    on conflict(child_device_id,day_start) do update set
      earned_seconds=excluded.earned_seconds, spent_seconds=case when saved.calendar_version=0 then excluded.spent_seconds else greatest(saved.spent_seconds,excluded.spent_seconds) end,
      limit_seconds=excluded.limit_seconds,reward_seconds=excluded.reward_seconds,
      granted_seconds=excluded.granted_seconds,approved_tasks=excluded.approved_tasks,
      budget_revision=excluded.budget_revision,calendar_version=1
    where saved.calendar_version=0 or (excluded.budget_revision >= coalesce(saved.budget_revision,0)
      and (saved.earned_seconds,saved.spent_seconds,saved.limit_seconds,saved.reward_seconds,saved.granted_seconds,saved.approved_tasks,saved.budget_revision)
      is distinct from (excluded.earned_seconds,greatest(saved.spent_seconds,excluded.spent_seconds),excluded.limit_seconds,excluded.reward_seconds,excluded.granted_seconds,excluded.approved_tasks,excluded.budget_revision));
  end loop;
end $$;

-- One report RPC; indexes already cover (family_id, day_start) and operations(family_id, day).
create function public.pc_parent_statistics(p_device uuid,p_days integer,p_end date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d public.devices; tz text; today date; last_day date; first_day date; rows jsonb;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null or d.role <> 'parent' or d.family_id is null then raise exception 'Paired parent required'; end if;
  if p_days is null or p_days not in (7,30) then raise exception 'Invalid period'; end if;
  select budget_timezone into tz from public.child_runtime_state where family_id=d.family_id;
  tz := coalesce(tz,'UTC'); today := (now() at time zone tz)::date;
  last_day := least(coalesce(p_end,today),today);
  first_day := greatest(last_day-(p_days-1),today-89);
  if last_day < today-89 then raise exception 'Period outside retention'; end if;
  with operations as (
    select day, count(*) filter(where kind='reward')::integer as tasks,
      coalesce(sum(seconds) filter(where kind='reward' and seconds>0),0)::integer as rewards,
      coalesce(sum(seconds) filter(where kind='adjustment' and seconds>0),0)::integer as granted
    from public.family_budget_operations
    where family_id=d.family_id and day between first_day and last_day
    group by day
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'day',g.day::date::text,'usedSeconds',case when s.calendar_version=1 then s.spent_seconds end,'limitSeconds',s.limit_seconds,
    'rewardSeconds',coalesce(o.rewards,s.reward_seconds),'grantedSeconds',coalesce(o.granted,s.granted_seconds),
    'approvedTasks',coalesce(o.tasks,s.approved_tasks),
    'updatedAt',s.updated_at,'legacy',coalesce(s.calendar_version=0,false)
  ) order by g.day),'[]'::jsonb) into rows
  from generate_series(first_day::timestamp,last_day::timestamp,interval '1 day') g(day)
  left join public.daily_stats_snapshots s on s.family_id=d.family_id and s.day_start=g.day::date
  left join operations o on o.day=g.day::date;
  return jsonb_build_object('today',today::text,'timezone',tz,'days',rows);
end $$;
revoke all on function public.pc_parent_statistics(uuid,integer,date) from public,anon,authenticated;
grant execute on function public.pc_parent_statistics(uuid,integer,date) to service_role;
revoke all on function public.pc_sync_budget_history(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.pc_sync_budget_history(uuid,jsonb) to service_role;

-- Old builds / a temporarily unavailable budget monitor must not overwrite a new snapshot.
create function public.pc_sync_legacy_stats(p_device uuid,p_start timestamptz,p_allocated integer,p_used integer) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.devices;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null or d.role <> 'child' or d.family_id is null then raise exception 'Paired child required'; end if;
  if p_start is null or p_allocated is null or p_used is null or p_allocated not between 0 and 691200
    or p_used not between 0 and 691200 then raise exception 'Invalid statistics'; end if;
  insert into public.daily_stats_snapshots as saved(family_id,child_device_id,day_start,earned_seconds,spent_seconds)
  values(d.family_id,d.id,(p_start at time zone 'UTC')::date,p_allocated,p_used)
  on conflict(child_device_id,day_start) do update set earned_seconds=excluded.earned_seconds,spent_seconds=excluded.spent_seconds
  where saved.calendar_version=0 and (saved.earned_seconds,saved.spent_seconds) is distinct from (excluded.earned_seconds,excluded.spent_seconds);
end $$;
revoke all on function public.pc_sync_legacy_stats(uuid,timestamptz,integer,integer) from public,anon,authenticated;
grant execute on function public.pc_sync_legacy_stats(uuid,timestamptz,integer,integer) to service_role;
