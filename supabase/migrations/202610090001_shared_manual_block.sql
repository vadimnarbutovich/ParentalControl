-- Manual block is shared by the remote parent and PIN-protected parent mode.
-- Additive migration: no user data or existing policies are removed.
alter table public.family_focus_desired_state
  add column revision bigint not null default 0 check (revision >= 0),
  add column last_child_intent uuid;
alter table public.child_runtime_state add column focus_revision bigint;

-- Old builds omit the revision (NULL). Updated clients explicitly send it, so a
-- delayed runtime upload cannot overwrite a newer locally acknowledged action.
create function public.pc_guard_focus_runtime() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.focus_revision is not null and old.focus_revision is not null
     and new.focus_revision < old.focus_revision then
    new.is_focus_active := old.is_focus_active;
    new.focus_ends_at := old.focus_ends_at;
    new.focus_revision := old.focus_revision;
  end if;
  return new;
end $$;
create trigger pc_guard_focus_runtime before update on public.child_runtime_state
  for each row execute function public.pc_guard_focus_runtime();

-- Use the same family lock for both directions. Desired state and command must
-- commit together; retrying an existing intent must not restore an old desire.
create or replace function public.replace_focus_command_atomic(
  p_family_id uuid, p_parent_device_id uuid, p_child_device_id uuid,
  p_command_type text, p_duration_seconds integer, p_intent_id uuid, p_has_token boolean
) returns table(id uuid, family_id uuid, command_type text, duration_seconds integer,
  status text, created_at timestamptz, updated_at timestamptz, retry_count integer,
  last_push_attempt_at timestamptz, error_message text, intent_id uuid, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare c public.focus_commands;
begin
  if p_command_type not in ('start_focus','end_focus') or p_intent_id is null then
    raise exception 'Invalid focus request';
  end if;
  perform 1 from public.families f where f.id=p_family_id for update;
  if not found or not exists(select 1 from public.devices d where d.id=p_parent_device_id
      and d.family_id=p_family_id and d.role='parent')
    or not exists(select 1 from public.devices d where d.id=p_child_device_id
      and d.family_id=p_family_id and d.role='child') then
    raise exception 'Paired parent and child required';
  end if;
  select x.* into c from public.focus_commands x
    where x.requested_by_device_id=p_parent_device_id and x.intent_id=p_intent_id limit 1;
  if not found then
    insert into public.family_focus_desired_state as s
      (family_id,should_focus_active,desired_duration_seconds,updated_by_device_id,updated_at,revision)
    values (p_family_id,p_command_type='start_focus',
      case when p_command_type='start_focus' then p_duration_seconds end,p_parent_device_id,clock_timestamp(),1)
    on conflict on constraint family_focus_desired_state_pkey do update set
      should_focus_active=excluded.should_focus_active,
      desired_duration_seconds=excluded.desired_duration_seconds,
      updated_by_device_id=excluded.updated_by_device_id,updated_at=excluded.updated_at,revision=s.revision+1;
    -- A focus toggle must not cancel pending location, schedule, task or budget work.
    update public.focus_commands x set status='failed',error_message='superseded_by_newer_command',updated_at=clock_timestamp()
      where x.family_id=p_family_id and x.target_device_id=p_child_device_id
      and x.command_type in ('start_focus','end_focus') and x.status in ('queued','sent','delivered');
    insert into public.focus_commands
      (family_id,requested_by_device_id,target_device_id,command_type,duration_seconds,status,
       error_message,retry_count,last_push_attempt_at,intent_id,expires_at)
    values (p_family_id,p_parent_device_id,p_child_device_id,p_command_type,p_duration_seconds,
      case when p_has_token then 'sent' else 'queued' end,
      case when p_has_token then null else 'Child APNs token missing' end,
      0,case when p_has_token then now() end,p_intent_id,now()+interval '10 minutes') returning * into c;
  end if;
  return query select c.id,c.family_id,c.command_type,c.duration_seconds,c.status,c.created_at,
    c.updated_at,c.retry_count,c.last_push_attempt_at,c.error_message,c.intent_id,c.expires_at;
end $$;

create function public.pc_set_local_manual_block(p_device uuid, p_active boolean,
  p_intent uuid, p_expected_revision bigint, p_pin_salt text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d public.devices; s public.family_focus_desired_state; outcome text;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null or d.role<>'child' or d.family_id is null then raise exception 'Paired child required'; end if;
  perform 1 from public.families where id=d.family_id for update;
  if not found then raise exception 'Family not found'; end if;
  if p_intent is null or p_active is null or p_expected_revision is null or p_expected_revision<0 then
    raise exception 'Invalid focus request';
  end if;
  select * into s from public.family_focus_desired_state where family_id=d.family_id;
  if s.last_child_intent=p_intent then
    outcome := 'accepted'; -- Response was lost: return CURRENT state, never replay.
  elsif not exists(select 1 from public.families where id=d.family_id
      and parent_pin_hash is not null and parent_pin_salt=p_pin_salt) then
    outcome := 'pin_changed';
  elsif coalesce(s.revision,0)<>p_expected_revision then
    outcome := 'conflict';
  else
    insert into public.family_focus_desired_state as state
      (family_id,should_focus_active,desired_duration_seconds,updated_by_device_id,updated_at,revision,last_child_intent)
    values(d.family_id,p_active,null,d.id,clock_timestamp(),1,p_intent)
    on conflict(family_id) do update set should_focus_active=excluded.should_focus_active,
      desired_duration_seconds=null,updated_by_device_id=d.id,updated_at=excluded.updated_at,
      revision=state.revision+1,last_child_intent=p_intent returning * into s;
    update public.focus_commands set status='failed',error_message='superseded_by_local_parent',updated_at=clock_timestamp()
      where family_id=d.family_id and target_device_id=d.id
      and command_type in ('start_focus','end_focus') and status in ('queued','sent','delivered');
    insert into public.child_runtime_state(family_id,child_device_id,is_focus_active,focus_ends_at,updated_at,focus_revision)
    values(d.family_id,d.id,p_active,null,clock_timestamp(),s.revision)
    on conflict(family_id) do update set is_focus_active=excluded.is_focus_active,focus_ends_at=null,
      updated_at=excluded.updated_at,focus_revision=excluded.focus_revision;
    outcome := 'accepted';
  end if;
  return jsonb_build_object('outcome',outcome,'desired',jsonb_build_object(
    'shouldFocusActive',coalesce(s.should_focus_active,false),'durationSeconds',s.desired_duration_seconds,
    'updatedAt',coalesce(s.updated_at,'1970-01-01'::timestamptz),'revision',coalesce(s.revision,0)));
end $$;

revoke all on function public.pc_guard_focus_runtime() from public,anon,authenticated;
revoke all on function public.pc_set_local_manual_block(uuid,boolean,uuid,bigint,text) from public,anon,authenticated;
grant execute on function public.pc_set_local_manual_block(uuid,boolean,uuid,bigint,text) to service_role;
revoke all on function public.replace_focus_command_atomic(uuid,uuid,uuid,text,integer,uuid,boolean) from public,anon,authenticated;
grant execute on function public.replace_focus_command_atomic(uuid,uuid,uuid,text,integer,uuid,boolean) to service_role;
