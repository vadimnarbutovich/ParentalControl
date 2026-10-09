-- Tasks are independent from the reward ledger: removing a task never reverses time.
-- Serialize edits with approval (family first, then task) and never resurrect deleted tasks.
create or replace function public.pc_save_child_task(
  p_device uuid, p_task uuid, p_title text, p_details text,
  p_reward_seconds integer, p_create boolean
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare d public.devices; t public.family_child_tasks;
begin
  select * into d from public.devices where id = p_device;
  if d.id is null or d.role <> 'parent' or d.family_id is null then
    raise exception 'Paired parent required';
  end if;
  if p_task is null or p_title is null or length(btrim(p_title)) = 0
     or p_reward_seconds is null or p_reward_seconds < 0 or p_reward_seconds > 7200 then
    raise exception 'Invalid task';
  end if;
  perform 1 from public.families where id = d.family_id for update;
  select * into t from public.family_child_tasks where id = p_task for update;
  if t.id is null then
    if p_create is distinct from true then raise exception 'Task no longer exists'; end if;
    -- Completed rows may already have expired; their reward ID must never be reused.
    if exists(select 1 from public.family_budget_operations where id = p_task) then
      raise exception 'Task already completed';
    end if;
    insert into public.family_child_tasks(id, family_id, title, details, reward_seconds)
      values(p_task, d.family_id, btrim(p_title), coalesce(p_details, ''), p_reward_seconds)
      returning * into t;
  else
    if t.family_id <> d.family_id or t.deleted_at is not null or t.status = 'approved' then
      raise exception 'Task cannot be edited';
    end if;
    update public.family_child_tasks
      set title = btrim(p_title), details = coalesce(p_details, ''),
          reward_seconds = p_reward_seconds, updated_at = now()
      where id = p_task returning * into t;
  end if;
  return to_jsonb(t);
end;
$$;
revoke all on function public.pc_save_child_task(uuid,uuid,text,text,integer,boolean) from public, anon, authenticated;
grant execute on function public.pc_save_child_task(uuid,uuid,text,text,integer,boolean) to service_role;

create index if not exists family_child_tasks_approved_expiry_idx
  on public.family_child_tasks ((coalesce(approved_at, updated_at))) where status = 'approved';

-- Replaces ONLY the existing task cleanup job. Family cleanup is unchanged.
-- The list endpoint and offline UI hide completed tasks at 24h; this job reclaims rows.
-- No foreign keys from statistics or reward operations reference family_child_tasks.
select cron.schedule('pc-clean-child-tasks', '*/15 * * * *', $job$
  delete from public.family_child_tasks
  where (status = 'approved' and coalesce(approved_at, updated_at) <= now() - interval '24 hours')
     or (deleted_at is not null and deleted_at <= now() - interval '7 days');
$job$);
