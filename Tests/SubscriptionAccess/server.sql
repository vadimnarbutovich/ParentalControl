-- Isolated fixtures; always rolled back, including the rollout switch.
begin;
do $$
declare f uuid:=gen_random_uuid(); p uuid:=gen_random_uuid(); c uuid:=gen_random_uuid();
  a jsonb; claim jsonb; event_claim jsonb; t timestamptz; customer text; accepted boolean;
begin
  insert into public.families(id,pairing_code) values(f,'ACCESS-'||f::text);
  insert into public.devices(id,family_id,install_id,role,device_secret) values
    (p,f,p::text,'parent','isolated-test'),(c,f,c::text,'child','isolated-test');
  update public.pc_access_rollout set enabled=false;
  perform public.pc_access_prepare(p,true);
  perform public.pc_access_prepare(c,true);
  assert not (public.pc_access_snapshot(c)->>'enforced')::boolean, 'rollout off';
  assert not exists(select 1 from jsonb_array_elements(public.pc_access_claim_maintenance()) e
    where e->>'family_id'=f::text), 'fixture has no background work before rollout';
  assert (select trial_started_at is null from public.pc_access_owners where device_id=p), 'no premature trial';
  update public.pc_access_rollout set enabled=true;
  perform public.pc_access_prepare(c,true);
  a:=public.pc_access_snapshot(c);
  assert a->>'state'='demo', 'ready pair starts demo';
  assert (a->>'controlUntilMs')::bigint-(a->>'issuedAtMs')::bigint=86400000, '24 hour trial';
  select trial_started_at,customer_id into t,customer from public.pc_access_owners where device_id=p;
  perform public.pc_access_prepare(c,true);
  assert (select trial_started_at=t from public.pc_access_owners where device_id=p), 'trial never restarts';
  update public.pc_access_owners set trial_started_at=now()-interval '25 hours' where device_id=p;
  assert public.pc_access_snapshot(c)->>'controlUntilMs' is null, 'expired demo has no lease';
  claim:=public.pc_access_claim_refresh(p);
  assert public.pc_access_claim_refresh(p) is null, 'single flight';
  accepted:=public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'active',now()+interval '30 days',false);
  assert accepted, 'verified purchase stored';
  a:=public.pc_access_snapshot(c);
  assert a->>'state'='paid', 'verified paid access';
  assert (select next_maintenance_at<=now()+interval '12 hours' from public.pc_access_pairs where family_id=f), 'paid lease scheduled for background renewal';
  update public.pc_access_pairs set next_maintenance_at=now() where family_id=f;
  assert exists(select 1 from jsonb_array_elements(public.pc_access_claim_maintenance()) e
    where e->>'family_id'=f::text), 'claim due paid family';
  assert not exists(select 1 from jsonb_array_elements(public.pc_access_claim_maintenance()) e
    where e->>'family_id'=f::text), 'background claim is single flight';
  assert (a->>'controlUntilMs')::bigint-(a->>'issuedAtMs')::bigint=86400000, 'bounded offline lease';
  assert public.pc_access_request_purchase_refresh(p), 'purchase bypasses periodic TTL';
  assert not public.pc_access_request_purchase_refresh(p), 'purchase refresh has separate cooldown';
  assert public.pc_access_claim_refresh(p) is not null, 'explicit refresh can start now';
  update public.pc_access_owners set refresh_until=null,refresh_token=null where device_id=p;
  perform public.pc_access_release(p,true);
  assert public.pc_access_snapshot(c)->>'controlUntilMs' is null, 'safe release';
  perform public.pc_access_release(p,false);
  assert public.pc_access_snapshot(c)->>'state'='paid', 'resume only if entitlement valid';
  update public.pc_access_owners set next_refresh_at=now() where device_id=p;
  claim:=public.pc_access_claim_refresh(p);
  event_claim:=public.pc_access_claim_event('fixture-'||f::text,array[customer]);
  accepted:=public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'inactive',null,false);
  assert not accepted, 'webhook fences stale verifier';
  assert (public.pc_access_claim_event('fixture-'||f::text,array[customer])->>'busy')::boolean, 'event single flight';
  claim:=public.pc_access_claim_refresh(p);
  perform public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'unknown',null,false);
  assert public.pc_access_snapshot(c)->>'state'='paid', 'network error preserves verified lease';
  perform public.pc_access_complete_event('fixture-'||f::text,(event_claim->>'token')::uuid,true);
  assert (public.pc_access_claim_event('fixture-'||f::text,array[customer])->>'done')::boolean, 'event deduplication';
  assert not has_table_privilege('anon','public.pc_access_owners','SELECT'), 'no anonymous access';
  assert not has_function_privilege('authenticated','public.pc_access_prepare(uuid,boolean)','EXECUTE'), 'no client writes';
end $$;
rollback;
