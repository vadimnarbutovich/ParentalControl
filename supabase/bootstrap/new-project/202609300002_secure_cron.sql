-- Fresh destination project only; not an incremental migration for the old project.
-- Create a new per-project cron credential inside Vault (never export its value).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'pc_cron_token') THEN
    PERFORM vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'pc_cron_token', 'ParentalControl scheduled task authentication');
  END IF;
END
$$;
CREATE OR REPLACE FUNCTION public.pc_validate_cron_token(p_token text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT length(p_token) BETWEEN 32 AND 256 AND EXISTS (
    SELECT 1 FROM vault.decrypted_secrets
    WHERE name = 'pc_cron_token'
      AND extensions.digest(p_token, 'sha256') = extensions.digest(decrypted_secret, 'sha256')
  );
$$;
REVOKE ALL ON FUNCTION public.pc_validate_cron_token(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pc_validate_cron_token(text) TO service_role;

-- Disabled until data verification and APNs setup are complete.
SELECT cron.schedule('parental-control-evaluate-block-schedules', '* * * * *', $pcjob$
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
    ) as request_id;
    $pcjob$);
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'parental-control-evaluate-block-schedules';

-- Disabled until data verification and APNs setup are complete.
SELECT cron.schedule('pc-clean-daily-stats', '20 3 * * *', $pcjob$ DELETE FROM daily_stats_snapshots WHERE day_start < (current_date - 90) $pcjob$);
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'pc-clean-daily-stats';

-- Disabled until data verification and APNs setup are complete.
SELECT cron.schedule('pc-clean-cron-logs', '0 */6 * * *', $pcjob$ TRUNCATE cron.job_run_details $pcjob$);
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'pc-clean-cron-logs';

-- Disabled until data verification and APNs setup are complete.
SELECT cron.schedule('pc-clean-net-http-response', '20 */6 * * *', $pcjob$ TRUNCATE net._http_response $pcjob$);
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'pc-clean-net-http-response';

-- Disabled until data verification and APNs setup are complete.
SELECT cron.schedule('pc-clean-focus-commands', '40 */6 * * *', $pcjob$ DELETE FROM focus_commands WHERE status IN ('applied','failed') AND created_at < now() - interval '1 day' $pcjob$);
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'pc-clean-focus-commands';

-- Disabled until data verification and APNs setup are complete.
SELECT cron.schedule('parental-control-stuck-command-retry', '* * * * *', $pcjob$
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
  ) as request_id;
  $pcjob$);
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'parental-control-stuck-command-retry';

-- Disabled until data verification and APNs setup are complete.
SELECT cron.schedule('pc-clean-abandoned-families', '*/30 * * * *', $pcjob$select public.cleanup_abandoned_families();$pcjob$);
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'pc-clean-abandoned-families';

-- Disabled until data verification and APNs setup are complete.
SELECT cron.schedule('pc-clean-child-tasks', '40 3 * * *', $pcjob$ DELETE FROM family_child_tasks WHERE (deleted_at IS NOT NULL AND deleted_at < now() - interval '7 days') OR (status = 'approved' AND approved_at IS NOT NULL AND approved_at < now() - interval '30 days') $pcjob$);
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'pc-clean-child-tasks';
