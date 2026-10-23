-- Isolated fixture, no changes to real families survive this transaction.
begin;
do $$
declare f uuid:=gen_random_uuid(); p uuid:=gen_random_uuid(); c uuid:=gen_random_uuid();
  claim jsonb; deadline timestamptz; a jsonb;
begin
  insert into public.families(id,pairing_code) values(f,'CONTINUITY-'||f::text);
  insert into public.devices(id,family_id,install_id,role,device_secret) values
    (p,f,p::text,'parent','isolated-test'),(c,f,c::text,'child','isolated-test');
  update public.pc_access_rollout set enabled=true;
  perform public.pc_access_prepare(p,true); perform public.pc_access_prepare(c,true);
  update public.pc_access_owners set trial_started_at=now()-interval '25 hours' where device_id=p;
  assert public.pc_access_snapshot(c)->>'controlUntilMs' is null,'no grace for a nonbuyer';
  claim:=public.pc_access_claim_refresh(p);
  assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'active',now()+interval '7 seconds',false);
  select paid_access_until into deadline from public.pc_access_owners where device_id=p;
  assert deadline=now()+interval '24 hours','fixed paid continuity';
  assert (select next_refresh_at=now()+interval '30 seconds' from public.pc_access_owners where device_id=p),'do not wait five minutes';
  a:=public.pc_access_snapshot(c);
  assert (a->>'controlUntilMs')::bigint-(a->>'issuedAtMs')::bigint=86400000,'old clients accept bounded lease';
  assert (a->>'nextCheckAtMs')::bigint-(a->>'issuedAtMs')::bigint=30000,'client checks renewal early';
  update public.pc_access_owners set purchase_until=now()-interval '1 second' where device_id=p;
  assert public.pc_access_snapshot(c)->>'state'='paid','billing boundary does not revoke';
  update public.pc_access_owners set next_refresh_at=now() where device_id=p;
  claim:=public.pc_access_claim_refresh(p);
  assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'inactive',null,false);
  assert (select paid_access_until is null from public.pc_access_owners where device_id=p),'negative response clears grace';
  assert public.pc_access_snapshot(c)->>'state'='expired','negative response revokes immediately';
  perform public.pc_access_finish_maintenance(p);
  assert (select next_maintenance_at='infinity'::timestamptz from public.pc_access_pairs where family_id=f),'confirmed expiration stops maintenance';
  update public.pc_access_owners set next_refresh_at=now() where device_id=p;
  claim:=public.pc_access_claim_refresh(p);
  assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'unknown',null,false);
  assert (select paid_access_until is null from public.pc_access_owners where device_id=p),'outage cannot revive expired access';
  perform public.pc_access_release(p,true);
  assert public.pc_access_snapshot(c)->>'controlUntilMs' is null,'explicit release wins over grace';
  perform public.pc_access_release(p,false);
  assert public.pc_access_snapshot(c)->>'state'='expired','resume cannot revive confirmed expiration';
  update public.pc_access_owners set paid_access_until=now(),revision=revision+1 where device_id=p;
  assert public.pc_access_snapshot(c)->>'controlUntilMs' is null,'grace ends exactly, never indefinite';
  perform public.pc_access_finish_maintenance(p);
  assert (select next_maintenance_at='infinity'::timestamptz from public.pc_access_pairs where family_id=f),'expired negative stops background maintenance';
  update public.pc_access_owners set next_refresh_at=now() where device_id=p;
  claim:=public.pc_access_claim_refresh(p);
  assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'active',now()+interval '3 minutes',false);
  assert public.pc_access_snapshot(c)->>'state'='paid','verified renewal restores access';
  update public.pc_access_owners set verified_at=now()-interval '7 days',paid_access_until=now()-interval '6 days',
    purchase_until=now()-interval '7 days',next_refresh_at=now() where device_id=p;
  claim:=public.pc_access_claim_refresh(p);
  assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'unknown',null,false);
  assert public.pc_access_snapshot(c)->>'state'='paid','outage preserves last known paid state even beyond 24h';
  assert (select verified_at=now()-interval '7 days' from public.pc_access_owners where device_id=p),'outage is not fresh verification';
  update public.pc_access_owners set next_refresh_at=now() where device_id=p;
  claim:=public.pc_access_claim_refresh(p);
  assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'inactive',null,false);
  assert public.pc_access_snapshot(c)->>'state'='expired','online canonical negative ends offline access';
  assert not public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'active',now()+interval '3 minutes',false),'late completed claim cannot revive access';
end $$;
rollback;
