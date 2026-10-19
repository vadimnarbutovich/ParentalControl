-- LPSE uses a separate token, but keeps the existing command receipts and last-location row.
alter table public.devices add column if not exists location_push_token text;
alter table public.devices add column if not exists location_push_environment text
  check (location_push_environment in ('sandbox', 'production'));

create or replace function public.pc_request_location_push(p_device uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare parent public.devices; child public.devices; cmd public.focus_commands;
begin
  select * into parent from public.devices where id=p_device;
  if parent.role is distinct from 'parent' or parent.family_id is null then raise exception 'Paired parent required'; end if;
  -- Serialize taps from multiple parent requests, without generating extra APNs events.
  perform 1 from public.families where id=parent.family_id for update;
  select * into child from public.devices where family_id=parent.family_id and role='child';
  if child.id is null then raise exception 'Child not linked'; end if;
  select * into cmd from public.focus_commands where family_id=parent.family_id
    and target_device_id=child.id and command_type='request_location'
    and ((status in ('queued','sent','delivered') and expires_at>now()) or created_at>now()-interval '30 seconds')
    order by created_at desc limit 1;
  if cmd.id is not null then return jsonb_build_object('command',to_jsonb(cmd),'dispatch',false); end if;
  insert into public.focus_commands(family_id,requested_by_device_id,target_device_id,command_type,
    status,error_message,expires_at,retry_count,last_push_attempt_at)
  values(parent.family_id,parent.id,child.id,'request_location',
    case when child.location_push_token is null then 'failed' else 'sent' end,
    case when child.location_push_token is null then 'location_push_not_ready' end,
    now()+interval '90 seconds',1,now()) returning * into cmd;
  return jsonb_build_object('command',to_jsonb(cmd),'dispatch',child.location_push_token is not null,
    'token',child.location_push_token,'environment',child.location_push_environment);
end $$;

create or replace function public.pc_finish_location_push(p_device uuid,p_command uuid,p_result jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare dev public.devices; cmd public.focus_commands; captured timestamptz; lat double precision; lon double precision; accuracy double precision;
begin
  select * into dev from public.devices where id=p_device for share;
  if dev.role is distinct from 'child' or dev.family_id is null then raise exception 'Paired child required'; end if;
  select * into cmd from public.focus_commands where id=p_command and target_device_id=dev.id
    and family_id=dev.family_id and command_type='request_location' for update;
  if cmd.id is null then raise exception 'Unknown location request'; end if;
  if cmd.status='applied' then return; end if; -- retry after a lost HTTP response
  if cmd.status not in ('sent','delivered','queued') or cmd.expires_at<=now() then raise exception 'Location request expired'; end if;
  if p_result->>'errorCode' is not null then
    if p_result->>'errorCode' not in ('location_always_required','location_services_disabled','location_timeout','location_unavailable') then
      raise exception 'Invalid location error';
    end if;
    update public.focus_commands set status='failed',error_message=p_result->>'errorCode',updated_at=now() where id=cmd.id;
    return;
  end if;
  captured := (p_result->>'capturedAtISO')::timestamptz;
  lat := (p_result->>'latitude')::double precision;
  lon := (p_result->>'longitude')::double precision;
  accuracy := (p_result->>'horizontalAccuracy')::double precision;
  if captured is null or captured<cmd.created_at-interval '5 seconds' or captured>now()+interval '5 seconds'
    or captured<now()-interval '90 seconds' or lat is null or not (lat between -90 and 90)
    or lon is null or not (lon between -180 and 180) or accuracy is null or not (accuracy between 0 and 100000) then
    raise exception 'Invalid location';
  end if;
  insert into public.child_location_state(family_id,child_device_id,latitude,longitude,horizontal_accuracy,captured_at,updated_at)
  values(dev.family_id,dev.id,lat,lon,accuracy,captured,now())
  on conflict(family_id) do update set child_device_id=excluded.child_device_id,latitude=excluded.latitude,
    longitude=excluded.longitude,horizontal_accuracy=excluded.horizontal_accuracy,captured_at=excluded.captured_at,updated_at=excluded.updated_at
    where public.child_location_state.captured_at<=excluded.captured_at;
  update public.focus_commands set status='applied',error_message=null,applied_at=now(),updated_at=now() where id=cmd.id;
end $$;

revoke all on function public.pc_request_location_push(uuid) from public, anon, authenticated;
revoke all on function public.pc_finish_location_push(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.pc_request_location_push(uuid) to service_role;
grant execute on function public.pc_finish_location_push(uuid,uuid,jsonb) to service_role;
