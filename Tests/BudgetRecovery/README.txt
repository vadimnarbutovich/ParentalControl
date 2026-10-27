Daily usage recovery after reinstall — 2026-10-27

The child restores accounted usage from the state already included in child_poll.
Host and Notification Service Extension use the same DailyBudgetStore path and
file lock. No server change, new request, timer or subscription decision.

Missing local store: restore only a valid same-family, same-day snapshot whose
revision does not exceed the supplied policy. Keep applied capped adjustments,
then apply only newer operations. Never copy old monitor events or clock anchors.
Existing store: reconcile cumulative usage with max(local, reported) before
applying new adjustments. Do not overwrite local extras or policy from the report.
Daily rollover remains authoritative; yesterday's usage is not carried forward.
Existing receipt/access gates and enforcement acknowledgements are unchanged.

Run from the project root:
xcrun swiftc -module-cache-path /private/tmp/parental-access-module-cache ParentalControl/Models/DailyBudget.swift Tests/BudgetRecovery/main.swift -o /private/tmp/parental-budget-recovery-tests
/private/tmp/parental-budget-recovery-tests
node Tests/BudgetRecovery/validate.cjs

Hardware acceptance (needs active paid/demo access and the new child build):
1. Existing reset child: open the app and confirm today's used/remaining time
   agrees with the parent's latest snapshot; no further reinstall is needed.
2. Use a monitored app for another minute; usage must continue from the restored
   count, not restart, multiply on refresh, or decrease.
3. Check manual block/unblock and adding time with the child app backgrounded.
4. Reinstall the child app, restore the SAME family and complete required
   permissions/selection. Today's retained usage and available time must return.
   Confirm again after restarting both apps.

Do not reset server usage or automatically extend the family's demo for testing.
Usage not uploaded before deletion cannot be recovered from this snapshot.
This change restores today's budget, not all historical local reports.
