-- Manual rollback for 20261001085318_reduce_idle_sync. Does not alter user data.
BEGIN;
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
    ) as request_id;
$pcjob$)
FROM cron.job WHERE jobname = 'parental-control-evaluate-block-schedules';

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
  ) as request_id;
$pcjob$)
FROM cron.job WHERE jobname = 'parental-control-stuck-command-retry';

-- The two additive FK indexes can remain: they do not change application semantics.
COMMIT;
