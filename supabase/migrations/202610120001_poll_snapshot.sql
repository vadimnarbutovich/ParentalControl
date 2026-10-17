-- Read-only aggregation. Device-secret authentication stays in the Edge Function;
-- this RPC is callable only by service_role and rechecks the current device/family.
-- Expiration, acknowledgement and delivery of commands are intentionally unchanged.
create function public.pc_poll_snapshot(p_device uuid,p_role text,p_include_parent_settings boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  d public.devices; child_id uuid; at_time timestamptz := statement_timestamp();
  desired jsonb; runtime jsonb; stats jsonb; pending jsonb; settings jsonb;
  failures bigint := 0;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null or d.family_id is null or d.role not in ('parent','child') or d.role is distinct from p_role then
    raise exception 'Paired device required';
  end if;
  select jsonb_build_object('should_focus_active',s.should_focus_active,
    'desired_duration_seconds',s.desired_duration_seconds,'updated_at',s.updated_at,'revision',s.revision)
    into desired from public.family_focus_desired_state s where s.family_id=d.family_id;

  if d.role='child' then
    select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) into pending from (
      select id,family_id,command_type,duration_seconds,status,created_at,updated_at
      from public.focus_commands where target_device_id=d.id and family_id=d.family_id
        and status in ('queued','sent','delivered') and expires_at>at_time
      order by created_at limit 20
    ) c;
    if p_include_parent_settings then
      select jsonb_build_object('parent_pin_hash',f.parent_pin_hash,'parent_pin_salt',f.parent_pin_salt,
        'parent_pin_updated_at',f.parent_pin_updated_at,'parent_is_pro',f.parent_is_pro,
        'parent_is_pro_updated_at',f.parent_is_pro_updated_at)
        into settings from public.families f where f.id=d.family_id;
    end if;
  else
    -- Match the previous maybeSingle lookup: absent/ambiguous child => no stats.
    select case when count(*)=1 then (array_agg(id))[1] else null end into child_id
      from public.devices where family_id=d.family_id and role='child';
    select jsonb_build_object('is_focus_active',r.is_focus_active,'focus_ends_at',r.focus_ends_at,
      'updated_at',r.updated_at,'available_seconds',r.available_seconds)
      into runtime from public.child_runtime_state r where r.family_id=d.family_id;
    select jsonb_build_object('day_start',s.day_start,'earned_seconds',s.earned_seconds,'spent_seconds',s.spent_seconds)
      into stats from public.daily_stats_snapshots s where s.child_device_id=child_id order by s.day_start desc limit 1;
    select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) into pending from (
      select id,created_at from public.focus_commands where family_id=d.family_id
        and status in ('queued','sent','delivered') and expires_at>at_time
      order by created_at limit 50
    ) c;
    select count(*) into failures from public.focus_commands where family_id=d.family_id
      and status='failed' and updated_at>=at_time-interval '30 minutes';
  end if;
  return jsonb_build_object('desiredRow',desired,'runtimeRow',runtime,'statsRow',stats,
    'pendingRows',pending,'fam',settings,'recentFailures',failures,'nowISO',at_time,
    'budget',public.pc_daily_budget_snapshot(d.id));
end $$;
revoke all on function public.pc_poll_snapshot(uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.pc_poll_snapshot(uuid,text,boolean) to service_role;
