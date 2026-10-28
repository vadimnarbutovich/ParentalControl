Budget monitor generation regression — 2026-10-26

The modern daily-budget path must distinguish a superseded monitoring attempt
from a real system failure. A stale attempt must not apply a fallback shield,
clear a newer shield, or stop a newer monitor after detecting the changed state.
Current registration failures and missing/exhausted budgets remain fail-closed.
No lock is held across DeviceActivity or ManagedSettings IPC.

Run from the project root:
xcrun swiftc -module-cache-path /private/tmp/parental-access-module-cache ParentalControl/Models/DailyBudget.swift DeviceActivityMonitorExtension/BudgetMonitorRearm.swift Tests/BudgetMonitor/main.swift -o /private/tmp/parental-budget-monitor-tests
/private/tmp/parental-budget-monitor-tests
node Tests/BudgetMonitor/validate.cjs

Hardware acceptance (required; mocks do not establish actual shield behavior):
- Update the child app without deleting data or changing the family.
- With paid/demo access active, time remaining, no active schedule and manual
  blocking off, use a monitored app while the child app is closed. Opening the
  parent app must not cause an unsolicited temporary shield.
- Verify manual block/unblock, adding time, schedule start/end, and exhaustion
  of the daily allowance, including while the child app is closed.
- If unexpected shielding recurs, record the time and collect the child logs.
  BudgetMonitor OSLog and parentalcontrol.budgetMonitorDiagnostic distinguish
  superseded attempts, missing/exhausted budgets, and real registration errors.
  Diagnostics stay local; no backend requests or retry timers were added.
