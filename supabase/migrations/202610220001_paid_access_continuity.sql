-- A canonical paid verification grants a bounded 24h continuity lease. Neither
-- negative responses nor outages move it. Demo and explicit release are unchanged.
alter table public.pc_access_owners add column paid_access_until timestamptz;
update public.pc_access_owners set paid_access_until=verified_at+interval '24 hours',
  revision=revision+1, next_refresh_at=now(),refresh_token=null,refresh_until=null
where purchase_state='active' and verified_at is not null;

create or replace function public.pc_access_finish_refresh(p_owner uuid,p_token uuid,p_state text,p_until timestamptz,p_lifetime boolean)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if p_state not in ('active','inactive','unknown') then raise exception 'Invalid purchase state'; end if;
  if p_state='active' and not p_lifetime and (p_until is null or p_until<=now()) then raise exception 'Invalid expiry'; end if;
  update public.pc_access_owners set
    purchase_state=case when p_state='unknown' then purchase_state else p_state end,
    purchase_until=case when p_state='unknown' then purchase_until else p_until end,
    lifetime=case when p_state='unknown' then lifetime else p_lifetime end,
    verified_at=case when p_state='unknown' then verified_at else now() end,
    paid_access_until=case when p_state='active' then now()+interval '24 hours' else paid_access_until end,
    revision=revision+case when p_state='unknown' then 0 else 1 end,
    refresh_token=null,refresh_until=null,
    next_refresh_at=case when p_state='active' then
      least(now()+interval '5 minutes',greatest(now()+interval '30 seconds',
        case when p_lifetime then now()+interval '5 minutes' else p_until-interval '1 minute' end))
      else now()+interval '30 seconds' end
  where device_id=p_owner and refresh_token=p_token and refresh_until>now();
  return found;
end $$;

create or replace function public.pc_access_snapshot(p_device uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.devices; pair public.pc_access_pairs; o public.pc_access_owners;
  p uuid; c uuid; deadline timestamptz; s text; ms bigint; check_at timestamptz;
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
  if pair.activated_at is null then s:='setup';
  else
    if not pair.released and o.paid_access_until>now() then
      deadline:=o.paid_access_until; s:='paid';
    end if;
    if not pair.released and deadline is null and o.trial_started_at+interval '24 hours'>now() then
      deadline:=o.trial_started_at+interval '24 hours'; s:='demo';
    end if;
    if deadline is null then
      s:=case when o.purchase_state='unknown' or o.verified_at is null or o.verified_at+interval '24 hours'<=now()
        then 'verification_required' else 'expired' end;
    end if;
  end if;
  check_at:=now()+interval '15 minutes';
  if s='paid' and o.purchase_state='active' and not o.lifetime then
    check_at:=least(check_at,greatest(now()+interval '30 seconds',
      coalesce(o.purchase_until,now())-interval '1 minute'));
  end if;
  check_at:=least(check_at,coalesce(deadline,check_at));
  ms:=floor(extract(epoch from now())*1000)::bigint;
  return jsonb_build_object('enforced',true,'protocolVersion',1,'familyID',d.family_id,
    'pairingID',c,'revision',coalesce(o.revision,1),'issuedAtMs',ms,
    'controlUntilMs',case when deadline is not null then floor(extract(epoch from deadline)*1000)::bigint end,
    'nextCheckAtMs',floor(extract(epoch from check_at)*1000)::bigint,
    'state',s,'released',coalesce(pair.released,false));
end $$;

create or replace function public.pc_access_schedule_maintenance()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare due timestamptz;
begin
  if new.purchase_state='active' and new.verified_at is not null then
    due:=greatest(now()+interval '1 minute',least(new.verified_at+interval '12 hours',
      case when new.lifetime then 'infinity'::timestamptz else new.purchase_until-interval '1 minute' end));
  elsif new.paid_access_until>now() then due:=now()+interval '15 minutes';
  elsif new.trial_started_at+interval '24 hours'>now() then due:=new.trial_started_at+interval '24 hours';
  else due:='infinity'; end if;
  update public.pc_access_pairs set next_maintenance_at=due where parent_id=new.device_id;
  return new;
end $$;

create or replace function public.pc_access_finish_maintenance(p_owner uuid)
returns void language sql security definer set search_path=public,pg_temp as $$
  update public.pc_access_pairs p set next_maintenance_at='infinity'
  from public.pc_access_owners o where p.parent_id=p_owner and o.device_id=p_owner
    and o.purchase_state<>'active' and coalesce(o.paid_access_until<=now(),true)
    and coalesce(o.trial_started_at+interval '24 hours'<=now(),true);
$$;
-- Promptly reconcile previously verified families; do not enrol or reset demos.
update public.pc_access_pairs p set next_maintenance_at=now()
from public.pc_access_owners o where p.parent_id=o.device_id and o.paid_access_until>now();
