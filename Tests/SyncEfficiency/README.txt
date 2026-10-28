Sync efficiency, 2026-10-24

Server follow-up, 2026-10-27 (no new iOS build required)
- pc_poll_snapshot now expires only its authenticated device's family queue
  before reading the snapshot, in one transaction. Volatility is now VOLATILE.
  Parent/child poll handlers no longer issue a separate REST expiration PATCH.
  Same TTL, statuses, error code, response fields, ordering and result limits.
  Legacy command/retry/link-health cleanup remains in place.
- Five read-only handlers reuse the device already authenticated in this HTTP
  request: desired state, command status, child location, schedules and tasks.
  Role/family/command-owner checks remain. No cross-request identity cache.
  Registration, pairing, unlink, mutations and runtime uploads keep rechecks.
- After a normal maintenance wake, non-paid demos are scheduled at the original
  trial_started_at + 24 hours, not another 15-minute retry. Confirmed-expired
  nonbuyers still park at infinity. No real trial start/deadline was edited.
  Finish locks owner before pair (same order as purchase update trigger), so a
  concurrent purchase either wins first or reschedules after the finish.
- No push-suppression heuristic was added. Every actual maintenance execution
  still refreshes and notifies the child before finishing. This retains paid
  renewals, uncertain previously-paid checks, expiry delivery and retry behavior.
  Redundant demo wakes disappear through scheduling, not dropped notifications.
- Cron frequency, payment verifier/webhooks, receipt schema, APNs retries,
  command ACKs, local Screen Time handling and all logging settings unchanged.

Deployment and verification
- Applied poll_expiration_in_snapshot and demo_maintenance_deadline migrations.
  Both were guarded by isolated SQL fixture assertions within the migration
  transaction; fixtures roll back on success and failure. No fixture rows remain.
- parental-control-sync v27 is ACTIVE; deployed source matches local files.
  Existing custom authentication and verify_jwt=false preserved. Shared verifier,
  webhook and APNs routing files byte-identical to v26; balance function unchanged.
- 9 new read/authorization/compatibility tests and 70 existing Node tests passed.
  Deno checks passed for both Edge entry points; sync integration guards passed.
- Live SQL checks passed: poll-expiration.sql, demo-maintenance.sql, server.sql
  and SubscriptionAccess/continuity.sql (rolled back). Includes role mismatch,
  family isolation, terminal/live commands, no-op updates, demo, renewal,
  unknown-paid state, lifetime, confirmed negative and service-only privileges.
- At 07:43 UTC: still 1 family / 2 devices, 0 fixture families, 0 stale pending
  commands. No newly introduced security-advisor findings.
- No manual reschedule/backfill: an already-claimed demo slot finishes normally
  on its next wake, then adopts the exact original demo deadline.

Run new checks
node --test Tests/SyncEfficiency/server-reads.test.cjs
node --experimental-strip-types --test Tests/SubscriptionAccess/*.test.ts Tests/DeviceIdentity/registration.test.cjs Tests/LocationPush/apns-routing.test.ts
npx --yes deno@2.5.4 check supabase/functions/parental-control-sync/index.ts supabase/functions/parental-control-balance-sync/index.ts

Remaining acceptance on existing installed builds
- Parent: refresh dashboard/map/tasks/schedules; block/unblock/add time.
- Child app closed: schedule start/end; demo expiry releases apps and pauses
  parent controls. Purchase/restore and renewals must retain previous behavior.
- Compare logs during an equivalent active test; the saved REST call is one per
  poll and one per affected read, NOT all database calls or Edge invocations.
  Whole-project Log Ingestion savings are not yet measured.

Rollback order (only if needed)
- Restore Edge v26 first (it issues the expiration PATCH); the new RPC is still
  compatible. Then restore the snapshot function from 202610120001 if necessary.
- Restore ONLY pc_access_finish_maintenance from 202610220002 if necessary.
  Never replay that whole historical migration: it also mutates owner receipts.
- No tables/columns/data were removed and no credentials/identities were reset.

Scope
- Schedule cron keeps its minute cadence, credentials and handler. It invokes
  Edge only for allowed schedule transitions OR due access maintenance.
- Existing access policy (including cached paid state), webhook, command retry,
  purchase verification and NSE processing are unchanged.
- APNs token registration serializes writes, remembers successful delivery in
  memory, retries failures, notices environment changes and repairs every 24h.
  New processes register again. Unknown bootstrap tokens cannot overwrite a
  freshly observed token. Unlink/role changes invalidate acknowledgements.
- Identical in-flight snapshots/bootstrap share transport, not a cached result.
  Writes and pushes invalidate joinable reads. Scope includes pairing/payload.
  Commands, purchase verification, ACKs and usage uploads are never coalesced.
- Foreground synchronization retains its immediate access check and avoids
  overlapping periodic sync for at most one 8-second interval; a slow request
  cannot suspend command fallback indefinitely. An existing loop is not restarted
  on bootstrap, preserving the stats/PIN throttle timestamps.

Checks
xcrun swiftc -parse-as-library -module-cache-path /private/tmp/parental-sync-module-cache ParentalControl/Services/SyncRequestCoalescer.swift Tests/SyncEfficiency/main.swift -o /private/tmp/parental-sync-efficiency-tests
/private/tmp/parental-sync-efficiency-tests
node Tests/SyncEfficiency/validate.cjs
node --experimental-strip-types --test Tests/SubscriptionAccess/*.test.ts Tests/LocationPush/*.test.ts

server.sql uses an exception subtransaction: generated fixtures roll back even
on success. It ran atomically with the migration before commit. It tests expired
and paid schedules, demo, removed/disabled schedules, unknown timezone fallback,
maintenance without schedules, released/stale pairs, lifetime, APNs row write
deduplication, environment changes and function privileges. It sends no pushes
or purchases, does not change real families, and does not reset subscription data.

Device acceptance (install without deleting data)
- Xcode -> TestFlight: notifications must still reach the correct environment.
- Repeated foreground/background while paid; block/unblock/add time.
- Child app closed: schedule start/end and subscription expiry/renewal.
- Expired access: no ordinary data polling; purchase/restore still reactivates.
- Offline -> online: failed token registration and normal sync retry.

Baseline audit window: 2026-10-24 11:40-12:40 UTC. 85 APNs registration RPCs and
60 schedule-maintenance invocations observed; one expired family's unresolved
schedule transition remained. These are observations, not a per-user forecast.

Verification completed
- Atomic Supabase migration + server.sql passed; 18 families / 49 devices stayed
  unchanged and no EFF test fixtures remained.
- Schedule cron at 12:59, 13:00, 13:01 and 13:02 UTC succeeded with 0 rows
  (no net.http_post invocation), versus 1 row at 12:58 before the change.
- 19 async Swift efficiency checks; 50 Node subscription/location tests;
  40 Swift access checks and 69 notification-control checks passed.
- Sync integration, cleanup, paywall, banner and 21-locale validation passed.
- Final unsigned Debug and Release builds passed. Existing extension build
  number warnings remain; signing/distribution profiles were not modified.
- Hardware acceptance above is still required after installing the new build.
