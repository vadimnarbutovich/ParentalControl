-- Older-policy reports may still contain newer usage. Merge usage monotonically,
-- but do not replace the newer limit/reward breakdown with their older policy.
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
      spent_seconds=case when saved.calendar_version=0 then excluded.spent_seconds else greatest(saved.spent_seconds,excluded.spent_seconds) end,
      earned_seconds=case when saved.calendar_version=0 or excluded.budget_revision>=coalesce(saved.budget_revision,0) then excluded.earned_seconds else saved.earned_seconds end,
      limit_seconds=case when saved.calendar_version=0 or excluded.budget_revision>=coalesce(saved.budget_revision,0) then excluded.limit_seconds else saved.limit_seconds end,
      reward_seconds=case when saved.calendar_version=0 or excluded.budget_revision>=coalesce(saved.budget_revision,0) then excluded.reward_seconds else saved.reward_seconds end,
      granted_seconds=case when saved.calendar_version=0 or excluded.budget_revision>=coalesce(saved.budget_revision,0) then excluded.granted_seconds else saved.granted_seconds end,
      approved_tasks=case when saved.calendar_version=0 or excluded.budget_revision>=coalesce(saved.budget_revision,0) then excluded.approved_tasks else saved.approved_tasks end,
      budget_revision=case when saved.calendar_version=0 or excluded.budget_revision>=coalesce(saved.budget_revision,0) then excluded.budget_revision else saved.budget_revision end,
      calendar_version=1
    where saved.calendar_version=0 or excluded.spent_seconds>saved.spent_seconds or
      (excluded.budget_revision>=coalesce(saved.budget_revision,0) and
       (saved.earned_seconds,saved.limit_seconds,saved.reward_seconds,saved.granted_seconds,saved.approved_tasks,saved.budget_revision)
       is distinct from (excluded.earned_seconds,excluded.limit_seconds,excluded.reward_seconds,excluded.granted_seconds,excluded.approved_tasks,excluded.budget_revision));
  end loop;
end $$;

-- Usage is a cumulative counter, not an increment. App and monitor uploads may
-- arrive out of order. Preserve the newest applied policy and the greatest usage
-- for the same child/day. Never change focus, schedules or the actual daily policy.
create function public.pc_guard_budget_runtime() returns trigger
language plpgsql set search_path = '' as $$
declare previous jsonb; incoming jsonb; chosen jsonb; used integer;
begin
  previous := old.budget_snapshot;
  incoming := new.budget_snapshot;
  if old.child_device_id is distinct from new.child_device_id or previous is null then return new; end if;
  if incoming is null or incoming->>'day' < previous->>'day' then
    new.budget_snapshot := previous;
    new.budget_timezone := old.budget_timezone;
    new.budget_protocol := old.budget_protocol;
  elsif incoming->>'day' = previous->>'day' then
    used := greatest((previous->>'usedSeconds')::integer,(incoming->>'usedSeconds')::integer);
    if (incoming->'policy'->>'revision')::bigint < (previous->'policy'->>'revision')::bigint then
      chosen := previous;
      new.budget_timezone := old.budget_timezone;
      new.budget_protocol := old.budget_protocol;
    else
      chosen := incoming;
    end if;
    new.budget_snapshot := jsonb_set(chosen,'{usedSeconds}',to_jsonb(used));
  end if;
  -- Also protects the old update_child_balance endpoint from regressing a budget.
  new.available_seconds := greatest(0,
    (new.budget_snapshot->'policy'->>'limitSeconds')::integer
    + (new.budget_snapshot->>'extraSeconds')::integer
    - (new.budget_snapshot->>'usedSeconds')::integer);
  return new;
end $$;
revoke all on function public.pc_guard_budget_runtime() from public,anon,authenticated;
create trigger pc_guard_budget_runtime before update on public.child_runtime_state
  for each row execute function public.pc_guard_budget_runtime();

-- The extension cannot write focus state, commands, limits or rewards. Its report
-- is authenticated with the same device credential as foreground sync.
create function public.pc_report_child_usage(p_device uuid,p_state jsonb,p_timezone text,p_history jsonb default '[]'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare d public.devices; policy jsonb; used integer; extra integer; lim integer; rev bigint; child_day date;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null or d.role <> 'child' or d.family_id is null then raise exception 'Paired child required'; end if;
  if jsonb_typeof(p_state) is distinct from 'object' then raise exception 'Invalid state'; end if;
  policy := p_state->'policy';
  if (policy->>'familyID')::uuid is distinct from d.family_id then raise exception 'Wrong family'; end if;
  if p_timezone is null or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone) then
    raise exception 'Invalid timezone';
  end if;
  used := (p_state->>'usedSeconds')::integer;
  extra := (p_state->>'extraSeconds')::integer;
  lim := (policy->>'limitSeconds')::integer;
  rev := (policy->>'revision')::bigint;
  child_day := (p_state->>'day')::date;
  if used is null or used not between 0 and 691200 or extra is null or extra not between -604800 and 604800
     or lim is null or lim not between 0 and 86400 or rev is null or rev<1 or child_day is null
     or p_state->>'day' <> child_day::text then raise exception 'Invalid budget state'; end if;
  if jsonb_typeof(p_history) is distinct from 'array' or jsonb_array_length(p_history)>30 then raise exception 'Invalid history'; end if;
  -- Validates dates, amounts and family for every archived entry; same retention as main app.
  perform public.pc_sync_budget_history(p_device,p_history || jsonb_build_array(p_state));
  -- An expired queued upload can still fill history, but must not become current runtime.
  if child_day < (now() at time zone p_timezone)::date then return; end if;
  insert into public.child_runtime_state as saved
    (family_id,child_device_id,budget_protocol,budget_timezone,budget_snapshot,available_seconds,updated_at)
  values(d.family_id,d.id,1,p_timezone,p_state,greatest(0,lim+extra-used),now())
  on conflict(family_id) do update set
    child_device_id=excluded.child_device_id,budget_protocol=1,budget_timezone=excluded.budget_timezone,
    budget_snapshot=excluded.budget_snapshot,available_seconds=excluded.available_seconds,updated_at=now();
end $$;
revoke all on function public.pc_report_child_usage(uuid,jsonb,text,jsonb) from public,anon,authenticated;
grant execute on function public.pc_report_child_usage(uuid,jsonb,text,jsonb) to service_role;
