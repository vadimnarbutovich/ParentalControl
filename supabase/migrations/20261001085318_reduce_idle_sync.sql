-- Conservative optimization: preserve minute cadence, timeouts, authentication and payloads.
-- Version matches the migration applied via MCP on 2026-10-01.
-- Apply after the 20260930 bootstrap. No user records are changed.
BEGIN;

DO $check$
BEGIN
  IF (SELECT count(*) FROM cron.job WHERE jobname IN (
    'parental-control-evaluate-block-schedules', 'parental-control-stuck-command-retry'
  )) <> 2 THEN
    RAISE EXCEPTION 'Expected both ParentalControl cron jobs';
  END IF;
END
$check$;

-- Disabled/deleted BUT currently active schedules must still send their end transition.
SELECT cron.alter_job(jobid, command := $pcjob$
select net.http_post(
      url := 'https://tttwrzgjddalgiwmgmyz.supabase.co/functions/v1/parental-control-sync',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-token', (select decrypted_secret from vault.decrypted_secrets where name = 'pc_cron_token')
      ),
      body := jsonb_build_object(
        'action', 'cron_evaluate_block_schedules',
        'payload', jsonb_build_object()
      ),
      timeout_milliseconds := 15000
    ) as request_id
WHERE EXISTS (
  SELECT 1 FROM public.family_block_schedules
  WHERE is_enabled OR is_currently_active
);
$pcjob$)
FROM cron.job WHERE jobname = 'parental-control-evaluate-block-schedules';

-- Include delivered AND expired pending commands so existing expiry/cleanup still runs.
-- Do not filter by retry_count or age here: the existing handler remains authoritative.
SELECT cron.alter_job(jobid, command := $pcjob$
select net.http_post(
    url := 'https://tttwrzgjddalgiwmgmyz.supabase.co/functions/v1/parental-control-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-token', (select decrypted_secret from vault.decrypted_secrets where name = 'pc_cron_token')
    ),
    body := jsonb_build_object(
      'action', 'cron_retry_stuck_commands',
      'payload', jsonb_build_object('maxBatch', 50, 'minAgeSeconds', 10)
    ),
    timeout_milliseconds := 10000
  ) as request_id
WHERE EXISTS (
  SELECT 1 FROM public.focus_commands
  WHERE status IN ('queued', 'sent', 'delivered')
);
$pcjob$)
FROM cron.job WHERE jobname = 'parental-control-stuck-command-retry';

-- Add missing FK indexes without removing any existing indexes.
CREATE INDEX IF NOT EXISTS idx_child_runtime_state_child_device_id
  ON public.child_runtime_state (child_device_id);
CREATE INDEX IF NOT EXISTS idx_family_focus_desired_state_updated_by_device_id
  ON public.family_focus_desired_state (updated_by_device_id);
COMMIT;
