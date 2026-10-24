-- Keep the minute cadence, authentication and transition handler unchanged.
-- Paused schedules must not spin forever; maintenance must also run WITHOUT
-- a schedule transition (renewal, demo expiry, lifetime verification).
create or replace function public.pc_access_maintenance_due(p_family uuid default null)
returns boolean language sql security definer set search_path=public,pg_temp as $$
  select exists (
    select 1 from public.pc_access_pairs p
    where (p_family is null or p.family_id=p_family)
      and p.activated_at is not null and not p.released
      and p.next_maintenance_at<=now()
      and public.pc_access_rollout_enabled(p.family_id,p.parent_id,p.child_id)
      and exists(select 1 from public.devices d where d.id=p.parent_id and d.family_id=p.family_id and d.role='parent')
      and exists(select 1 from public.devices d where d.id=p.child_id and d.family_id=p.family_id and d.role='child')
  );
$$;

create or replace function public.pc_schedule_work_due(p_family uuid default null)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare candidates uuid[];
begin
  select coalesce(array_agg(distinct s.family_id),'{}'::uuid[]) into candidates
  from public.family_block_schedules s
  where (p_family is null or s.family_id=p_family)
    and (s.is_enabled or s.is_currently_active)
    and public.pc_schedule_needs_evaluation(s,statement_timestamp());
  if cardinality(candidates)=0 then return false; end if;
  -- Use the SAME access decision as the Edge handler; no new expiry policy.
  return cardinality(public.pc_access_allowed_families(candidates))>0;
end $$;

revoke all on function public.pc_access_maintenance_due(uuid),public.pc_schedule_work_due(uuid) from public,anon,authenticated;
grant execute on function public.pc_access_maintenance_due(uuid),public.pc_schedule_work_due(uuid) to service_role;

do $$
begin
  if (select count(*) from cron.job where jobname='parental-control-evaluate-block-schedules')<>1 then
    raise exception 'Expected exactly one schedule evaluator';
  end if;
end $$;
select cron.alter_job(jobid,command := $job$
select net.http_post(
  url := 'https://tttwrzgjddalgiwmgmyz.supabase.co/functions/v1/parental-control-sync',
  headers := jsonb_build_object('Content-Type','application/json','x-cron-token',
    (select decrypted_secret from vault.decrypted_secrets where name='pc_cron_token')),
  body := jsonb_build_object('action','cron_evaluate_block_schedules','payload',jsonb_build_object()),
  timeout_milliseconds := 15000
) as request_id
where public.pc_access_maintenance_due() or public.pc_schedule_work_due();
$job$) from cron.job where jobname='parental-control-evaluate-block-schedules';

-- Even older clients may submit an unchanged token. Avoid a physical row
-- update in that case, while preserving environment discovery/reset semantics.
create or replace function public.pc_register_apns_token(p_device_id uuid,p_token text,p_environment text default null)
returns void language plpgsql set search_path='' as $$
begin
  if p_token is null or p_token !~ '^[0-9a-f]+$' or length(p_token)%2<>0 or length(p_token)>1024 then
    raise exception 'Invalid APNs token';
  end if;
  if p_environment is not null and p_environment not in ('sandbox','production') then
    raise exception 'Invalid APNs environment';
  end if;
  update public.devices
  set apns_environment=case when p_environment is not null then p_environment
        when apns_token=p_token then apns_environment else null end,
      apns_token=p_token
  where id=p_device_id and (
    apns_token is distinct from p_token or
    (p_environment is not null and apns_environment is distinct from p_environment)
  );
end $$;
