Subscription access integration — 2026-10-22

Confirmed purchase state (2026-10-22; supersedes paid continuity)
- Paid access is the last authenticated canonical decision. Offline/verification
  failures preserve active, including sleep/reboot. No local paid expiry timer.
  An ONLINE canonical inactive response immediately clears paid continuity and
  emits a higher-revision expired snapshot. It never revives without a newly
  verified active purchase. Explicit release/unlink and 24h demo are unchanged.
- This intentionally allows indefinite OFFLINE use of previously verified paid
  access, as requested. No offline access is invented for a nonbuyer. Child PIN
  recovery remains available. Initial purchase/restore still requires current
  canonical purchase confirmation, never the SDK flag alone.
- RevenueCat has_already_renewed uses ends_at, covering the already-paid next
  period before current_period_ends_at advances. Contradictory expired dates
  cannot synthesize a fresh purchase; only explicit in_grace_period may give
  a short canonical billing-grace horizon. HTTP failures stay unknown.
- Renewal checks use nextCheckAtMs (including early checks near period end),
  not only a fixed 15min client interval. Server TTL respects a nearby expiry.
- Early renewal webhook + stale API period is retried, not marked completed.
  Webhook payload never grants access; environment allowlisting is preserved.
- Premium settings use effective server paid access, labelled Premium available.
  Cached SDK entitlement alone cannot show active access.
- Both migrations paid_access_continuity and confirmed_purchase_state passed
  server.sql, pilots.sql, continuity.sql with the policy applicable at the time
  inside rollback-isolated savepoints. Only schema/backfill persisted; no demo
  reset, family deletion, global rollout change or synthetic purchase occurred.
- Hardware: install updated host/extensions, then exercise several accelerated
  Sandbox renewals with child app backgrounded. Active cached paid access must
  survive offline and reboot; confirmed expiration must revoke after reconnect.
- Foreground always revalidates. If parent status check detects expiration it
  wakes child NSE. tasks_updated wake retries remain eligible after expiration,
  but child_poll still returns 402 and no paid command payload in that state.
  APNs delivery is best-effort; undelivered revocation requires later sync.
- Automated SQL regression: Tests/SubscriptionAccess/continuity.sql.

ROLLOUT IS OFF. This is implemented integration code, not a production acceptance
sign-off. Do not enable pc_access_rollout until BOTH updated devices pass the
hardware checklist below. Existing families have not started their demo.

Implementation
- Keychain backup of the existing device ID + secret; no account registration.
- Server-owned purchase identity. The SDK logs in to it before purchase/restore.
  Existing purchases under an older sb-UUID need an explicit Restore Purchases.
  Never trust a client-supplied customer ID or isPro as a server entitlement.
- Additive RLS/service-role-only access tables and RPCs. The 24-hour demo starts
  once BOTH paired devices report supported protocol + completed setup, with
  child Screen Time authorization and selection. Re-pairing does not reset it.
- Server-verified paid decisions; inactive and verification failure differ.
  Network failures preserve the last verified decision, not a new purchase.
  Sandbox requires an explicit server-side owner allowlist.
- Host request gate, ordinary polling suspension, usage-upload gate, location
  request gate, both sync endpoints, schedule cron and command-retry gates.
  Recovery checks remain at 15-minute intervals; purchase/restore gets a
  separately rate-limited immediate check and a short recovery window.
- Shared decision checks in host, NSE and DeviceActivity monitor. Confirmed paid expiration clears
  default and named schedule stores and stops owned monitoring. Selection,
  tasks, schedules and pairing stay intact. The old destructive one-app trim
  has been removed, including its remaining picker UI branch.
- Paid actions on parent show paywall; child does not get purchase prompts.
  Paused-access banner is localized in all 21 current application locales.
- A local expiry monitor is armed only for demo, never for cached paid access. System IPC
  remains on the bounded worker, outside shared-data locks. Late responses are
  revision-checked; same-revision polling does not invalidate ongoing system work.
- Existing authenticated schedule cron also performs bounded maintenance:
  normally every 12 hours for paid owners, near subscription expiration, and
  once at demo expiry. Unknown paid verification retries without extending the
  old lease. Inactive, expired demo owners stop background maintenance.
- Authenticated RevenueCat webhook rechecks canonical purchases, including both
  owners on transfer. Processing tokens fence stale verifier responses; event
  IDs deduplicate deliveries. Raw webhook bodies/customer attributes are not saved.
  TEST events are authentication/delivery checks only and never grant access.

Server deployment
Project: tttwrzgjddalgiwmgmyz
Migrations: family_access, explicit_purchase_refresh, access_maintenance,
family_access_pilots, access_setup_and_enrollment, paid_access_continuity,
confirmed_purchase_state.
Both sync functions include access checks; normal device/cron authentication is
preserved. Restriction switch remains false.
Webhook: ParentalControl Supabase Access / whintgr235923552d
https://app.revenuecat.com/projects/77ee7cb3/integrations/webhooks/whintgr235923552d
The user configured Authorization header and received 'ok' for a dashboard TEST.
Independent HTTP checks: missing/wrong secret => 401; correct secret TEST => 200.
Secrets are not in the repository. REVENUECAT_SECRET_API_KEY and
REVENUECAT_WEBHOOK_AUTH belong only in Edge Function Secrets.

Automated verification
PIN cache repair (2026-10-22)
- PIN metadata now uses one versioned Keychain item (update/add, never delete/add).
  Legacy migration retains readable old data if the new write fails. Tombstones
  prevent leftover legacy records from restoring a deliberately removed PIN.
- Keychain unavailable/corrupted is not PIN absent. Foreground refresh is local;
  Parent Mode entry may repair missing/corrupted or pending metadata using the
  EXISTING authenticated fetch_parent_pin recovery action. No access gate,
  subscription policy, server endpoint or polling cadence was changed.
- Recovery is single-flight and family-scoped, at most one attempt per five
  minutes across app restarts, initiated by Parent Mode entry only. A usable
  current local PIN requires no new network request. Keychain errors log only
  operation and OSStatus, never PIN/hash/salt. Late fetches check family/role.
- Device acceptance: update without uninstalling, open Parent Mode online with
  expired access to repair the cache; then relaunch offline and enter the same
  PIN. Paid actions must remain gated. Also verify PIN change, locked-phone
  delivery, wrong-PIN lockout, unlink/re-pair and app relaunch.
xcrun swiftc -module-cache-path /private/tmp/parental-pin-module-cache ParentalControl/Services/ParentPinService.swift Tests/ParentPIN/main.swift -o /private/tmp/parental-pin-tests
/private/tmp/parental-pin-tests

node --experimental-strip-types --test Tests/SubscriptionAccess/*.test.ts
xcrun swiftc -module-cache-path /private/tmp/parental-access-module-cache ParentalControl/Models/FamilyAccessLease.swift ParentalControl/Models/FamilyAccessPresentationStack.swift Tests/SubscriptionAccess/main.swift -o /private/tmp/parental-access-tests
/private/tmp/parental-access-tests
node Tests/Paywall/validate.cjs
node Tests/Localization/validate.cjs
npx --yes deno@2.5.4 check --node-modules-dir=none supabase/functions/parental-control-sync/index.ts supabase/functions/parental-control-balance-sync/index.ts
Tests/SubscriptionAccess/server.sql: isolated fixtures, assertions, final ROLLBACK.
The SQL test temporarily enables the rollout only INSIDE the rolled-back
transaction; other sessions never observe that uncommitted flag.
Also run the existing NotificationControl, WorkerTests and ScheduleTests.
Build all app/extension targets, not only the host.

Required hardware acceptance BEFORE enabling restrictions
1. Install new builds on BOTH phones; open child once; verify permissions,
   selection, initialized budget and pairing. Confirm both access-ready flags.
2. Explicitly approve enabling a test family/rollout and sandbox allowance.
   Do not use an arbitrary client environment flag to grant sandbox purchases.
3. Verify exactly one demo start; restart/re-pair must not move its timestamp.
4. Expire a TEST owner's demo deliberately; with child app closed and another
   app active, verify actual manual AND schedule shields clear without payment.
   Repeat offline, locked screen, zero budget, overlapping schedule and reboot.
5. Parent paid actions show paywall, child never does. Navigation, restore,
   support, PIN-authorized local recovery and unlink remain possible.
   With expired access and an empty runtime cache, block/time buttons must still
   open the paywall rather than stay disabled as "Synchronizing". Create/edit
   task and schedule entry points must gate before opening a new draft. Also
   expire access while an editor is ALREADY open: Save shows a paywall over the
   editor; closing it must retain typed fields and must not persist a mutation.
6. Test sandbox annual trial, monthly and lifetime, cancellation, restore,
   renewal, refund and transfer. Existing legacy SDK purchases require Restore.
   Verify both server access and actual enforcement, not just an SDK flag/ACK.
7. After purchase verify background NSE control resumes, minutes still count,
   schedules reconcile, and a delayed expiry/retry cannot undo renewed access.
8. Verify 12-hour maintenance actually reaches the child without foregrounding.
   Check request volume after demo expiry (no ordinary 8-second polling/uploads).
9. Test failed webhook delivery/retry and RevenueCat outage: cached paid access
   persists; confirmed inactive revokes; stale receipts cannot regrant access.

Limitations / release gates
- iOS DeviceActivity and APNs are not exact wall-clock guarantees. Offline expiry,
  short remaining intervals and safe release require physical-device testing.
- SQL/unit tests and an unsigned Simulator build are NOT TestFlight acceptance.
- TEST webhook success does not prove a real purchase/refund was verified.
- No-account restore depends on the Apple account and RevenueCat restore policy.
- Turning rollout off does not reset an already enrolled local receipt: delayed
  legacy responses must not bypass payment. Plan rollback with safe release,
  not a client isPro override.
- Keep the global rollout flag OFF during pilots. A pilot initially identifies an
  exact family + parent + child, then permanently enrolls that parent device.
  Replacing the child, unlinking or deleting the family cannot reopen legacy access
  or restart the owner's demo. Other parents remain unaffected.
  Tests/SubscriptionAccess/pilots.sql verifies this with rolled-back fixtures.
- An enrolled but not activated family is SETUP with no blocking lease. The
  wizard may save selection and limits and poll setup status; it cannot send
  manual blocks, time adjustments, tasks, schedules or location requests.
  child_poll registers budget capabilities without a usage upload and returns
  no pending commands / active focus in setup. Expired activated families cannot
  use setup exceptions, even if a client sends ready=false.
- PIN-authorized removal-protection activation requires current access; disabling
  protection stays available without purchase. Setup selection does not enforce
  shields. Complete the wizard to start the demo before enabling protection.
- Purchase/restore success requires a canonical server confirmation field, not
  HTTP 200, demo access or the SDK entitlement alone. Unknown/network failure
  keeps the paywall open with a localized pending-verification message.
  Retrying an owned purchase while access is unavailable does not call StoreKit
  purchase again. Monthly/annual upgrades remain possible with active access.
  Missing verifier/older server response fails closed. No purchased entitlement
  is synthesized, and safe release is never undone by a confirmation.
- Delayed purchase/restore confirmation: within the existing 120-second recovery
  window, the throttled access check uses verify_purchase INSTEAD OF access_status
  while the operation is awaiting confirmation. Automatic retries do not extend
  the window. No separate timer/polling loop is added. Only an explicit positive
  purchaseConfirmed result completes the operation; cached paid access does not.
  Paywall observes awaiting -> confirmed and closes without restarting the app.
  Both Retry buttons recheck the server without calling purchase/restore or
  requiring loaded product prices. After the bounded window, Retry remains
  available and starts a new recovery window only on an explicit user action.
  Hardware regression: delay confirmation after Apple accepts a purchase, leave
  the paywall open, and verify it closes once the server confirms. Also test
  restore, a cancelled Apple sheet, offline retry, and opening the paywall with
  an existing active subscription (must not dismiss on its own).
- A short hardware-test demo is an explicitly approved change to the TEST owner's
  trial_started_at, with revision incremented, BEFORE either device receives an
  enforced lease. Never shorten an already cached lease without refreshing both
  devices first. Removing an allowlist row is not a safe client receipt rollback;
  use safe release / canonical renewed access as described above.
