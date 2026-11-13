New-day background accounting audit — 2026-11-10

Run from repository root:
xcrun swiftc -module-cache-path /private/tmp/parental-access-module-cache ParentalControl/Models/DailyBudget.swift Tests/DailyRollover/main.swift -o /private/tmp/parental-rollover-tests
/private/tmp/parental-rollover-tests

61 checks use the production DailyBudgetState/Policy/UsagePlan: previous-day
remaining or exhausted budgets; extras reset; stale callback rejection; all
20 cumulative thresholds up to 600 seconds; state serialization between events;
repeated/backward dates; weekly limits offline; zero-limit day; idle gaps and
skipped days. These are model tests, not evidence of OS callback delivery.
52 existing CumulativeBudget and 38 BudgetMonitor checks also passed, including
BudgetMonitor/validate.cjs. No runtime code or backend configuration changed.

Reviewed runtime path:
- ScreenTimeEnforcer ensures repeating parentalcontrol.dailyBudget registration,
  including when usage is exhausted. Exhaustion stops parentalcontrol.activity,
  not the daily monitor.
- DeviceActivityMonitorExtension.intervalDidStart handles both names and calls
  enforceDailyBudget. DailyBudgetStore.current archives yesterday and advance
  resets usage/extras/generation, resolving the stored policy for the new weekday.
- With available time, the extension arms a fresh cumulative plan and clears the
  budget shield only after successful registration and current-context checks.
- At the final threshold, recordMonitorUsage reaches zero available; enforcement
  applies the shield locally. BackgroundUsageUploader runs after enforcement and
  does not gate it on networking or a server acknowledgement.
- Old-generation threshold events can also cause current() to roll the day;
  a nil monitorEvent triggers rearming without charging yesterday's callback.

Limits of this audit:
- Apple invokes intervalDidStart on device usage within the interval, not as a
  guaranteed midnight wall-clock timer. A delayed restart with includesPastActivity
  false can omit usage before the new registration; no second-perfect claim.
- Physical midnight behavior, actual ManagedSettings shield and exact callback
  timing were not observed in this audit. Test overnight without opening the host.
- Active cached family access, valid local setup/selection/authorization and
  monitoring not paused are prerequisites. Explicit manual/schedule blocks have
  their own priority. Demo expiry intentionally releases restrictions. A reboot
  or clock change can invalidate a demo receipt until authenticated refresh.
- Parent counters can lag local accounting due to background upload delivery.

Device test: receive the active demo and 600-second daily policy on the child
before midnight. Leave the host app backgrounded. The next morning use selected
apps, noting actual active usage and shield time; do not open the host until
observations are recorded. Keep this separate from reboot/clock-change tests.

Apple reference:
https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter
