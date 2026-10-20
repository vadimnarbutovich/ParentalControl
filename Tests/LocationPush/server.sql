-- Isolated fixtures only; ROLLBACK removes every row, including on successful tests.
begin;
do $$
declare f uuid:=gen_random_uuid(); other_f uuid:=gen_random_uuid();
  p uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  first_result jsonb; second_result jsonb; command_id uuid; result jsonb; rejected boolean;
begin
  insert into public.families(id,pairing_code) values(f,'LPSE-'||f::text),(other_f,'LPSE-'||other_f::text);
  insert into public.devices(id,family_id,install_id,role,device_secret) values
    (p,f,p::text,'parent','isolated-test'),(c,f,c::text,'child','isolated-test'),
    (outsider,other_f,outsider::text,'child','isolated-test');
  first_result:=public.pc_request_location_push(p);
  assert first_result->'command'->>'error_message'='location_push_not_ready', 'missing token must fail clearly';
  assert (first_result->>'dispatch')::boolean=false, 'no token, no push';
  update public.focus_commands set created_at=now()-interval '31 seconds' where family_id=f;
  update public.devices set location_push_token=repeat('ab',32) where id=c;
  first_result:=public.pc_request_location_push(p);
  command_id:=(first_result->'command'->>'id')::uuid;
  assert (first_result->>'dispatch')::boolean=true, 'first request dispatches';
  second_result:=public.pc_request_location_push(p);
  assert second_result->'command'->>'id'=command_id::text, 'reuse pending request';
  assert (second_result->>'dispatch')::boolean=false, 'duplicate tap must not send APNs';
  rejected:=false;
  begin perform public.pc_request_location_push(c); exception when others then rejected:=true; end;
  assert rejected, 'child cannot request another location';
  result:=jsonb_build_object('latitude',0,'longitude',0,'horizontalAccuracy',10,'capturedAtISO',now());
  rejected:=false;
  begin perform public.pc_finish_location_push(outsider,command_id,result); exception when others then rejected:=true; end;
  assert rejected, 'different family cannot report';
  rejected:=false;
  begin perform public.pc_finish_location_push(c,command_id,result||'{"latitude":999}'::jsonb); exception when others then rejected:=true; end;
  assert rejected, 'invalid coordinates rejected';
  perform public.pc_finish_location_push(c,command_id,result);
  assert (select status='applied' from public.focus_commands where id=command_id), 'ACK persisted';
  assert (select count(*)=1 from public.child_location_state where family_id=f), 'one location row';
  perform public.pc_finish_location_push(c,command_id,result||'{"latitude":50}'::jsonb);
  assert (select latitude=0 from public.child_location_state where family_id=f), 'duplicate report cannot change result';
  update public.focus_commands set status='sent',expires_at=now()-interval '1 second' where id=command_id;
  rejected:=false;
  begin perform public.pc_finish_location_push(c,command_id,result); exception when others then rejected:=true; end;
  assert rejected, 'expired result rejected';
  update public.focus_commands set expires_at=now()+interval '1 minute' where id=command_id;
  update public.devices set family_id=null where id=c;
  rejected:=false;
  begin perform public.pc_finish_location_push(c,command_id,result); exception when others then rejected:=true; end;
  assert rejected, 'unlink invalidates in-flight request';
end $$;
rollback;
