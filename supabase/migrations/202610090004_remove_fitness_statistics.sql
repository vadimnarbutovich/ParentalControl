-- Deploy the compatible edge function before applying this cleanup.
-- Manual blocking runtime/commands and the minute ledger are NOT fitness statistics.
alter table public.daily_stats_snapshots
  drop column steps,
  drop column push_ups,
  drop column squats,
  drop column focus_session_total_seconds;
