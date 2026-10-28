-- Synthetic fixtures only. Never reference a real family/device; always rollback.
begin;
do $$
declare p uuid:=gen_random_uuid(); c uuid:=gen_random_uuid();
  f uuid:=gen_random_uuid(); linked uuid:=gen_random_uuid(); other uuid:=gen_random_uuid();
  owner_before jsonb; credentials_before text;
begin
  insert into public.families(id,pairing_code) values
    (f,'SETUP-'||f::text),(linked,'SETUP-'||linked::text),(other,'SETUP-'||other::text);
  insert into public.devices(id,install_id,device_secret,role,family_id) values
    (p,p::text,'pending-setup-fixture-secret','parent',f),
    (c,c::text,'pending-setup-child-fixture','child',null);
  insert into public.pc_access_owners(device_id,trial_started_at,purchase_state,lifetime)
    values(p,now()-interval '2 days','active',true);
  select to_jsonb(o) into owner_before from public.pc_access_owners o where device_id=p;
  select device_secret into credentials_before from public.devices where id=p;

  assert not public.pc_reset_pending_setup(p,other,'child'), 'wrong family refused';
  assert exists(select 1 from public.families where id=other), 'other family untouched';
  update public.devices set family_id=f where id=c;
  assert not public.pc_reset_pending_setup(p,f,'child'), 'child joining prevents reset';
  assert not public.pc_reset_pending_setup(c,f,'parent'), 'child cannot discard family';
  assert (select count(*)=2 from public.devices where family_id=f), 'linked phones retained';

  update public.devices set family_id=null where id=c;
  assert public.pc_reset_pending_setup(p,f,'child'), 'explicit pending reset succeeds';
  assert not exists(select 1 from public.families where id=f), 'pending family removed';
  assert (select family_id is null and role='child' and device_secret=credentials_before
    from public.devices where id=p), 'same device credentials, chosen role';
  assert (select to_jsonb(o)=owner_before from public.pc_access_owners o where device_id=p),
    'purchase, demo, customer ID and all owner state preserved';
  assert public.pc_reset_pending_setup(p,f,'child'), 'lost success response retry is safe';
  update public.devices set family_id=linked where id=p;
  assert not public.pc_reset_pending_setup(p,f,'parent'), 'late retry cannot reset new family';
  assert (select family_id=linked and role='child' from public.devices where id=p), 'new link untouched';

  assert not has_function_privilege('anon','public.pc_reset_pending_setup(uuid,uuid,text)','execute');
  assert not has_function_privilege('authenticated','public.pc_reset_pending_setup(uuid,uuid,text)','execute');
  assert has_function_privilege('service_role','public.pc_reset_pending_setup(uuid,uuid,text)','execute');
end $$;
rollback;
