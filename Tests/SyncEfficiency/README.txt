Sync efficiency, 2026-10-24

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
