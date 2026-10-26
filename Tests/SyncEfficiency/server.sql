-- Safe to run as part of the migration transaction. All fixture changes live
-- in an exception subtransaction and are rolled back even when checks pass.
do $test$
declare f uuid:=gen_random_uuid(); p uuid:=gen_random_uuid(); c uuid:=gen_random_uuid();
  sid uuid:=gen_random_uuid(); version_before text; completed boolean:=false;
begin
  begin
    insert into public.families(id,pairing_code) values(f,'EFF-'||f::text);
    insert into public.devices(id,family_id,install_id,role,device_secret) values
      (p,f,p::text,'parent','isolated-efficiency-test'),(c,f,c::text,'child','isolated-efficiency-test');
    insert into public.pc_access_owners(device_id,enrolled,purchase_state,verified_at,trial_started_at)
      values(p,true,'inactive',now(),now()-interval '25 hours');
    insert into public.pc_access_pairs(family_id,parent_id,child_id,parent_ready,child_ready,activated_at,next_maintenance_at)
      values(f,p,c,true,true,now(), 'infinity');
    insert into public.family_block_schedules(id,family_id,name,start_hour,start_minute,end_hour,end_minute,
      weekdays,is_enabled,is_currently_active,timezone_identifier)
      values(sid,f,'isolated fixture',0,0,0,0,array[1,2,3,4,5,6,7],true,false,'UTC');
    assert public.pc_schedule_needs_evaluation((select s from public.family_block_schedules s where id=sid),now()), 'transition fixture';
    assert not public.pc_schedule_work_due(f), 'expired family must not spin on schedule';
    assert not public.pc_access_maintenance_due(f), 'expired maintenance is parked';

    update public.pc_access_owners set purchase_state='active',purchase_until=now()+interval '30 days',verified_at=now() where device_id=p;
    assert public.pc_schedule_work_due(f), 'paid schedule still evaluated';
    update public.family_block_schedules set is_currently_active=true where id=sid;
    assert not public.pc_schedule_work_due(f), 'unchanged paid schedule does not invoke Edge';
    update public.family_block_schedules set timezone_identifier='Unknown/TestZone' where id=sid;
    assert public.pc_schedule_work_due(f), 'unknown timezone retains conservative fallback for paid family';
    update public.family_block_schedules set timezone_identifier='UTC' where id=sid;
    update public.family_block_schedules set is_enabled=false where id=sid;
    assert public.pc_schedule_work_due(f), 'disabled active schedule still gets its end transition';
    update public.family_block_schedules set deleted_at=now() where id=sid;
    assert public.pc_schedule_work_due(f), 'deleted active schedule still gets its end transition';
    update public.family_block_schedules set is_currently_active=false where id=sid;
    update public.pc_access_pairs set next_maintenance_at=now()-interval '1 second' where family_id=f;
    assert public.pc_access_maintenance_due(f), 'renewal verification runs without schedule transitions';
    update public.pc_access_pairs set released=true where family_id=f;
    assert not public.pc_access_maintenance_due(f), 'released control has no background maintenance';
    update public.pc_access_pairs set released=false where family_id=f;
    update public.pc_access_owners set lifetime=true where device_id=p;
    assert public.pc_access_maintenance_due(f), 'lifetime verification is preserved';
    update public.pc_access_owners set purchase_state='inactive',verified_at=now(),trial_started_at=now()-interval '23 hours' where device_id=p;
    update public.family_block_schedules set is_enabled=true,deleted_at=null where id=sid;
    assert public.pc_schedule_work_due(f), 'demo schedule still works';
    update public.pc_access_owners set trial_started_at=now()-interval '25 hours' where device_id=p;
    update public.pc_access_pairs set next_maintenance_at=now()-interval '1 second' where family_id=f;
    assert public.pc_access_maintenance_due(f), 'demo expiry maintenance is not lost';
    assert not public.pc_schedule_work_due(f), 'expired demo schedule is gated';
    update public.devices set family_id=null where id=c;
    assert not public.pc_access_maintenance_due(f), 'obsolete pair cannot spin maintenance';

    perform public.pc_register_apns_token(p,'aabb','sandbox');
    select ctid::text into version_before from public.devices where id=p;
    perform public.pc_register_apns_token(p,'aabb',null);
    perform public.pc_register_apns_token(p,'aabb','sandbox');
    assert (select ctid::text=version_before from public.devices where id=p), 'identical token does not write a new row';
    perform public.pc_register_apns_token(p,'aabb','production');
    assert (select apns_environment='production' from public.devices where id=p), 'same token may change environment';
    perform public.pc_register_apns_token(p,'ccdd',null);
    assert (select apns_token='ccdd' and apns_environment is null from public.devices where id=p), 'unknown new token resets old environment';
    assert not has_function_privilege('anon','public.pc_access_maintenance_due(uuid)','execute'), 'no anonymous maintenance access';
    assert not has_function_privilege('authenticated','public.pc_schedule_work_due(uuid)','execute'), 'no client schedule predicate access';
    assert exists(select 1 from cron.job where jobname='parental-control-evaluate-block-schedules'
      and schedule='* * * * *' and active
      and command like '%pc_access_maintenance_due() or public.pc_schedule_work_due()%'), 'minute cadence and both independent triggers retained';
    raise sqlstate 'PTEST' using message='fixture checks complete';
  exception when sqlstate 'PTEST' then completed:=true;
  end;
  assert completed, 'tests must complete';
  assert not exists(select 1 from public.families where id=f), 'fixtures rolled back';
end $test$;
