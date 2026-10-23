-- Enrollment follows the parent device, not a disposable family row.
-- Global rollout stays unchanged. Existing non-pilot families stay legacy.
alter table public.pc_access_owners add column enrolled boolean not null default false;
update public.pc_access_owners o set enrolled=true
where exists(select 1 from public.pc_access_pilots p where p.parent_id=o.device_id);

create or replace function public.pc_access_rollout_enabled(p_family uuid,p_parent uuid,p_child uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce((select enabled from public.pc_access_rollout where singleton),false)
    or coalesce((select enrolled from public.pc_access_owners where device_id=p_parent),false)
    or exists(select 1 from public.pc_access_pilots
      where family_id=p_family and parent_id=p_parent and child_id=p_child);
$$;

create function public.pc_access_enroll_pilot()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.pc_access_owners(device_id,enrolled) values(new.parent_id,true)
    on conflict(device_id) do update set enrolled=true;
  return new;
end $$;
revoke all on function public.pc_access_enroll_pilot() from public,anon,authenticated;
create trigger pc_access_enroll_pilot after insert or update on public.pc_access_pilots
for each row execute function public.pc_access_enroll_pilot();

create or replace function public.pc_access_prepare(p_device uuid, p_ready boolean default false)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.devices; p uuid; c uuid; pair public.pc_access_pairs;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null then raise exception 'Unknown device'; end if;
  if d.role='parent' then
    insert into public.pc_access_owners(device_id) values(d.id) on conflict do nothing;
  end if;
  if d.family_id is null then return; end if;
  perform 1 from public.families where id=d.family_id for update;
  select id into p from public.devices where family_id=d.family_id and role='parent';
  select id into c from public.devices where family_id=d.family_id and role='child';
  if p is null or c is null then return; end if;
  insert into public.pc_access_owners(device_id) values(p) on conflict do nothing;
  if public.pc_access_rollout_enabled(d.family_id,p,c) then
    update public.pc_access_owners set enrolled=true where device_id=p and not enrolled;
  end if;
  insert into public.pc_access_pairs(family_id,parent_id,child_id) values(d.family_id,p,c)
    on conflict(family_id) do nothing;
  select * into pair from public.pc_access_pairs where family_id=d.family_id for update;
  if pair.parent_id<>p or pair.child_id<>c then
    update public.pc_access_pairs set parent_id=p,child_id=c,parent_ready=false,child_ready=false,
      activated_at=null,released=false where family_id=d.family_id;
    update public.pc_access_owners set revision=revision+1 where device_id=p;
  end if;
  if d.role='parent' then
    update public.pc_access_pairs set parent_ready=p_ready where family_id=d.family_id;
  elsif d.role='child' then
    update public.pc_access_pairs set child_ready=p_ready where family_id=d.family_id;
  end if;
  if public.pc_access_rollout_enabled(d.family_id,p,c) and exists(
    select 1 from public.pc_access_pairs where family_id=d.family_id and parent_ready and child_ready and activated_at is null
  ) then
    update public.pc_access_owners set trial_started_at=coalesce(trial_started_at,now()),revision=revision+1 where device_id=p;
    update public.pc_access_pairs set activated_at=now() where family_id=d.family_id;
  end if;
end $$;

create or replace function public.pc_access_snapshot(p_device uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.devices; pair public.pc_access_pairs; o public.pc_access_owners;
  p uuid; c uuid; deadline timestamptz; s text; ms bigint;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null then raise exception 'Unknown device'; end if;
  select id into p from public.devices where family_id=d.family_id and role='parent';
  select id into c from public.devices where family_id=d.family_id and role='child';
  if p is null and d.role='parent' then p:=d.id; end if;
  if not public.pc_access_rollout_enabled(d.family_id,p,c) then
    return jsonb_build_object('enforced',false);
  end if;
  select * into o from public.pc_access_owners where device_id=p;
  select * into pair from public.pc_access_pairs where family_id=d.family_id and parent_id=p and child_id=c;
  -- A missing/unready pair is SETUP, never unrestricted legacy access.
  -- No lease: child enforcers release shields. Only configuration is permitted.
  if pair.activated_at is null then
    s:='setup';
  else
    if not pair.released and o.purchase_state='active' and o.verified_at is not null then
      deadline:=least(o.verified_at+interval '24 hours',case when o.lifetime then 'infinity'::timestamptz else o.purchase_until end);
      if deadline>now() then s:='paid'; else deadline:=null; end if;
    end if;
    if not pair.released and deadline is null and o.trial_started_at+interval '24 hours'>now() then
      deadline:=o.trial_started_at+interval '24 hours'; s:='demo';
    end if;
    if deadline is null then
      s:=case when o.purchase_state='unknown' or o.verified_at is null or o.verified_at+interval '24 hours'<=now()
        then 'verification_required' else 'expired' end;
    end if;
  end if;
  ms:=floor(extract(epoch from now())*1000)::bigint;
  return jsonb_build_object('enforced',true,'protocolVersion',1,'familyID',d.family_id,
    'pairingID',c,'revision',coalesce(o.revision,1),'issuedAtMs',ms,
    'controlUntilMs',case when deadline is not null then floor(extract(epoch from deadline)*1000)::bigint end,
    'nextCheckAtMs',least(ms+900000,coalesce(floor(extract(epoch from deadline)*1000)::bigint,ms+900000)),
    'state',s,'released',coalesce(pair.released,false));
end $$;
