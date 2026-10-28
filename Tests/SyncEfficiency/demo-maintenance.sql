-- No real family's trial, subscription, queue or maintenance schedule is changed.
do $test$
declare f uuid:=gen_random_uuid(); p uuid:=gen_random_uuid(); c uuid:=gen_random_uuid();
  deadline timestamptz; scheduled timestamptz; row_version text; claim jsonb; access_before jsonb;
  completed boolean:=false;
begin
  begin
    insert into public.families(id,pairing_code) values(f,'DEMO-'||f::text);
    insert into public.devices(id,family_id,install_id,role,device_secret) values
      (p,f,p::text,'parent','isolated-maintenance-test'),(c,f,c::text,'child','isolated-maintenance-test');
    insert into public.pc_access_pilots(family_id,parent_id,child_id) values(f,p,c);
    perform public.pc_access_prepare(p,true); perform public.pc_access_prepare(c,true);
    update public.pc_access_owners set trial_started_at=now()-interval '23 hours' where device_id=p;
    select trial_started_at+interval '24 hours' into deadline from public.pc_access_owners where device_id=p;
    -- Mimic retained-device re-pairing followed by a claimed 15-minute retry.
    update public.pc_access_pairs set next_maintenance_at=now()+interval '15 minutes' where family_id=f;
    access_before:=public.pc_access_snapshot(c);
    perform public.pc_access_finish_maintenance(p);
    assert (select next_maintenance_at=deadline from public.pc_access_pairs where family_id=f), 'demo parked at exact original expiry';
    assert public.pc_access_snapshot(c)=access_before, 'planning must not alter access, revision or trial';
    assert not public.pc_access_maintenance_due(f), 'no empty demo wake now';
    select ctid::text into row_version from public.pc_access_pairs where family_id=f;
    perform public.pc_access_finish_maintenance(p);
    assert (select ctid::text=row_version from public.pc_access_pairs where family_id=f), 'same due time is not rewritten';

    -- Unknown result for a never-paid demo follows its deadline, not retry slots.
    claim:=public.pc_access_claim_refresh(p);
    assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'unknown',null,false);
    perform public.pc_access_finish_maintenance(p);
    assert (select next_maintenance_at=deadline from public.pc_access_pairs where family_id=f);
    update public.pc_access_owners set trial_started_at=now()-interval '25 hours' where device_id=p;
    update public.pc_access_pairs set next_maintenance_at=now() where family_id=f;
    assert public.pc_access_maintenance_due(f), 'expiry wake preserved before finish';
    perform public.pc_access_finish_maintenance(p);
    assert (select next_maintenance_at='infinity'::timestamptz from public.pc_access_pairs where family_id=f), 'after expiry notification stop idle work';

    -- A new verified purchase reschedules even a parked pair.
    update public.pc_access_owners set next_refresh_at=now() where device_id=p;
    claim:=public.pc_access_claim_refresh(p);
    assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'active',now()+interval '3 minutes',false);
    select next_maintenance_at into scheduled from public.pc_access_pairs where family_id=f;
    assert scheduled=now()+interval '2 minutes', 'Sandbox renewal cadence preserved';
    perform public.pc_access_finish_maintenance(p);
    assert (select next_maintenance_at=scheduled from public.pc_access_pairs where family_id=f), 'paid schedule untouched';
    update public.pc_access_pairs set next_maintenance_at=now()+interval '15 minutes' where family_id=f;
    update public.pc_access_owners set next_refresh_at=now() where device_id=p;
    claim:=public.pc_access_claim_refresh(p);
    assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'unknown',null,false);
    perform public.pc_access_finish_maintenance(p);
    assert (select next_maintenance_at=now()+interval '15 minutes' from public.pc_access_pairs where family_id=f), 'uncertain previously-paid verification keeps retry';
    assert public.pc_access_snapshot(c)->>'state'='paid', 'unknown never revokes paid access';
    -- now() is fixed throughout this fixture transaction; simulate a later
    -- verification timestamp so the existing owner-change trigger fires.
    update public.pc_access_owners set next_refresh_at=now(),verified_at=now()-interval '1 second' where device_id=p;
    claim:=public.pc_access_claim_refresh(p);
    assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'active',null,true);
    perform public.pc_access_finish_maintenance(p);
    assert (select next_maintenance_at=now()+interval '12 hours' from public.pc_access_pairs where family_id=f), 'lifetime verification retained';
    update public.pc_access_owners set next_refresh_at=now() where device_id=p;
    claim:=public.pc_access_claim_refresh(p);
    assert public.pc_access_finish_refresh(p,(claim->>'token')::uuid,'inactive',null,false);
    perform public.pc_access_finish_maintenance(p);
    assert (select next_maintenance_at='infinity'::timestamptz from public.pc_access_pairs where family_id=f);
    assert public.pc_access_snapshot(c)->>'state'='expired', 'confirmed negative still expires access';
    assert not has_function_privilege('anon','public.pc_access_finish_maintenance(uuid)','execute');
    assert not has_function_privilege('authenticated','public.pc_access_finish_maintenance(uuid)','execute');
    perform public.pc_access_finish_maintenance(gen_random_uuid());
    raise sqlstate 'PTEST' using message='fixture checks complete';
  exception when sqlstate 'PTEST' then completed:=true;
  end;
  assert completed;
  assert not exists(select 1 from public.families where id=f), 'fixture rolled back';
end $test$;
