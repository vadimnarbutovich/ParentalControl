-- An explicit purchase/restore must not wait for the periodic cache TTL.
-- Its separate cooldown bounds repeated client requests and fences a pre-purchase refresh.
alter table public.pc_access_owners add column last_explicit_refresh timestamptz;
create function public.pc_access_request_purchase_refresh(p_owner uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  update public.pc_access_owners set next_refresh_at=now(),refresh_token=null,refresh_until=null,
    last_explicit_refresh=now()
    where device_id=p_owner and (last_explicit_refresh is null or last_explicit_refresh<=now()-interval '30 seconds');
  return found;
end $$;
revoke all on function public.pc_access_request_purchase_refresh(uuid) from public,anon,authenticated;
grant execute on function public.pc_access_request_purchase_refresh(uuid) to service_role;
