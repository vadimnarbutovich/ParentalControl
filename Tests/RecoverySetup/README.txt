Recovery-only onboarding

Run: node Tests/RecoverySetup/validate.cjs
Also: node Tests/DeviceIdentity/validate.cjs

Executes the actual AppState preparation method with fake network/storage,
plus 256 combinations of permissions, role, PIN, budget and access state.
Network/protected-storage errors and a changed family must not produce a plan
that treats unknown settings as absent. Recovery never writes a PIN or budget.
Expired access skips paid budget polling and paid child app-selection setup.

Hardware follow-up:
1. Keep the existing family and PIN; note the nondefault daily/weekly limits.
2. Reinstall the parent, choose Restore link. The existing install/share page
   appears first, with recovery-specific instructions and an Already installed
   button that continues without sharing or waiting for the child. Then only
   missing setup steps appear; no new PIN or limit is required. Verify the old PIN
   on the child. Also check the link and QR code when both apps were deleted.
3. Reinstall the child and restore. Regrant permissions/select apps if missing;
   verify the existing PIN before accessing the protected picker. Do not create
   a new PIN. Removal protection stays optional in Settings.
4. Close/relaunch during recovery: the short recovery flow must resume.
5. With no internet, recovery shows a retry, not editable default settings.
6. With expired paid/demo access, recovery still finishes without resetting the
   demo, granting paid access, or requiring a paid budget poll.
7. Fresh install/new-family setup and Settings onboarding replay stay complete.
