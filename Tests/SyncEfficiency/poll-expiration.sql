-- Execute with the migration: fixture subtransaction rolls back on success too.
do $test$
declare f uuid:=gen_random_uuid(); other_f uuid:=gen_random_uuid();
  p uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); other_c uuid:=gen_random_uuid();
  ids uuid[]:=array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
  snapshot jsonb; row_version text; denied boolean; completed boolean:=false;
begin
  begin
    insert into public.families(id,pairing_code) values(f,'POLL-'||f::text),(other_f,'POLL-'||other_f::text);
    insert into public.devices(id,family_id,install_id,role,device_secret) values
      (p,f,p::text,'parent','isolated-poll-test'),(c,f,c::text,'child','isolated-poll-test'),
      (other_c,other_f,other_c::text,'child','isolated-poll-test');
    insert into public.focus_commands(id,family_id,requested_by_device_id,target_device_id,command_type,status,expires_at,retry_count) values
      (ids[1],f,p,c,'start_focus','queued',now()-interval '1 minute',2),
      (ids[2],f,p,c,'end_focus','sent',now()-interval '1 minute',3),
      (ids[3],f,p,c,'tasks_updated','delivered',now()-interval '1 minute',1),
      (ids[4],f,p,c,'tasks_updated','queued',now()+interval '10 minutes',0),
      (ids[5],f,p,c,'start_focus','applied',now()-interval '1 minute',0),
      (ids[6],other_f,p,other_c,'tasks_updated','queued',now()-interval '1 minute',0);
    -- Invalid identity/role must never mutate any queue.
    denied:=false;
    begin perform public.pc_poll_snapshot(p,'child');
    exception when raise_exception then denied:=true; end;
    assert denied, 'role mismatch rejected';
    assert (select status='queued' from public.focus_commands where id=ids[1]), 'invalid role did not expire commands';
    denied:=false;
    begin perform public.pc_poll_snapshot(gen_random_uuid(),'parent');
    exception when raise_exception then denied:=true; end;
    assert denied, 'unknown device rejected';

    snapshot:=public.pc_poll_snapshot(p,'parent');
    assert (select count(*)=3 from public.focus_commands where id=any(ids[1:3]) and status='failed' and error_message='expired_ttl'), 'all pending statuses expire';
    assert (snapshot->>'recentFailures')::int=3, 'same response includes expired failures';
    assert jsonb_array_length(snapshot->'pendingRows')=1, 'only live commands returned';
    assert snapshot->'pendingRows'->0->>'id'=ids[4]::text, 'live command remains';
    assert (select retry_count=2 and applied_at is null from public.focus_commands where id=ids[1]), 'retry and ack fields unchanged';
    assert (select status='applied' from public.focus_commands where id=ids[5]), 'terminal command preserved';
    assert (select status='queued' from public.focus_commands where id=ids[6]), 'other family untouched';
    select ctid::text into row_version from public.focus_commands where id=ids[1];
    snapshot:=public.pc_poll_snapshot(c,'child',true);
    assert (select ctid::text=row_version from public.focus_commands where id=ids[1]), 'next poll does not rewrite expired row';
    assert jsonb_array_length(snapshot->'pendingRows')=1, 'child still receives live command';
    assert snapshot->'fam' is not null, 'parent settings remain available';
    assert snapshot ?& array['desiredRow','runtimeRow','statsRow','pendingRows','fam','recentFailures','nowISO','budget'], 'wire keys retained';
    update public.focus_commands set expires_at=now()-interval '1 second' where id=ids[4];
    snapshot:=public.pc_poll_snapshot(c,'child',false);
    assert jsonb_array_length(snapshot->'pendingRows')=0, 'child poll also expires commands';
    assert snapshot->'fam'='null'::jsonb, 'optional settings omitted';
    assert not has_function_privilege('anon','public.pc_poll_snapshot(uuid,text,boolean)','execute');
    assert not has_function_privilege('authenticated','public.pc_poll_snapshot(uuid,text,boolean)','execute');
    assert has_function_privilege('service_role','public.pc_poll_snapshot(uuid,text,boolean)','execute');
    assert (select provolatile='v' from pg_proc where oid='public.pc_poll_snapshot(uuid,text,boolean)'::regprocedure), 'write-enabled function volatility';
    raise sqlstate 'PTEST' using message='fixture checks complete';
  exception when sqlstate 'PTEST' then completed:=true;
  end;
  assert completed;
  assert not exists(select 1 from public.families where id in (f,other_f)), 'fixture rolled back';
end $test$;
