-- Gross grants/rewards can exceed the net balance after repeated withdrawals.
-- They must not reject otherwise valid budget synchronizations.
alter table public.daily_stats_snapshots
  drop constraint daily_stats_snapshots_reward_seconds_check,
  drop constraint daily_stats_snapshots_granted_seconds_check,
  add constraint daily_stats_snapshots_reward_seconds_check check (reward_seconds >= 0),
  add constraint daily_stats_snapshots_granted_seconds_check check (granted_seconds >= 0);
