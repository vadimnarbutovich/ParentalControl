-- Additive rollout. Off by default; only explicitly capable, ready pairs enrol.
create table public.pc_access_rollout (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false
);
insert into public.pc_access_rollout(singleton,enabled) values(true,false);
create table public.pc_access_owners (
  device_id uuid primary key references public.devices(id) on delete cascade,
  customer_id text not null unique default ('pc-' || gen_random_uuid()::text),
  trial_started_at timestamptz,
  purchase_state text not null default 'unknown' check(purchase_state in ('unknown','active','inactive')),
  purchase_until timestamptz,
  lifetime boolean not null default false,
  verified_at timestamptz,
  sandbox_allowed boolean not null default false,
  revision bigint not null default 1,
  refresh_token uuid,
  refresh_until timestamptz,
  next_refresh_at timestamptz not null default '-infinity'
);
create table public.pc_access_pairs (
  family_id uuid primary key references public.families(id) on delete cascade,
  parent_id uuid not null references public.devices(id) on delete cascade,
  child_id uuid not null references public.devices(id) on delete cascade,
  parent_ready boolean not null default false,
  child_ready boolean not null default false,
  activated_at timestamptz,
  released boolean not null default false
);
alter table public.pc_access_rollout enable row level security;
alter table public.pc_access_owners enable row level security;
alter table public.pc_access_pairs enable row level security;
revoke all on public.pc_access_rollout, public.pc_access_owners, public.pc_access_pairs from public, anon, authenticated;
grant all on public.pc_access_rollout, public.pc_access_owners, public.pc_access_pairs to service_role;

create function public.pc_access_prepare(p_device uuid, p_ready boolean default false)
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
  if (select enabled from public.pc_access_rollout where singleton) and exists(
    select 1 from public.pc_access_pairs where family_id=d.family_id and parent_ready and child_ready and activated_at is null
  ) then
    update public.pc_access_owners set trial_started_at=coalesce(trial_started_at,now()),revision=revision+1 where device_id=p;
    update public.pc_access_pairs set activated_at=now() where family_id=d.family_id;
  end if;
end $$;

create function public.pc_access_snapshot(p_device uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.devices; pair public.pc_access_pairs; o public.pc_access_owners;
  deadline timestamptz; s text; enforced boolean; ms bigint;
begin
  select * into d from public.devices where id=p_device;
  if d.id is null then raise exception 'Unknown device'; end if;
  select * into pair from public.pc_access_pairs where family_id=d.family_id;
  enforced:=coalesce((select enabled from public.pc_access_rollout where singleton),false)
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

-- Single flight and cooldown are claimed atomically before any RevenueCat call.
create function public.pc_access_claim_refresh(p_owner uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare o public.pc_access_owners; token uuid:=gen_random_uuid();
begin
  select * into o from public.pc_access_owners where device_id=p_owner for update;
  if o.device_id is null or o.next_refresh_at>now() or o.refresh_until>now() then return null; end if;
  update public.pc_access_owners set refresh_token=token,refresh_until=now()+interval '30 seconds',
    next_refresh_at=now()+interval '30 seconds' where device_id=p_owner;
  return jsonb_build_object('token',token,'customerID',o.customer_id,'sandbox',o.sandbox_allowed);
end $$;
create function public.pc_access_finish_refresh(p_owner uuid,p_token uuid,p_state text,p_until timestamptz,p_lifetime boolean)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if p_state not in ('active','inactive','unknown') then raise exception 'Invalid purchase state'; end if;
  if p_state='active' and not p_lifetime and (p_until is null or p_until<=now()) then raise exception 'Invalid expiry'; end if;
  update public.pc_access_owners set
    purchase_state=case when p_state='unknown' then purchase_state else p_state end,
    purchase_until=case when p_state='unknown' then purchase_until else p_until end,
    lifetime=case when p_state='unknown' then lifetime else p_lifetime end,
    verified_at=case when p_state='unknown' then verified_at else now() end,
    revision=revision+case when p_state='unknown' then 0 else 1 end,
    refresh_token=null,refresh_until=null,
    next_refresh_at=now()+case when p_state='active' then interval '5 minutes' else interval '30 seconds' end
  where device_id=p_owner and refresh_token=p_token and refresh_until>now();
  return found;
end $$;

-- Used by scheduled jobs before emitting any paid command/retry.
create function public.pc_access_release(p_device uuid,p_released boolean)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.devices;
begin
  select * into d from public.devices where id=p_device;
  if d.role is distinct from 'parent' or d.family_id is null then raise exception 'Paired parent required'; end if;
  perform 1 from public.families where id=d.family_id for update;
  update public.pc_access_pairs set released=p_released where family_id=d.family_id and parent_id=d.id;
  if not found then raise exception 'Pairing changed'; end if;
  update public.pc_access_owners set revision=revision+1 where device_id=d.id;
end $$;

create function public.pc_access_allowed_families(p_families uuid[])
returns uuid[] language plpgsql security definer set search_path=public,pg_temp as $$
declare f uuid; child uuid; a jsonb; result uuid[]:='{}';
begin
  foreach f in array p_families loop
    select id into child from public.devices where family_id=f and role='child';
    if child is null then continue; end if;
    a:=public.pc_access_snapshot(child);
    if not (a->>'enforced')::boolean or a->>'state' in ('paid','demo') then result:=array_append(result,f); end if;
  end loop;
  return result;
end $$;

revoke all on function public.pc_access_prepare(uuid,boolean),public.pc_access_snapshot(uuid),
  public.pc_access_claim_refresh(uuid),public.pc_access_finish_refresh(uuid,uuid,text,timestamptz,boolean),
  public.pc_access_allowed_families(uuid[]),public.pc_access_release(uuid,boolean) from public,anon,authenticated;
grant execute on function public.pc_access_prepare(uuid,boolean),public.pc_access_snapshot(uuid),
  public.pc_access_claim_refresh(uuid),public.pc_access_finish_refresh(uuid,uuid,text,timestamptz,boolean),
  public.pc_access_allowed_families(uuid[]),public.pc_access_release(uuid,boolean) to service_role;

-- Store only delivery IDs and processing state, never webhook bodies or receipts.
create table public.pc_access_events (
  id text primary key check(length(id) between 1 and 128),
  token uuid,
  processing_until timestamptz,
  processed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.pc_access_events enable row level security;
revoke all on public.pc_access_events from public,anon,authenticated;
grant all on public.pc_access_events to service_role;

create function public.pc_access_claim_event(p_id text,p_customers text[])
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare e public.pc_access_events; t uuid:=gen_random_uuid(); owners jsonb; ids uuid[];
begin
  if cardinality(p_customers)>100 then raise exception 'Too many identities'; end if;
  insert into public.pc_access_events(id) values(p_id) on conflict do nothing;
  select * into e from public.pc_access_events where id=p_id for update;
  if e.processed_at is not null then return jsonb_build_object('done',true); end if;
  if e.processing_until>now() then return jsonb_build_object('busy',true); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'family_id',d.family_id)),'[]'),
    coalesce(array_agg(d.id),'{}') into owners,ids
    from public.pc_access_owners o join public.devices d on d.id=o.device_id
    where o.customer_id=any(p_customers) and d.role='parent';
  -- Fence any verification started before this event. A delayed response must
  -- not overwrite the canonical refresh triggered by a refund or transfer.
  update public.pc_access_owners set refresh_token=null,refresh_until=null,next_refresh_at=now()
    where device_id=any(ids);
  update public.pc_access_events set token=t,processing_until=now()+interval '60 seconds' where id=p_id;
  return jsonb_build_object('token',t,'owners',owners);
end $$;
create function public.pc_access_complete_event(p_id text,p_token uuid,p_success boolean)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  update public.pc_access_events set token=null,processing_until=null,
    processed_at=case when p_success then now() else null end
    where id=p_id and token=p_token and processing_until>now();
  return found;
end $$;
revoke all on function public.pc_access_claim_event(text,text[]),public.pc_access_complete_event(text,uuid,boolean) from public,anon,authenticated;
grant execute on function public.pc_access_claim_event(text,text[]),public.pc_access_complete_event(text,uuid,boolean) to service_role;
