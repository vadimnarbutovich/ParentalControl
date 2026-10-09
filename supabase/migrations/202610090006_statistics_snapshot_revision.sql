-- Keep live parent-poll updates from replacing a newer report snapshot.
create or replace function public.pc_parent_statistics(p_device uuid,p_days integer,p_end date default null) returns jsonb
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
    'budgetRevision',s.budget_revision,'updatedAt',s.updated_at,'legacy',coalesce(s.calendar_version=0,false)
  ) order by g.day),'[]'::jsonb) into rows
  from generate_series(first_day::timestamp,last_day::timestamp,interval '1 day') g(day)
  left join public.daily_stats_snapshots s on s.family_id=d.family_id and s.day_start=g.day::date
  left join operations o on o.day=g.day::date;
  return jsonb_build_object('today',today::text,'timezone',tz,'days',rows);
end $$;
