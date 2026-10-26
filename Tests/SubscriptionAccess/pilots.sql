-- Isolated fixtures. Every change, including the global flag, is rolled back.
begin;
do $$
declare f uuid:=gen_random_uuid(); other_f uuid:=gen_random_uuid();
  p uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); replacement uuid:=gen_random_uuid();
  other_p uuid:=gen_random_uuid(); other_c uuid:=gen_random_uuid(); a jsonb; claims jsonb;
begin
  insert into public.families(id,pairing_code) values
    (f,'PILOT-'||f::text),(other_f,'PILOT-'||other_f::text);
  insert into public.devices(id,family_id,install_id,role,device_secret) values
    (p,f,p::text,'parent','isolated-test'),(c,f,c::text,'child','isolated-test'),
    (other_p,other_f,other_p::text,'parent','isolated-test'),
    (other_c,other_f,other_c::text,'child','isolated-test');
  update public.pc_access_rollout set enabled=false;
  perform public.pc_access_prepare(p,true);
  perform public.pc_access_prepare(c,false);
  perform public.pc_access_prepare(other_p,true);
  perform public.pc_access_prepare(other_c,true);
  assert not (public.pc_access_snapshot(c)->>'enforced')::boolean, 'off before allowlist';
  insert into public.pc_access_pilots(family_id,parent_id,child_id) values(f,p,c);
  assert public.pc_access_rollout_enabled(f,p,c), 'exact pair eligible';
  assert public.pc_access_rollout_enabled(other_f,p,c), 'enrollment follows parent';
  assert not public.pc_access_rollout_enabled(f,other_p,c), 'parent identity matters';
  assert public.pc_access_rollout_enabled(f,p,other_c), 'replacement child cannot reopen access';
  perform public.pc_access_prepare(p,true);
  assert (public.pc_access_snapshot(c)->>'enforced')::boolean, 'unready pilot is enforced';
  assert public.pc_access_snapshot(c)->>'state'='setup', 'unready pilot only permits setup';
  assert public.pc_access_snapshot(c)->>'controlUntilMs' is null, 'setup never grants blocking lease';
  assert (select trial_started_at is null from public.pc_access_owners where device_id=p), 'no early demo';
  perform public.pc_access_prepare(c,true);
  a:=public.pc_access_snapshot(c);
  assert a->>'state'='demo' and (a->>'enforced')::boolean, 'pilot activates without global switch';
  assert (public.pc_access_snapshot(p)->>'enforced')::boolean, 'both pilot devices covered';
  assert (a->>'controlUntilMs')::bigint-(a->>'issuedAtMs')::bigint=86400000, 'normal pilot demo is 24h';
  assert not (public.pc_access_snapshot(other_c)->>'enforced')::boolean, 'other ready family unaffected';
  assert (select trial_started_at is null from public.pc_access_owners where device_id=other_p), 'other demo not started';

  -- Test shortening uses existing server-owned trial data, not a client override.
  update public.pc_access_owners set trial_started_at=now()-interval '23 hours 30 minutes',revision=revision+1 where device_id=p;
  a:=public.pc_access_snapshot(c);
  assert (a->>'controlUntilMs')::bigint-(a->>'issuedAtMs')::bigint=1800000, 'test lease has finite 30min expiry';
  assert (select next_maintenance_at=now()+interval '30 minutes' from public.pc_access_pairs where family_id=f), 'maintenance follows test expiry';
  -- Even an activated but non-allowlisted pair must not enter maintenance.
  update public.pc_access_pairs set activated_at=now(),next_maintenance_at=now() where family_id in (f,other_f);
  claims:=public.pc_access_claim_maintenance();
  assert exists(select 1 from jsonb_array_elements(claims) e where e->>'family_id'=f::text), 'pilot receives maintenance';
  assert not exists(select 1 from jsonb_array_elements(claims) e where e->>'family_id'=other_f::text), 'unlisted family excluded from maintenance';
  assert not exists(select 1 from jsonb_array_elements(public.pc_access_claim_maintenance()) e where e->>'family_id'=f::text), 'maintenance single flight';

  update public.pc_access_owners set trial_started_at=now()-interval '25 hours',revision=revision+1 where device_id=p;
  assert public.pc_access_snapshot(c)->>'controlUntilMs' is null, 'pilot expires normally';
  perform public.pc_access_prepare(p,false);
  perform public.pc_access_prepare(c,false);
  assert public.pc_access_snapshot(c)->>'state'<>'setup', 'replaying onboarding cannot reopen setup exceptions';
  assert not (f=any(public.pc_access_allowed_families(array[f,other_f]))), 'expired pilot commands rejected';
  assert other_f=any(public.pc_access_allowed_families(array[f,other_f])), 'legacy family commands unaffected';
  perform public.pc_access_release(p,true);
  assert (public.pc_access_snapshot(c)->>'released')::boolean, 'safe release still available';

  update public.devices set family_id=null where id=c;
  insert into public.devices(id,family_id,install_id,role,device_secret) values
    (replacement,f,replacement::text,'child','isolated-test');
  perform public.pc_access_prepare(replacement,true);
  perform public.pc_access_prepare(p,true);
  assert (public.pc_access_snapshot(replacement)->>'enforced')::boolean, 'replacement inherits restrictions';
  assert public.pc_access_rollout_enabled(f,p,replacement), 'owner stays enrolled after replacement';
  assert public.pc_access_snapshot(replacement)->>'controlUntilMs' is null, 'replacement cannot restart demo';
  update public.pc_access_rollout set enabled=true;
  perform public.pc_access_prepare(replacement,true);
  assert (public.pc_access_snapshot(replacement)->>'enforced')::boolean, 'eventual global rollout still works';
  assert public.pc_access_snapshot(replacement)->>'controlUntilMs' is null, 're-pair does not reset demo';
  -- Actual unlink shape: device rows survive, family/pilot/pair are deleted.
  update public.devices set family_id=null where family_id=f;
  delete from public.families where id=f;
  f:=gen_random_uuid();
  insert into public.families(id,pairing_code) values(f,'REP-'||f::text);
  update public.devices set family_id=f where id in (p,replacement);
  update public.pc_access_rollout set enabled=false;
  assert public.pc_access_snapshot(p)->>'state'='setup', 'new family starts restricted even before prepare';
  perform public.pc_access_prepare(p,true);
  perform public.pc_access_prepare(replacement,true);
  assert (public.pc_access_snapshot(p)->>'enforced')::boolean, 'deleting pilot family cannot escape enrollment';
  assert public.pc_access_snapshot(p)->>'controlUntilMs' is null, 'deleted family cannot renew demo';
  assert not has_table_privilege('anon','public.pc_access_pilots','SELECT'), 'no anonymous pilot data';
  assert not has_table_privilege('authenticated','public.pc_access_pilots','INSERT'), 'no client activation';
  assert not has_function_privilege('authenticated','public.pc_access_rollout_enabled(uuid,uuid,uuid)','EXECUTE'), 'no direct client helper access';
end $$;
rollback;
