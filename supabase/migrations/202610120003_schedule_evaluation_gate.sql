-- Preserve unknown/whitespace timezone fallback before activating the prefilter.
-- A conservative prefilter, NOT the schedule enforcer. The existing Edge
-- handler still computes transitions, updates flags, queues commands and pushes.
-- Unknown timezone / unexpected data => run the old handler (fail open).
create or replace function public.pc_schedule_needs_evaluation(s public.family_block_schedules,p_now timestamptz)
returns boolean language plpgsql stable set search_path = '' as $$
declare tz text; local_time timestamp; minute_of_day integer; start_min integer; end_min integer;
  weekday integer; previous_weekday integer; target_active boolean;
begin
  if s.deleted_at is not null or not s.is_enabled then return s.is_currently_active; end if;
  -- Intl receives the original nonblank string. Whitespace-padded IDs must
  -- fall through to the old handler rather than being silently normalized here.
  tz := case when s.timezone_identifier is null or btrim(s.timezone_identifier)='' then 'UTC' else s.timezone_identifier end;
  -- Do not guess how Intl handles PostgreSQL-specific timezone abbreviations.
  if tz <> 'UTC' and tz !~ '^(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)/' then
    return true;
  end if;
  local_time := p_now at time zone tz;
  minute_of_day := extract(hour from local_time)::integer*60+extract(minute from local_time)::integer;
  weekday := extract(isodow from local_time)::integer; -- Mon=1 .. Sun=7, same as Intl mapper.
  previous_weekday := case when weekday=1 then 7 else weekday-1 end;
  start_min := s.start_hour*60+s.start_minute;
  end_min := s.end_hour*60+s.end_minute;
  if end_min > start_min then
    target_active := weekday=any(s.weekdays) and minute_of_day>=start_min and minute_of_day<end_min;
  elsif minute_of_day>=start_min then
    target_active := weekday=any(s.weekdays);
  elsif minute_of_day<end_min then
    target_active := previous_weekday=any(s.weekdays);
  else
    target_active := false;
  end if;
  return target_active is distinct from s.is_currently_active;
exception when others then
  return true;
end $$;
revoke all on function public.pc_schedule_needs_evaluation(public.family_block_schedules,timestamptz) from public,anon,authenticated;
grant execute on function public.pc_schedule_needs_evaluation(public.family_block_schedules,timestamptz) to service_role;

-- Apply after verifying the conservative predicate against the existing Intl handler.
-- The job cadence, authentication, timeout and transition handler are unchanged.
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
where exists (
  select 1 from public.family_block_schedules s
  where (s.is_enabled or s.is_currently_active)
    and public.pc_schedule_needs_evaluation(s,statement_timestamp())
);
$job$) from cron.job where jobname='parental-control-evaluate-block-schedules';
