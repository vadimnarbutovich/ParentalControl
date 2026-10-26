-- Exact-pair pilots: keep the global rollout OFF while validating two test devices.
-- No pilot is inserted by this migration; activation is a separate explicit operation.
-- A replacement parent/child or another family must not inherit a pilot allowance.
create table public.pc_access_pilots (
  family_id uuid primary key references public.families(id) on delete cascade,
  parent_id uuid not null references public.devices(id) on delete cascade,
  child_id uuid not null references public.devices(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.pc_access_pilots enable row level security;
revoke all on public.pc_access_pilots from public,anon,authenticated;
grant all on public.pc_access_pilots to service_role;

create function public.pc_access_rollout_enabled(p_family uuid,p_parent uuid,p_child uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce((select enabled from public.pc_access_rollout where singleton),false)
    or exists(select 1 from public.pc_access_pilots
      where family_id=p_family and parent_id=p_parent and child_id=p_child);
$$;
revoke all on function public.pc_access_rollout_enabled(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.pc_access_rollout_enabled(uuid,uuid,uuid) to service_role;

create or replace function public.pc_access_prepare(p_device uuid, p_ready boolean default false)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.devices; p uuid; c uuid; pair public.pc_access_pairs;
begin
  select * into d from public.devices where id=p_device;
  if d.role='parent' then
    insert into public.pc_access_owners(device_id) values(d.id) on conflict do nothing;
  end if;
  if d.family_id is null then return; end if;
  perform 1 from public.families where id=d.family_id for update;
  select id into p from public.devices where family_id=d.family_id and role='parent';
  select id into c from public.devices where family_id=d.family_id and role='child';
  if p is null or c is null then return; end if;
  insert into public.pc_access_owners(device_id) values(p) on conflict do nothing;
  insert into public.pc_access_pairs(family_id,parent_id,child_id) values(d.family_id,p,c)
    on conflict(family_id) do nothing;
  select * into pair from public.pc_access_pairs where family_id=d.family_id for update;
  if pair.parent_id<>p or pair.child_id<>c then
    update public.pc_access_pairs set parent_id=p,child_id=c,parent_ready=false,child_ready=false,
      activated_at=null,released=false where family_id=d.family_id;
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
  deadline timestamptz; s text; enforced boolean; ms bigint;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null then raise exception 'Unknown device'; end if;
  select * into pair from public.pc_access_pairs where family_id=d.family_id;
  enforced:=public.pc_access_rollout_enabled(d.family_id,pair.parent_id,pair.child_id)
    and pair.activated_at is not null
    and exists(select 1 from public.devices where id=pair.parent_id and family_id=d.family_id and role='parent')
    and exists(select 1 from public.devices where id=pair.child_id and family_id=d.family_id and role='child');
  if not coalesce(enforced,false) then return jsonb_build_object('enforced',false); end if;
  select * into o from public.pc_access_owners where device_id=pair.parent_id;
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
  ms:=floor(extract(epoch from now())*1000)::bigint;
  return jsonb_build_object('enforced',true,'protocolVersion',1,'familyID',d.family_id,
    'pairingID',pair.child_id,'revision',o.revision,'issuedAtMs',ms,
    'controlUntilMs',case when deadline is not null then floor(extract(epoch from deadline)*1000)::bigint end,
    'nextCheckAtMs',least(ms+900000,coalesce(floor(extract(epoch from deadline)*1000)::bigint,ms+900000)),
    'state',s,'released',pair.released);
end $$;

create or replace function public.pc_access_claim_maintenance()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare pair public.pc_access_pairs; result jsonb:='[]';
begin
  for pair in select * from public.pc_access_pairs where activated_at is not null and not released
    and public.pc_access_rollout_enabled(family_id,parent_id,child_id)
    and next_maintenance_at<=now() order by next_maintenance_at for update skip locked limit 5
  loop
    update public.pc_access_pairs set next_maintenance_at=now()+interval '15 minutes' where family_id=pair.family_id;
    if exists(select 1 from public.devices where id=pair.parent_id and family_id=pair.family_id and role='parent')
      and exists(select 1 from public.devices where id=pair.child_id and family_id=pair.family_id and role='child') then
      result:=result||jsonb_build_array(jsonb_build_object('id',pair.parent_id,'family_id',pair.family_id));
    end if;
  end loop;
  return result;
end $$;

