-- Explicit role choice after reinstall, never an automatic startup cleanup.
-- Only the authenticated device's parent-only setup can be discarded.
create or replace function public.pc_reset_pending_setup(p_device uuid, p_family uuid, p_role text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.devices;
begin
  if p_family is null or p_role is null or p_role not in ('parent','child') then
    raise exception 'Invalid setup request';
  end if;
  -- Same lock order as access preparation: family before device. FOR UPDATE
  -- also conflicts with the FK key-share lock taken by a concurrent child join.
  perform 1 from public.families where id=p_family for update;
  select * into d from public.devices where id=p_device for update;
  if d.id is null then raise exception 'Unknown device'; end if;
  if d.family_id is null then
    -- Successful reset whose HTTP response was lost. Keep the same identity.
    update public.devices set role=p_role where id=p_device;
    return true;
  end if;
  if d.family_id<>p_family or d.role<>'parent' then return false; end if;
  if exists(select 1 from public.devices where family_id=p_family and id<>p_device) then
    return false;
  end if;
  update public.devices set family_id=null,role=p_role where id=p_device;
  delete from public.families where id=p_family;
  -- Family-owned rows cascade. Device, credentials and pc_access_owners survive;
  -- in particular no trial, RevenueCat identity or purchase state is reset.
  return true;
end $$;
revoke all on function public.pc_reset_pending_setup(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.pc_reset_pending_setup(uuid,uuid,text) to service_role;
