Cumulative child usage accounting — 2026-11-10

Observed on the child's iPhone 13 Pro, published build 1.0 (14): from 16:35:08
through 16:44:43 Minsk, nine threshold cycles took 575 seconds, while the
single-chunk model charged 270 seconds. Exhaustion/shield occurred at 16:48:30.
The logs establish callback cadence, not exact foreground app durations or the
internal reason for Apple's delay.

Modern daily budgets now register up to 20 cumulative events in one activity:
30, 60, ... seconds, ending at the allowance or a bounded 600-second window.
Allowances below one minute retain 10-second steps and an exact last threshold.
Intermediate events do NOT stop/start monitoring. Only a completed window or
an existing enforcement change rearms. There can still be delay/lost activity
at a window boundary; this is not a claim of second-perfect system delivery.
Warnings are not scheduled for this modern monitor (they do not debit usage).

Persistent optional monitorPlan stores the starting used count and registered
thresholds. Matching generation + threshold advances usage to max(existing,
baseline + threshold), capped by budget. Duplicate, out-of-order and missing
intermediate callbacks cannot multiply charges. Old generation/day events do
not debit the new allowance. Early-event guard remains; elapsed wall time is
never itself charged. Terminal callbacks retire the generation even if server
reconciliation has already advanced usage beyond the window baseline.

The file lock, stale-enforcement fences, subscription gates and manual control
remain. Host/NSE use the same plan. Old single-event state is readable; its
outstanding event can be consumed before migration. Restore after reinstall
retains usage but never restores monitorPlan/event ownership from the server.
No backend changes, new polling, network timers or uploader throttle changes.

Run from project root:
xcrun swiftc -module-cache-path /private/tmp/parental-access-module-cache ParentalControl/Models/DailyBudget.swift Tests/CumulativeBudget/main.swift -o /private/tmp/parental-cumulative-budget-tests
/private/tmp/parental-cumulative-budget-tests
Also run Tests/BudgetMonitor, Tests/BudgetRecovery, and NotificationControl/main.swift
using their existing README commands. Results: 52 + 38 + 39 + 69 checks passed,
and both budget integration guard scripts passed.

Full unsigned Debug iOS build including all extensions passed with Xcode 27.2.
RevenueCat pin changed from 5.66.0 to 5.80.2 (same as ScreenBlocker) because the
old CustomerCenterConfigData init(stringRepresentation:) is ambiguous in this
SDK. No subscription code was changed. Log: /private/tmp/parental-cumulative-build.log

Required device acceptance, not yet performed:
- Install the new child build over existing data; keep family and selections.
- With active Premium/demo, no schedule and manual block off, set 6 minutes
  remaining. Close the child app, continuously use a selected app and time the
  actual shield. Compare child/parent counters after delivery settles.
- Repeat with >10 minutes remaining to cross a monitoring window boundary.
- Lock the screen for 2 minutes mid-test. The idle gap must not be charged.
- Switch between selected Instagram and Yandex; verify aggregate usage.
- Verify parent block/unblock, +/- minutes, schedule boundaries and access expiry.
- Since RevenueCat was updated, check entitlement refresh/restore and paywall.
Local BudgetMonitor info logs now record threshold, delta, remaining and whether
its window ended, without app tokens, family IDs or extra backend logging.

Device evidence added 2026-11-10:
User confirmed 5-minute exhaustion and +5-minute unlock. The later collected
archive confirms one full 20-event window (18:32:40–18:42:58 Minsk), median
callback spacing 29.998s, with no intermediate restart. The next window started
at 18:42:58.273 and delivered another four thresholds. Across 18:14:09–18:45:53,
42 threshold callbacks match the server increment 1500 -> 2760 seconds.
However, event names are private and Usage info entries were not retained;
per-event deltas/actual foreground activity cannot be independently recovered.
The next window's first callback arrived after 65.3 seconds. This evidence
confirms improved cadence and continued accounting across the window boundary,
not zero boundary delay or exact wall-clock accounting. Screen-off-idle and
schedule/access-expiry acceptance remain unconfirmed by this test.
