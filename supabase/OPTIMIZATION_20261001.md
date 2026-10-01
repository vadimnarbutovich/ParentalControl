# Conservative sync optimization (2026-10-01)

- Minute cron cadence, URLs, Vault credentials, payloads and timeouts are unchanged.
- Retry cron invokes Edge only if queued/sent/delivered commands exist. Expired pending commands still invoke the existing expiration handler; applied/failed-only or empty queues skip HTTP.
- Schedule cron skips HTTP only if no enabled or currently active schedules exist. Enabled future schedules and disabled/deleted active schedules remain eligible.
- Schedule evaluation excludes only disabled, inactive rows. Date/time, overnight, timezone, command dispatch and acknowledgement logic are unchanged.
- Parent/child polls reuse the device row authenticated during the same request, without any cross-request cache. Invalid credentials and role checks are preserved.
- Added two missing foreign-key indexes. No indexes or data are removed.
- No iOS code, polling intervals, push payloads, response schemas, pairing or balance logic changed.

## Rollback

Run `supabase/rollback/20261001085318_reduce_idle_sync.sql` to restore unconditional cron calls. Keep their current active flags and schedules.
Redeploy the pre-change `parental-control-sync/index.ts` from Git (or the private snapshot in `.migration-backups/20261001-sync-optimization/`), keeping `verify_jwt=false`: authentication is implemented by the function itself.
The additive FK indexes need not be removed.

## Deferred decisions

Adaptive polling, next-transition scheduling, pagination/batching and consolidating multiple reads into a new RPC need separate validation. This patch deliberately does not redesign them.
Family cleanup after 15 days of inactivity is unchanged at the user's explicit request. The 90-day statistics retention is also unchanged.

## Pre-deployment checks

23 isolated comparisons of old/new TypeScript handlers passed using mocked database responses (no network). Covered parent/child poll response parity, one fewer query per successful poll, missing/invalid credentials, wrong role, unpaired devices, cron authorization, and identical schedule transitions for enabled/disabled/deleted/active combinations across UTC, Warsaw, New York and an invalid-zone fallback, including overnight intervals. TypeScript transpilation passed; this is not a full Deno type check or a two-device end-to-end test.
A read-only SQL truth-table check found zero transitions excluded by the new schedule guard. The retry guard retains queued, sent and delivered statuses, including expired rows.

## Deployment and post-deployment checks

Applied migration `20261001085318_reduce_idle_sync` to project `tttwrzgjddalgiwmgmyz`; deployed `parental-control-sync` version 3. Retrieved deployed source matches the local file.
At 08:54 UTC on 2026-10-01 both minute jobs succeeded with `0 rows` (no HTTP dispatch while there was no work). Schedule and active flags of all eight jobs were unchanged. Record counts across all nine public tables were unchanged.
Real HTTP requests for parent polling without credentials, child polling with invalid credentials, and cron evaluation without a token all returned 401. Missing-FK-index advisories were resolved; no new security advisory appeared. Existing password-protection advisory and unused-index informational notices remain outside this change.
No app build, iOS simulator run or real-device end-to-end test was performed.

## Device verification

Using the existing paired devices: refresh parent statistics/balance; start and end focus; change the child's balance; trigger a schedule start/end; disable an active schedule; reconnect the child after temporary loss of connectivity. Confirm that commands are applied and acknowledged and statistics update as before. No new iOS build is required for this server-only change.
