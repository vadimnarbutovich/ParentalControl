-- Reuse the existing authenticated schedule cron; do not add per-family polling jobs.
alter table public.pc_access_pairs add column next_maintenance_at timestamptz not null default now();
create function public.pc_access_schedule_maintenance()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare due timestamptz;
begin
  if new.purchase_state='active' and new.verified_at is not null then
    due:=greatest(now()+interval '1 minute',least(new.verified_at+interval '12 hours',
      case when new.lifetime then 'infinity'::timestamptz else new.purchase_until-interval '5 minutes' end));
  elsif new.trial_started_at+interval '24 hours'>now() then
    due:=new.trial_started_at+interval '24 hours';
  else due:='infinity'; end if;
  update public.pc_access_pairs set next_maintenance_at=due where parent_id=new.device_id;
  return new;
end $$;
create trigger pc_access_schedule_maintenance after update of trial_started_at,purchase_state,verified_at on public.pc_access_owners
for each row when (old.trial_started_at is distinct from new.trial_started_at or old.purchase_state is distinct from new.purchase_state or old.verified_at is distinct from new.verified_at)
execute function public.pc_access_schedule_maintenance();

create function public.pc_access_claim_maintenance()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare pair public.pc_access_pairs; result jsonb:='[]';
begin
  if not (select enabled from public.pc_access_rollout where singleton) then return result; end if;
  for pair in select * from public.pc_access_pairs where activated_at is not null and not released
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
create function public.pc_access_finish_maintenance(p_owner uuid)
returns void language sql security definer set search_path=public,pg_temp as $$
  update public.pc_access_pairs p set next_maintenance_at='infinity'
  from public.pc_access_owners o where p.parent_id=p_owner and o.device_id=p_owner
    and o.purchase_state<>'active' and coalesce(o.trial_started_at+interval '24 hours'<=now(),true);
$$;
revoke all on function public.pc_access_schedule_maintenance(),public.pc_access_claim_maintenance(),public.pc_access_finish_maintenance(uuid) from public,anon,authenticated;
grant execute on function public.pc_access_claim_maintenance(),public.pc_access_finish_maintenance(uuid) to service_role;
